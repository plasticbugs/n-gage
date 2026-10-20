/* The exec calls: EUser's `svc N` stubs, and the executor behind most of
 * the ones that create things.  Numbers and arguments are EKA1's, as the
 * ROM's EUser makes them (docs/eka1_exec.md).
 *
 * Every stub is one `svc` instruction reached by BL, so the call returns to
 * the caller's LR.  Bit 23 of the number marks a "slow" exec and bit 22 one
 * that may reschedule; the index into the table is what is left. */
#include "kobj.h"
#include "mm.h"

extern struct process *proc_mapped(void);
extern struct thread *thread_by_id(u32 id);
extern void thread_reprioritise(struct thread *t);
extern int  des_type(u32 d);
extern int  des_read8(u32 d, u8 *buf, int max);
extern int  des_to_ascii(u32 d, char *out, int max);
extern void kputdes16(u32 d);
extern int  ipc_read(struct thread *c, u32 cdes, u32 ldes, int off, int unit);
extern int  ipc_write(struct thread *c, u32 cdes, u32 ldes, int off, int unit);
extern int  ipc_des_len(struct thread *c, u32 cdes, int max);
extern void ipc_set_session_ptr(u32 mh, u32 ptr);
extern void ipc_receive_cancel(struct server *s);
extern struct process *proc_new(const u16 *path, int n);
extern s32 loader_exec(struct thread *t, int sub, u32 args, u32 attr);
extern s32 hal_get(u32 fn, u32 a1, u32 a2);
extern s32 unicode_exec(int idx, u32 a0);
extern void locale_refresh(u32 p);

#define ARG(i) (c->r[i])

static struct thread *thr(u32 h) { return (struct thread *)handle_lookup(cur, h, O_THREAD); }
static struct process *prc(u32 h) { return (struct process *)handle_lookup(cur, h, O_PROCESS); }

static void kill_by_handle(u32 h, int type, s32 reason, u32 catdes)
{
    u16 cat[16]; int n = 0;
    if (catdes) n = des_read16(catdes, cat, 16);
    struct thread *t = thr(h);
    if (t) thread_exit(t, type, reason, cat, n);
}

/* Words on a user stack that look like return addresses into the ROM. */
void trace_stack(u32 sp)
{
    extern int uaddr_ok(u32, u32);
    kprintf("  stack:");
    for (int i = 0; i < 32 && uaddr_ok(sp + 4 * i, 4); i++) {
        u32 w = uread32(sp + 4 * i);
        if (w - NGVM_ROM_BASE < 0x1400000 && (w & 1 || !(w & 3))) kprintf(" %x", w);
    }
    kprintf("\n");
}

/* ---- the executor ----------------------------------------------------------- */
static s32 name_arg(u32 d, u16 *buf)
{
    if (d == 0xFFFF0000u || d == 0) return 0;
    return des_read16(d, buf, NAME_MAX);
}

static s32 put_handle(u32 args, struct kobj *o, int towned)
{
    u32 h = handle_make(cur, o, towned);
    u32 d = uread32(args);                    /* TPtr8 over the handle word */
    uwrite32(des_ptr(d), h);
    des_setlen(d, 4);
    return KErrNone;
}

/* ---- a server being started -------------------------------------------------
 * A client that cannot find its server starts it.  RPhCltServer::Connect
 * creates PhoneServer.exe, raises it to EPriorityHigh, resumes it and waits
 * for its signal; on the phone the new server takes its name at once.  Here
 * the loader takes tens of milliseconds to create the process, and a second
 * client that misses the name in that time starts a second copy.  The copy
 * finds the name taken and panics (PhSrvFault 2), the client waiting on it
 * panics after it (PhSrvTest 1), and on Sonic N the screen is never updated
 * again.  So a miss is remembered against the name, and another thread that
 * misses the same name meanwhile is answered when the server appears, or
 * when the first attempt is over: its thread dead, or STARTING_US since its
 * last miss. */
#define STARTS_N     8
#define WAITS_N      8
#define STARTING_US  2000000u
#define WAIT_POLL_US 5000u

extern int u16_eq_fold(const u16 *, int, const u16 *, int);

static struct { u16 name[NAME_MAX]; int n; u32 by; u64 since; } starts[STARTS_N];
static struct { u16 name[NAME_MAX]; int n; u32 tid, args, status; int towned, on; } waits[WAITS_N];
static struct ktimer wait_timer[WAITS_N];      /* kind 10: polls waits[secs] */

static int start_live(int i)
{
    struct thread *b;
    if (!starts[i].n) return 0;
    if (now_us() - starts[i].since > STARTING_US || !(b = thread_by_id(starts[i].by)) || b->state == T_DEAD)
        starts[i].n = 0;
    return starts[i].n != 0;
}

static int start_find(const u16 *name, int n)
{
    for (int i = 0; i < STARTS_N; i++)
        if (start_live(i) && u16_eq_fold(starts[i].name, starts[i].n, name, n)) return i;
    return -1;
}

static void start_note(const u16 *name, int n, struct thread *t)
{
    int i = start_find(name, n);
    if (i < 0)
        for (i = 0; i < STARTS_N && start_live(i); i++) ;
    if (i == STARTS_N || !n) return;            /* full: no record, as before */
    memcpy(starts[i].name, name, 2 * n);
    starts[i].n = n; starts[i].by = t->id; starts[i].since = now_us();
}

/* the session the thread asked for, or KErrNotFound, in its own process */
static void wait_answer(int i, struct server *s)
{
    struct thread *t = thread_by_id(waits[i].tid);
    if (t && t->state != T_DEAD) {
        struct process *was = proc_mapped();
        if (t->proc != was) proc_switch_in(t->proc);
        s32 r = KErrNotFound;
        if (s) {
            struct session *ss = (struct session *)obj_new(O_SESSION, sizeof(struct session), t->proc);
            ss->server = s;
            ss->client = t;
            obj_ref(&s->o);
            u32 d = uread32(waits[i].args);
            uwrite32(des_ptr(d), handle_make(t, &ss->o, waits[i].towned));
            des_setlen(d, 4);
            r = KErrNone;
        }
        kprintf("[ipc] thread %d: server ", t->id);
        kputs16(waits[i].name, waits[i].n);
        kprintf(s ? " started\n" : " not started\n");
        request_complete(t, waits[i].status, r);
        if (was && was != proc_mapped()) proc_switch_in(was);
    }
    if (wait_timer[i].queued) timer_dequeue(&wait_timer[i]);
    waits[i].on = 0;
}

static int wait_add(struct thread *t, u32 args, u32 status, int towned, const u16 *name, int n, u32 by)
{
    for (int i = 0; i < WAITS_N; i++) {
        if (waits[i].on) continue;
        memcpy(waits[i].name, name, 2 * n);
        waits[i].n = n; waits[i].tid = t->id; waits[i].args = args; waits[i].status = status;
        waits[i].towned = towned; waits[i].on = 1;
        wait_timer[i].kind = 10; wait_timer[i].secs = (u32)i; wait_timer[i].thread = 0;
        timer_queue(&wait_timer[i], now_us() + WAIT_POLL_US);
        kprintf("[ipc] thread %d waits for server ", t->id);
        kputs16(name, n);
        kprintf(", which thread %d is starting\n", by);
        return 1;
    }
    return 0;
}

/* timer_tick: a wait's poll */
void session_wait_tick(struct ktimer *k)
{
    int i = (int)k->secs;
    if (!waits[i].on) return;
    struct server *s = server_find(waits[i].name, waits[i].n);
    if (s || start_find(waits[i].name, waits[i].n) < 0) wait_answer(i, s);
    else timer_queue(k, now_us() + WAIT_POLL_US);
}

/* a server has taken the name: its record is over, and its waiters connect */
static void start_done(const u16 *name, int n, struct server *s)
{
    for (int i = 0; i < STARTS_N; i++)
        if (starts[i].n && u16_eq_fold(starts[i].name, starts[i].n, name, n)) starts[i].n = 0;
    for (int i = 0; i < WAITS_N; i++)
        if (waits[i].on && u16_eq_fold(waits[i].name, waits[i].n, name, n)) wait_answer(i, s);
}

/* A chunk's maximum is reported as asked, but no more than CHUNK_RESERVE_MAX
 * of addresses is reserved for one: programs ask for 32 MB heaps a thread at
 * a time (AppRun, FbServ, SysAp), which would fill chunk space with no RAM
 * behind it, and an N-Gage gives applications 3 to 4 MB in all.  Growing
 * past the reservation fails KErrNoMemory, as the phone's RAM would.  A
 * double-ended chunk keeps all of its range: its committed part may sit
 * anywhere in it. */
#define CHUNK_RESERVE_MAX 0x00800000u

static struct chunk *chunk_new(u32 max, u32 bottom, u32 top, int de)
{
    struct chunk *k = (struct chunk *)obj_new(O_CHUNK, sizeof(struct chunk), cur->proc);
    max = (max + NGVM_PAGE_SIZE - 1) & ~(NGVM_PAGE_SIZE - 1);
    k->max = max;
    k->reserved = de || max <= CHUNK_RESERVE_MAX ? max : CHUNK_RESERVE_MAX;
    k->base = vm_reserve(k->reserved);
    k->double_ended = de;
    if (!k->base) return 0;
    k->bottom = bottom & ~(NGVM_PAGE_SIZE - 1);
    k->top = (top + NGVM_PAGE_SIZE - 1) & ~(NGVM_PAGE_SIZE - 1);
    if (k->top > k->reserved) k->top = k->reserved;
    if (k->top > k->bottom && vm_commit(k->base + k->bottom, k->top - k->bottom)) return 0;
    return k;
}

static s32 chunk_adjust(struct chunk *k, u32 bottom, u32 top)
{
    bottom &= ~(NGVM_PAGE_SIZE - 1);
    top = (top + NGVM_PAGE_SIZE - 1) & ~(NGVM_PAGE_SIZE - 1);
    if (top > k->max || bottom > top) return KErrArgument;
    if (top > k->reserved) return KErrNoMemory;
    /* release what falls outside, commit what is new */
    if (k->bottom < bottom) vm_decommit(k->base + k->bottom, (bottom < k->top ? bottom : k->top) - k->bottom);
    if (top < k->top) vm_decommit(k->base + (top > k->bottom ? top : k->bottom), k->top - (top > k->bottom ? top : k->bottom));
    if (top > bottom && vm_commit(k->base + bottom, top - bottom)) return KErrNoMemory;
    k->bottom = bottom;
    k->top = top;
    return KErrNone;
}

static struct kobj *find_named(int type, const u16 *name, int n)
{
    extern int u16_eq_fold(const u16 *, int, const u16 *, int);
    u16 full[2 * NAME_MAX];
    for (struct kobj *o = obj_first(type); o; o = o->next) {
        if (o->namelen && u16_eq_fold(o->name, o->namelen, name, n)) return o;
        int fl = obj_full_name(o, full, 2 * NAME_MAX);
        if (u16_eq_fold(full, fl, name, n)) return o;
    }
    return 0;
}

int executor(struct thread *t, u32 attr, u32 a, u32 status)
{
    int sub = attr & 0xFF;
    int towned = (attr & HANDLE_THREAD_OWNED) != 0;
    u32 a0 = uread32(a), a1 = uread32(a + 4), a2 = uread32(a + 8), a3 = uread32(a + 12);
    u16 name[NAME_MAX];
    s32 r = KErrNone;
    int deferred = 0;                           /* completed later: a waiting session */
    if (kflags & DBGF_EXEC) {
        kprintf("[exec]   executor %x (%x %x %x %x) stack:", attr, a0, a1, a2, a3);
        extern int uaddr_ok(u32, u32);
        for (int i = 0; i < 24 && uaddr_ok(t->ctx.r[13] + 4 * i, 4); i++) {
            u32 w = uread32(t->ctx.r[13] + 4 * i);
            if (w - NGVM_ROM_BASE < 0x1400000 && (w & 1 || !(w & 3))) kprintf(" %x", w);
        }
        kprintf("\n");
    }
    switch (sub) {
    case 0x00: case 0x01:                       /* create chunk: local, global */
    case 0x4C: case 0x4D: {                     /* double ended                */
        int de = sub >= 0x4C;
        u32 info = des_ptr(a2);
        struct chunk *k = de ? chunk_new(uread32(info + 8), uread32(info), uread32(info + 4), 1)
                             : chunk_new(uread32(info + 4), 0, uread32(info), 0);
        if (!k) { r = KErrNoMemory; break; }
        int n = name_arg(a1, name);
        if (n) { obj_set_name(&k->o, name, n); k->o.global = (sub & 1); }
        r = put_handle(a, &k->o, towned);
        break;
    }
    case 0x02: case 0x18: case 0x1A: {         /* open a global chunk, mutex, semaphore */
        int n = name_arg(a1, name);
        struct kobj *o = find_named(sub == 0x02 ? O_CHUNK : sub == 0x18 ? O_MUTEX : O_SEMAPHORE, name, n);
        r = o ? put_handle(a, o, towned) : KErrNotFound;
        if (sub == 0x1A && (kflags & DBGF_IPC)) {
            kprintf("[sem] open ");
            kputs16(name, n);
            kprintf(" by ");
            kputs16(t->proc->o.name, t->proc->o.namelen);
            kprintf(" -> %d (refs %d)\n", r, o ? o->refs : 0);
        }
        break;
    }
    case 0x03: {                                 /* adjust chunk (top)       */
        struct chunk *k = (struct chunk *)handle_lookup(t, a0, O_CHUNK);
        r = k ? chunk_adjust(k, 0, a1) : KErrBadHandle;
        if ((kflags & DBGF_IPC) && (r || a1 >= 0x200000)) {
            kprintf("[chunk] adjust %x %p to %x (max %x reserved %x) -> %d by ", a0, k ? k->base : 0, a1, k ? k->max : 0, k ? k->reserved : 0, r);
            kputs16(t->o.name, t->o.namelen);
            kprintf("\n");
        }
        break;
    }
    case 0x4E: {                                 /* adjust double ended     */
        struct chunk *k = (struct chunk *)handle_lookup(t, a0, O_CHUNK);
        r = k ? chunk_adjust(k, a1, a2) : KErrBadHandle;
        break;
    }
    case 0x05: case 0x08: case 0x06:             /* add/free device drivers */
        r = KErrNone;
        break;
    case 0x44: case 0x45: case 0x46: {           /* RUndertaker               */
        extern s32 undertaker_executor(struct thread *, int, u32, int);
        r = undertaker_executor(t, sub, a, towned);
        break;
    }
    case 0x36: {                                 /* RChangeNotifier::Create  */
        extern s32 notifier_create(struct thread *, u32, int);
        r = notifier_create(t, a, towned);
        break;
    }
    case 0x4A:                                   /* ChangeLocale(locale DLL): the English
                                                    TLocale the kernel serves stays */
        r = KErrNone;
        break;
    case 0x0A: {                                 /* open a logical channel  */
        extern s32 chan_create(struct thread *, u32, int);
        r = chan_create(t, a, towned);
        break;
    }
    case 0x0F: {                                 /* duplicate a2 from thread a1 */
        struct thread *o = thr(a1);
        struct kobj *x = o ? handle_lookup(o, a2, 0) : 0;
        r = x ? put_handle(a, x, towned) : KErrBadHandle;
        break;
    }
    case 0x10:                                   /* close                   */
        r = handle_close(t, a0);
        break;
    case 0x15: {                                 /* create server           */
        struct server *s = (struct server *)obj_new(O_SERVER, sizeof(struct server), t->proc);
        int n = name_arg(a1, name);
        extern struct server *server_find(const u16 *, int);
        if (n && server_find(name, n)) { r = KErrAlreadyExists; break; }
        obj_set_name(&s->o, name, n);
        s->thread = t;
        r = put_handle(a, &s->o, 1);
        if (kflags & DBGF_IPC) { kprintf("[ipc] server "); kputs16(name, n); kprintf("\n"); }
        if (n) start_done(name, n, s);
        break;
    }
    case 0x16: {                                 /* create session          */
        extern struct server *server_find(const u16 *, int);
        int n = name_arg(a1, name);
        struct server *s = server_find(name, n);
        if (!s) {
            /* another thread is starting it: wait for that (above) */
            int i = n ? start_find(name, n) : -1;
            if (i >= 0 && starts[i].by != t->id && wait_add(t, a, status, towned, name, n, starts[i].by)) {
                deferred = 1; break;
            }
            if (n && (i < 0 || starts[i].by == t->id)) start_note(name, n, t);
            if (kflags & DBGF_IPC) { kprintf("[ipc] no server "); kputs16(name, n); kprintf("\n"); }
            if (kflags & DBGF_DUMP) thread_dump();
            r = KErrNotFound; break;
        }
        struct session *ss = (struct session *)obj_new(O_SESSION, sizeof(struct session), t->proc);
        ss->server = s;
        ss->client = t;
        obj_ref(&s->o);
        r = put_handle(a, &ss->o, towned);
        break;
    }
    case 0x17: {                                 /* create mutex            */
        struct mutex *m = (struct mutex *)obj_new(O_MUTEX, sizeof(struct mutex), t->proc);
        int n = name_arg(a2, name);
        obj_set_name(&m->o, name, n);
        r = put_handle(a, &m->o, towned);
        break;
    }
    case 0x19: {                                 /* create semaphore        */
        int n = name_arg(a2, name);
        if (n && find_named(O_SEMAPHORE, name, n)) { r = KErrAlreadyExists; break; }
        struct semaphore *s = (struct semaphore *)obj_new(O_SEMAPHORE, sizeof(struct semaphore), t->proc);
        obj_set_name(&s->o, name, n);
        s->count = (s32)a3;
        r = put_handle(a, &s->o, towned);
        if (n && (kflags & DBGF_IPC)) {
            kprintf("[sem] create ");
            kputs16(name, n);
            kprintf(" by ");
            kputs16(t->proc->o.name, t->proc->o.namelen);
            kprintf("\n");
        }
        break;
    }
    case 0x1B: {                                 /* create timer            */
        struct ktimer *k = (struct ktimer *)obj_new(O_TIMER, sizeof(struct ktimer), t->proc);
        r = put_handle(a, &k->o, towned);
        break;
    }
    case 0x1C: case 0x1D: case 0x0C: case 0x0D:  /* the loader's calls      */
    case 0x4B: case 0x50: case 0x51:
        r = loader_exec(t, sub, a, attr);
        break;
    case 0x0E: {                                 /* open by find handle     */
        struct kobj *o = obj_by_seq(a1 >> 28, a1 & 0x0FFFFFFF);
        r = o ? put_handle(a, o, towned) : KErrNotFound;
        break;
    }
    case 0x1F: {                                 /* open process by id      */
        struct kobj *o = 0;
        for (o = obj_first(O_PROCESS); o; o = o->next) if (((struct process *)o)->id == a1) break;
        r = o ? put_handle(a, o, towned) : KErrNotFound;
        break;
    }
    case 0x21: case 0x22: case 0x23: {          /* kill, terminate, panic process */
        struct process *p = prc(a0);
        u16 cat[16]; int n = 0;
        if (sub == 0x23 && a2) n = des_read16(a2, cat, 16);
        if (p) proc_kill(p, sub - 0x21, (s32)a1, cat, n);
        r = p ? KErrNone : KErrBadHandle;
        break;
    }
    case 0x25: case 0x30: {                      /* logon: process, thread  */
        struct kobj *o = handle_lookup(t, a0, sub == 0x25 ? O_PROCESS : O_THREAD);
        if (!o) { r = KErrBadHandle; break; }
        int dead = sub == 0x25 ? ((struct process *)o)->exit_type != 3 : ((struct thread *)o)->state == T_DEAD;
        if (dead) {
            request_complete(t, a1, sub == 0x25 ? ((struct process *)o)->exit_reason : ((struct thread *)o)->exit_reason);
            break;
        }
        struct logon *l = kzalloc(sizeof *l);
        l->t = t; l->status = a1;
        struct logon **lp = sub == 0x25 ? &((struct process *)o)->logons : &((struct thread *)o)->logons;
        l->next = *lp; *lp = l;
        break;
    }
    case 0x26: case 0x31: {                      /* logon cancel            */
        struct kobj *o = handle_lookup(t, a0, sub == 0x26 ? O_PROCESS : O_THREAD);
        if (!o) { r = KErrBadHandle; break; }
        struct logon **lp = sub == 0x26 ? &((struct process *)o)->logons : &((struct thread *)o)->logons;
        for (; *lp; lp = &(*lp)->next)
            if ((*lp)->t == t && (*lp)->status == a1) {
                struct logon *x = *lp; *lp = x->next;
                request_complete(t, x->status, KErrNone);
                kfree(x);
                break;
            }
        break;
    }
    case 0x27: {                                 /* create thread           */
        u32 info = des_ptr(a3);
        u32 func = uread32(info), stack = uread32(info + 4), heap = uread32(info + 8);
        u32 hmin = uread32(info + 12), hmax = uread32(info + 16), ptr = uread32(info + 20);
        struct thread *nt = thread_create(t->proc, func, ptr, stack, heap, hmin, hmax, 0);
        int n = name_arg(a2, name);
        obj_set_name(&nt->o, name, n);
        r = put_handle(a, &nt->o, towned);
        if (kflags & DBGF_SCHED) {
            kprintf("[sched] new thread "); kputs16(name, n);
            kprintf(" func %p heap %p\n", func, heap);
        }
        break;
    }
    case 0x28: {                                 /* set initial parameter   */
        struct thread *o = thr(a0);
        if (!o) { r = KErrBadHandle; break; }
        o->ctx.r[5] = a1;
        break;
    }
    case 0x29: {                                 /* open thread by name     */
        int n = name_arg(a1, name);
        struct kobj *o = find_named(O_THREAD, name, n);
        r = o ? put_handle(a, o, towned) : KErrNotFound;
        break;
    }
    case 0x2A: {                                 /* open thread by id       */
        struct thread *o = thread_by_id(a1);
        r = o ? put_handle(a, &o->o, towned) : KErrNotFound;
        break;
    }
    case 0x2B: {                                 /* a thread's process      */
        struct thread *o = thr(a1);
        r = o ? put_handle(a, &o->proc->o, 0) : KErrBadHandle;
        break;
    }
    case 0x2C: case 0x20: {                      /* rename thread, process  */
        struct kobj *o = handle_lookup(t, a0, sub == 0x2C ? O_THREAD : O_PROCESS);
        int n = name_arg(a1, name);
        if (o) obj_set_name(o, name, n);
        r = o ? KErrNone : KErrBadHandle;
        break;
    }
    case 0x2D:                                   /* kill thread             */
        kill_by_handle(a0, 0, (s32)a1, 0);
        break;
    case 0x2E:                                   /* terminate thread        */
        kill_by_handle(a0, 1, (s32)a1, 0);
        break;
    case 0x2F:                                   /* panic thread            */
        kill_by_handle(a0, 2, (s32)a1, a2);
        break;
    case 0x32: {                                 /* a thread's heap         */
        struct thread *o = thr(a0);
        if (!o) { r = KErrBadHandle; break; }
        uwrite32(a1, o->heap);
        break;
    }
    case 0x34: {                                 /* set TLS                 */
        int i, fr = -1;
        for (i = 0; i < MAX_TLS; i++) {
            if (t->tls[i].key == a0) break;
            if (!t->tls[i].key && fr < 0) fr = i;
        }
        if (i == MAX_TLS) i = fr;
        if (i < 0) { r = KErrNoMemory; break; }
        t->tls[i].key = a0; t->tls[i].ptr = a1;
        break;
    }
    case 0x35:                                   /* free TLS                */
        for (int i = 0; i < MAX_TLS; i++) if (t->tls[i].key == a0) t->tls[i].key = t->tls[i].ptr = 0;
        break;
    case 0x37: {                                 /* DllGlobalAlloc(h, size) */
        extern s32 dll_global_alloc(u32, u32);
        r = dll_global_alloc(a0, a1);
        break;
    }
    case 0x38: case 0x39: case 0x3B: case 0x3C: case 0x3D: case 0x3E: {
                                                 /* local drives; media change */
        extern s32 drive_executor(struct thread *, int, u32);
        r = drive_executor(t, sub, a);
        break;
    }
    case 0x3F: case 0x40:                        /* debugger open/close     */
        break;
    case 0x54: {                                 /* share a session (in-process) */
        struct kobj *o = handle_lookup(t, a1, O_SESSION);
        r = o ? put_handle(a, o, 0) : KErrBadHandle;
        break;
    }
    default:
        kpanic("executor %x unimplemented (args %x %x %x %x) lr %p", attr, a0, a1, a2, a3, t->ctx.r[14]);
    }
    if (kflags & DBGF_EXEC) kprintf("[exec]   executor %x -> %d\n", sub, r);
    if (!deferred) request_complete(t, status, r);
    return r;
}

/* ---- the static call list exec, and other execs about code ----------------- */
static s32 static_call_list(u32 h, u32 pcount, u32 plist)
{
    struct thread *t = thr(h);
    if (!t) return KErrBadHandle;
    u32 list[256];
    int max = (int)uread32(pcount);
    if (max > 256) max = 256;
    int n = proc_static_calls(t->proc, list, max);
    u32 out = uread32(plist);
    for (int i = 0; i < n; i++) uwrite32(out + 4 * i, list[i]);
    uwrite32(pcount, n);
    return KErrNone;
}

/* ---- dispatch ------------------------------------------------------------------- */
void exec_dispatch(struct ctx *c, u32 n)
{
    u32 idx = n & 0x003FFFFF;
    s32 r = 0;
    struct thread *me = cur;
    if (kflags & DBGF_EXEC) {
        kprintf("[exec] ");
        kputs16(me->proc->o.name, me->proc->o.namelen);
        kputc(':');
        kputs16(me->o.name, me->o.namelen);
        kprintf(" %x (%x %x %x %x) lr %p\n", n, ARG(0), ARG(1), ARG(2), ARG(3), c->r[14]);
    }
    /* return to the caller of the stub, in its state */
    c->pc = c->r[14] & ~1u;
    c->cpsr = (c->cpsr & ~0x20u) | ((c->r[14] & 1) << 5);

    switch (idx) {
    /* chunks */
    case 0x01: case 0x02: case 0x03: case 0xB0: case 0xB1: {
        struct chunk *k = (struct chunk *)handle_lookup(me, ARG(0), O_CHUNK);
        if (!k) { r = KErrBadHandle; break; }
        r = idx == 0x01 ? (s32)k->base : idx == 0x02 ? (s32)(k->top - k->bottom) : idx == 0x03 ? (s32)k->max
          : idx == 0xB0 ? (s32)k->bottom : (s32)k->top;
        break;
    }
    /* mutexes and semaphores */
    case 0x18: { struct mutex *m = (struct mutex *)handle_lookup(me, ARG(0), O_MUTEX); r = m ? (m->holder ? 0 : 1) : 0; break; }
    case 0x19: { struct mutex *m = (struct mutex *)handle_lookup(me, ARG(0), O_MUTEX); if (m) mutex_wait(m); break; }
    case 0x1A: { struct mutex *m = (struct mutex *)handle_lookup(me, ARG(0), O_MUTEX); if (m) mutex_signal(m); break; }
    case 0x29: { struct semaphore *s = (struct semaphore *)handle_lookup(me, ARG(0), O_SEMAPHORE); r = s ? s->count : 0; break; }
    case 0x2A: { struct semaphore *s = (struct semaphore *)handle_lookup(me, ARG(0), O_SEMAPHORE); if (s) sem_wait(s); break; }
    case 0x2B: { struct semaphore *s = (struct semaphore *)handle_lookup(me, ARG(0), O_SEMAPHORE); if (s) sem_signal(s, 1); break; }
    case 0x2C: { struct semaphore *s = (struct semaphore *)handle_lookup(me, ARG(1), O_SEMAPHORE); if (s) sem_signal(s, ARG(0)); break; }
    /* processes */
    case 0x1B: { struct process *p = prc(ARG(0)); r = p ? (s32)p->id : KErrBadHandle; break; }
    case 0x1D: {                                  /* resume                 */
        struct process *p = prc(ARG(0));
        if (p && p->main) thread_resume(p->main);
        if (p && (kflags & DBGF_IPC)) {
            kprintf("[kern] resume process ");
            kputs16(p->o.name, p->o.namelen);
            kprintf(" prio %d (main thread %d)\n", p->prio, p->main ? p->main->prio : -1);
        }
        break;
    }
    case 0xB5: {                                  /* RThread::Context(TDes8&): r0-r15, cpsr */
        struct thread *t = thr(ARG(1));
        if (!t) { r = KErrBadHandle; break; }
        u32 regs[17];
        for (int i = 0; i < 15; i++) regs[i] = t->ctx.r[i];
        regs[15] = t->ctx.pc;
        regs[16] = t->ctx.cpsr;
        int n = des_maxlen(ARG(0));
        r = des_write8(ARG(0), (const u8 *)regs, n < (int)sizeof regs ? n : (int)sizeof regs);
        break;
    }
    case 0x1E: case 0x1F: {                      /* file name, command line */
        struct process *p = prc(ARG(1));
        if (!p) { r = KErrBadHandle; break; }
        if (idx == 0x1E) des_write16(ARG(0), p->fname, p->fnamelen);
        else des_write16(ARG(0), p->cmd, p->cmdlen);
        break;
    }
    case 0xC0: { struct process *p = prc(ARG(0)); r = p ? p->cmdlen : KErrBadHandle; break; }
    case 0x20: { struct process *p = prc(ARG(0)); r = p ? (p->exit_type == 3 ? 3 : p->exit_type) : 0; break; }
    case 0x21: { struct process *p = prc(ARG(0)); r = p ? p->exit_reason : 0; break; }
    case 0x22: { struct process *p = prc(ARG(1)); if (p) des_write16(ARG(0), p->exit_cat, p->exit_catlen); break; }
    case 0x23: { struct process *p = prc(ARG(0)); r = p ? p->prio : 0; break; }
    case 0x24: {                                  /* set process priority   */
        struct process *p = prc(ARG(1));
        if (!p) { r = KErrBadHandle; break; }
        p->prio = ARG(0);
        for (struct kobj *o = obj_first(O_THREAD); o; o = o->next)
            if (((struct thread *)o)->proc == p) thread_reprioritise((struct thread *)o);
        break;
    }
    case 0x25: { struct process *p = prc(ARG(0)); r = p ? (s32)p->flags : 0; break; }
    case 0x26: { struct process *p = prc(ARG(2)); if (p) p->flags = (p->flags & ~ARG(0)) | ARG(1); break; }
    case 0x27: break;                             /* set owner             */
    case 0xAA: case 0xAF: {                       /* RProcess::Type / SetType */
        struct process *p = prc(ARG(1));
        if (!p) { r = KErrBadHandle; break; }
        if (idx == 0xAA) for (int i = 0; i < 3; i++) uwrite32(ARG(0) + 4 * i, p->uid[i]);
        else for (int i = 0; i < 3; i++) p->uid[i] = uread32(ARG(0) + 4 * i);
        break;
    }
    /* threads */
    case 0x32: { struct thread *t = thr(ARG(0)); r = t ? (s32)t->id : KErrBadHandle; break; }
    case 0x34: {                                  /* resume                 */
        struct thread *t = thr(ARG(0));
        if (t) thread_resume(t);
        break;
    }
    case 0x35: { struct thread *t = thr(ARG(0)); if (t) t->suspend_count++; break; }
    case 0x36: { struct thread *t = thr(ARG(0)); r = t ? t->prio_rel : 0; break; }
    case 0x37: {
        struct thread *t = thr(ARG(1));
        if (t) { t->prio_rel = (s32)ARG(0); thread_reprioritise(t); }
        break;
    }
    case 0x38: { struct thread *t = thr(ARG(0)); r = t ? t->proc->prio : 0; break; }
    case 0x39: {
        struct thread *t = thr(ARG(1));
        if (t) {
            t->proc->prio = ARG(0);
            for (struct kobj *o = obj_first(O_THREAD); o; o = o->next)
                if (((struct thread *)o)->proc == t->proc) thread_reprioritise((struct thread *)o);
        }
        break;
    }
    case 0x3A: {                                  /* flags; bit 31: first thread, attaching */
        struct thread *t = thr(ARG(0));
        r = t ? (s32)(t->flags | (t->first_in_process ? 0x80000000u : 0)) : 0;
        break;
    }
    case 0x3B: { struct thread *t = thr(ARG(2)); if (t) t->flags = (t->flags & ~ARG(0)) | ARG(1); break; }
    case 0x3C: { struct thread *t = thr(ARG(0)); r = t ? t->reqsem : 0; break; }
    case 0x3D: { struct thread *t = thr(ARG(0)); r = t ? (t->state == T_DEAD ? t->exit_type : 3) : 0; break; }
    case 0x3E: { struct thread *t = thr(ARG(0)); r = t ? t->exit_reason : 0; break; }
    case 0x3F: { struct thread *t = thr(ARG(1)); if (t) des_write16(ARG(0), t->exit_cat, t->exit_catlen); break; }
    /* IPC copies: (client des, local des, offset, client thread) */
    case 0x40: case 0x41: {
        struct thread *t = thr(ARG(1));
        r = t ? ipc_des_len(t, ARG(0), idx == 0x41) : KErrBadHandle;
        break;
    }
    case 0x42: case 0x43: case 0x44: case 0x45: {
        struct thread *t = thr(ARG(3));
        if (!t) { r = KErrBadHandle; break; }
        int unit = (idx & 1) ? 2 : 1;
        r = idx < 0x44 ? ipc_read(t, ARG(0), ARG(1), ARG(2), unit) : ipc_write(t, ARG(0), ARG(1), ARG(2), unit);
        break;
    }
    case 0x46: {                                  /* RThread::RequestComplete(TRequestStatus*&, code) */
        struct thread *t = thr(ARG(2));
        u32 st = uread32(ARG(0));
        if (t && st) request_complete(t, st, (s32)ARG(1));
        if (t && st && (kflags & DBGF_IPC)) {
            kprintf("[ipc] request complete %d for ", (s32)ARG(1));
            kputs16(t->o.name, t->o.namelen);
            kprintf("\n");
        }
        uwrite32(ARG(0), 0);
        break;
    }
    /* timers */
    case 0x47: {
        struct ktimer *k = (struct ktimer *)handle_lookup(me, ARG(0), O_TIMER);
        if (k && k->thread) {                      /* queued, or an inactivity timer parked */
            if (k->queued) timer_dequeue(k);
            request_complete(k->thread, k->status, KErrCancel);
            k->thread = 0;
        }
        break;
    }
    case 0x48: case 0x49: case 0x4A: case 0xC1: {  /* After(status, us), At(status, &TTime), Lock, Inactivity */
        struct ktimer *k = (struct ktimer *)handle_lookup(me, ARG(2), O_TIMER);
        if (!k) { r = KErrBadHandle; break; }
        if (k->thread) { thread_exit(me, 2, 15, (const u16 *)u"KERN-EXEC", 9); break; }
        u64 when;
        if (idx == 0x48) when = now_us() + (u32)ARG(1);
        else if (idx == 0x49) {
            extern u64 home_time_us(void);
            s64 at = (s64)(((u64)uread32(ARG(1) + 4) << 32) | uread32(ARG(1)));
            s64 d = at - (s64)home_time_us();
            when = now_us() + (d > 0 ? (u64)d : 0);
        } else if (idx == 0x4A) when = now_us() + 1000000 / 12;
        else {
            extern u64 last_activity;
            /* after secs with no user activity; quiet longer than that
             * already, it waits for the next activity and then secs more */
            k->thread = me; k->status = ARG(0); k->kind = 2; k->secs = ARG(1);
            when = last_activity + (u64)k->secs * 1000000;
            if (when > now_us()) timer_queue(k, when);
            break;
        }
        k->thread = me;
        k->status = ARG(0);
        k->kind = 0;
        timer_queue(k, when);
        break;
    }
    /* requests */
    case 0x4D:                                     /* WaitForAnyRequest     */
        if (--me->reqsem < 0) sched_block(me, T_WAIT_REQ);
        break;
    case 0x4E:                                     /* RequestSignal(n)      */
        thread_signal(me, (s32)ARG(0));
        break;
    case 0x5E: {                                   /* User::After(us, status) */
        struct ktimer *k = (struct ktimer *)obj_new(O_TIMER, sizeof(struct ktimer), me->proc);
        obj_ref(&k->o);
        k->thread = me;
        k->status = ARG(1);
        k->kind = 9;
        timer_queue(k, now_us() + (u32)ARG(0));
        break;
    }
    /* characters */
    case 0x4F: case 0x50: case 0x51: case 0x52: case 0x53:
        r = unicode_exec(idx, ARG(0));
        break;
    /* descriptor searches */
    case 0x54: case 0x55: {
        extern s32 des_match(u32, u32, int, int);
        r = des_match(ARG(0), ARG(1), ARG(2), idx == 0x54 ? 1 : 2);
        break;
    }
    case 0x56: case 0x57: {
        extern s32 des_find(u32, u32, int, int, int);
        r = des_find(ARG(0), ARG(1), ARG(2), 1, idx == 0x56 ? 1 : 2);
        break;
    }
    case 0x58: case 0x59: {
        extern s32 des_locate(u32, int, int, int);
        r = des_locate(ARG(0), ARG(1), 1, idx == 0x58 ? 1 : 2);
        break;
    }
    /* names */
    case 0x5A: case 0x5B: {
        struct kobj *o = handle_lookup(me, ARG(1), 0);
        if (!o) { r = KErrBadHandle; break; }
        if (idx == 0x5A) des_write16(ARG(0), o->name, o->namelen);
        else { u16 b[2 * NAME_MAX]; int n = obj_full_name(o, b, 2 * NAME_MAX); des_write16(ARG(0), b, n); }
        break;
    }
    case 0x5C: {                                   /* HandleInfo(THandleInfo*, h) */
        struct kobj *o = handle_lookup(me, ARG(1), 0);
        if (!o) { r = KErrBadHandle; break; }
        int inproc = 0, inthr = 0;
        for (int i = 0; i < MAX_HANDLES; i++) {
            if (me->proc->h.e[i].obj == o) inproc += me->proc->h.e[i].count;
            if (me->h && me->h->e[i].obj == o) inthr += me->h->e[i].count;
        }
        uwrite32(ARG(0), inproc);
        uwrite32(ARG(0) + 4, inthr);
        uwrite32(ARG(0) + 8, 1);
        uwrite32(ARG(0) + 12, 1);
        break;
    }
    case 0x60: r = 1; break;                       /* ELangEnglish          */
    case 0x61: case 0x62: case 0x63: case 0x64: case 0x65: case 0x66: case 0x67: {
        extern s32 locale_text(int, u32, u32);     /* day/month names, suffixes */
        r = locale_text(idx, ARG(0), ARG(1));
        break;
    }
    case 0x68: locale_refresh(ARG(0)); break;
    case 0x69: { extern void locale_set(u32); locale_set(ARG(0)); break; }
    /* thread-local state */
    case 0x6C: r = (s32)me->heap; break;
    case 0x6D: r = (s32)me->heap; me->heap = ARG(0); break;
    case 0x6E: {                                    /* time now (TTime*, offset*) */
        extern u64 home_time_us(void);
        u64 tt = home_time_us();
        uwrite32(ARG(0), (u32)tt);
        uwrite32(ARG(0) + 4, (u32)(tt >> 32));
        if (ARG(1)) uwrite32(ARG(1), 0);
        break;
    }
    case 0x70: r = (s32)(now_us() / 15625); break;  /* 64 Hz nanokernel ticks */
    case 0x72: {                                    /* TTrap::Trap: push     */
        u32 tr = ARG(0);
        uwrite32(tr + 0x40, me->trap_frame);
        uwrite32(tr + 0x48, me->trap_handler);
        me->trap_frame = tr;
        r = (s32)me->trap_handler;
        break;
    }
    case 0x73: {                                    /* pop                   */
        u32 tr = me->trap_frame;
        if (tr) me->trap_frame = uread32(tr + 0x40);
        r = (s32)tr;
        break;
    }
    case 0x74: r = (s32)me->active_scheduler; break;
    case 0x75: me->active_scheduler = ARG(0); break;
    case 0x80: {                                    /* DllTls(handle)        */
        r = 0;
        for (int i = 0; i < MAX_TLS; i++) if (me->tls[i].key == ARG(0)) { r = (s32)me->tls[i].ptr; break; }
        break;
    }
    case 0x81: r = (s32)me->trap_handler; break;
    case 0x82: r = (s32)me->trap_handler; me->trap_handler = ARG(0); break;
    case 0x8D: { s32 v = (s32)uread32(ARG(0)); uwrite32(ARG(0), v + 1); r = v; break; }
    case 0x8E: { s32 v = (s32)uread32(ARG(0)); uwrite32(ARG(0), v - 1); r = v; break; }
    case 0x9D: r = (s32)IO(IO_TIMER_US); break;    /* FastCounter: 1 MHz    */
    case 0xA8: break;                               /* heap created: a note  */
    case 0xB8: r = (s32)rom_root_dir(); break;      /* the image's one, with NGVM's additions */
    case 0xBC: r = (s32)NGVM_ROM_BASE; break;
    case 0xC9: activity(); break;                   /* User::ResetInactivityTime */
    case 0xC2: {                                    /* User::InactivityTime: seconds */
        extern u64 last_activity;
        r = (s32)((now_us() - last_activity) / 1000000);
        break;
    }
    case 0x99: case 0x9A: r = 0; break;             /* RDebug::ProfileStart/End: no profiler */
    case 0xBA: r = 0; break;                        /* RBusLogicalChannel::DoCheckBusStatus(socket):
                                                       0, the bus is up; nothing powers down here */
    case 0xBE: {                                     /* Math::Random         */
        static u32 seed = 0x12345678;
        seed = seed * 69069 + 1;
        r = (s32)seed;
        break;
    }
    /* TFindXxx::Next(result, &handle, match) */
    case 0x00: r = obj_find_next(O_CHUNK, ARG(0), ARG(1), ARG(2)); break;
    case 0x0F: r = obj_find_next(O_LIBRARY, ARG(0), ARG(1), ARG(2)); break;
    case 0x17: r = obj_find_next(O_MUTEX, ARG(0), ARG(1), ARG(2)); break;
    case 0x1C: r = obj_find_next(O_PROCESS, ARG(0), ARG(1), ARG(2)); break;
    case 0x28: r = obj_find_next(O_SEMAPHORE, ARG(0), ARG(1), ARG(2)); break;
    case 0x2D: r = obj_find_next(O_SERVER, ARG(0), ARG(1), ARG(2)); break;
    case 0x33: r = obj_find_next(O_THREAD, ARG(0), ARG(1), ARG(2)); break;
    case 0x06: case 0x0A: case 0x0B: r = KErrNotFound; break;  /* devices, channels */
    case 0x77: case 0x78: case 0x79: case 0x7A: case 0x7B: {   /* raw events */
        extern s32 event_exec(int, u32, u32);
        r = event_exec(idx, ARG(0), ARG(1));
        break;
    }
    case 0x4B: case 0x4C: {                         /* RChangeNotifier::Logon, LogonCancel */
        extern s32 notifier_exec(int, u32, u32);
        r = notifier_exec(idx, ARG(0), ARG(1));
        break;
    }
    case 0xCB: r = KErrNone; break;                 /* SetMemoryThresholds: no low-memory events */
    case 0x9B: r = 0; break;                        /* Password::IsEnabled: no password */
    case 0x9C: r = 1; break;                        /* Password::IsValid               */
    case 0xBB: {                                    /* UserSvr::DllFileName(addr, TDes16&) */
        u16 path[NAME_MAX];
        int n = rom_path_for_code(ARG(0), path, NAME_MAX);
        r = n ? des_write16(ARG(1), path, n) : KErrNotFound;
        break;
    }
    case 0xAB: { extern u32 locale_charset(void); r = (s32)locale_charset(); break; }
    case 0xAC: case 0xAD: r = KErrNone; break;     /* WsSwitchOnScreen, ...RegisterSwitchOnScreenHandling */
    case 0xB2: case 0xB3: r = 0; break;             /* Unlock/LockRamDrive: always mapped */
    case 0xC8: r = 0; break;                        /* FatUtilityFunctions: none, the FS's own */
    case 0x97:                                      /* RDebug: {opcode, thread} header */
        if (uread32(ARG(0)) == 14) {                /* Print(des)                 */
            kprintf("[rdebug] ");
            kputdes16(ARG(1));
            kprintf("\n");
            r = KErrNone;
        } else r = KErrNotSupported;
        break;
    case 0x0C: case 0x0D: case 0x0E: {              /* channel request, cancel, control */
        extern s32 chan_exec(int, u32, u32, u32, u32);
        r = chan_exec(idx, ARG(0), ARG(1), ARG(2), ARG(3));
        break;
    }
    /* code */
    case 0x10: {                                    /* RLibrary::Lookup(ord, h) */
        struct library *l = (struct library *)handle_lookup(me, ARG(1), O_LIBRARY);
        r = (l && ARG(0) >= 1 && (s32)ARG(0) <= l->export_count) ? (s32)uread32(l->export_dir + 4 * (ARG(0) - 1)) : 0;
        break;
    }
    case 0x11: { struct library *l = (struct library *)handle_lookup(me, ARG(0), O_LIBRARY); r = l ? (s32)l->entry : 0; break; }
    case 0x14: r = static_call_list(ARG(0), ARG(1), ARG(2)); break;
    case 0x16: {                                    /* RLibrary::FileName(des, h) */
        struct library *l = (struct library *)handle_lookup(me, ARG(1), O_LIBRARY);
        if (l) des_write16(ARG(0), l->fname, l->fnamelen);
        break;
    }
    case 0xA9: {                                    /* RLibrary::Type        */
        struct library *l = (struct library *)handle_lookup(me, ARG(1), O_LIBRARY);
        if (l) for (int i = 0; i < 3; i++) uwrite32(ARG(0) + 4 * i, l->uid[i]);
        break;
    }
    /* servers and sessions */
    case 0x2E: {                                    /* Receive(h, status, buf) */
        struct server *s = (struct server *)handle_lookup(me, ARG(0), O_SERVER);
        if (s) ipc_receive(me, s, ARG(1), ARG(2));
        break;
    }
    case 0x2F: { struct server *s = (struct server *)handle_lookup(me, ARG(0), O_SERVER); if (s) ipc_receive_cancel(s); break; }
    case 0x30: ipc_set_session_ptr(ARG(0), ARG(1)); break;
    case 0x31: case 0xBF: {                         /* send(h, fn, args, status) */
        struct session *s = (struct session *)handle_lookup(me, ARG(0), O_SESSION);
        r = s ? ipc_send(me, s, (s32)ARG(1), ARG(2), ARG(3)) : KErrBadHandle;
        break;
    }
    case 0x6B: r = ipc_complete(me, ARG(0), (s32)ARG(1)); break;
    /* the executor */
    case 0x76: r = executor(me, ARG(0), ARG(1), ARG(2)); break;
    /* system */
    case 0x7C: {                                    /* ScreenInfo(TPckg<TScreenInfoV01>) */
        u32 d = ARG(0), p = des_ptr(d);
        extern u32 lcd_buffer(void);
        uwrite32(p + 0, 0);                         /* iWindowHandleValid    */
        uwrite32(p + 4, 0);
        uwrite32(p + 8, 1);                         /* iScreenAddressValid   */
        uwrite32(p + 12, lcd_buffer());
        uwrite32(p + 16, LCD_W);
        uwrite32(p + 20, LCD_H);
        des_setlen(d, 24);
        break;
    }
    case 0x83: case 0x84: r = hal_get(ARG(0), ARG(1), ARG(2)); break;  /* UserHal get / set */
    case 0xB7: case 0x8F: case 0x90: case 0x91: case 0x92: {
        extern s32 drive_exec(int, u32, u32, u32, u32);
        r = drive_exec(idx, ARG(0), ARG(1), ARG(2), ARG(3));
        break;
    }
    case 0x7D: case 0x7E: case 0x7F: {
        extern s32 dll_global_exec(int, u32, u32, u32, u32);
        r = dll_global_exec(idx, ARG(0), ARG(1), ARG(2), ARG(3));
        break;
    }
    case 0x87: case 0x88: break;                    /* Ws/FsRegisterThread   */
    case 0x85: r = 0; break;                        /* KernelStartup         */
    case 0x89: break;                               /* Beep                  */
    default: {
        trace_stack(c->r[13]);
        kpanic("unimplemented exec %x (%x %x %x %x) in thread %d lr %p", n, ARG(0), ARG(1), ARG(2), ARG(3), me->id, c->r[14]);
    }
    }
    if (kflags & DBGF_EXEC) kprintf("[exec]   -> %x\n", r);
    c->r[0] = (u32)r;
}
