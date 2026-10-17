/* Threads: who runs, who waits, and the timers that wake them.
 *
 * Highest effective priority runs; a running thread keeps the CPU against
 * others of its own priority until its time slice ends.  The kernel itself
 * never blocks: an exec that waits marks the caller and picks another thread
 * before returning to user mode. */
#include "kobj.h"
#include "mm.h"

#define SLICE_US 20000

struct thread *cur;
struct thread *idle_thread;
static struct process *mapped_proc;     /* whose data window is mapped     */
static u32 run_stamp;
static int slice_expired;
static u64 slice_end;
static struct ktimer *tq;                /* sorted by expiry                */

u64 now_us(void)
{
    u32 lo = IO(IO_TIMER_US);
    u32 hi = IO(IO_TIMER_US_HI);
    return ((u64)hi << 32) | lo;
}

struct thread *thread_by_id(u32 id)
{
    for (struct kobj *o = obj_first(O_THREAD); o; o = o->next)
        if (((struct thread *)o)->id == id) return (struct thread *)o;
    return 0;
}

static int effective_prio(struct thread *t)
{
    int r = t->prio_rel;
    if (r >= 100) return r;               /* EPriorityAbsolute*              */
    if (r <= -30) return 1;               /* EPriorityNull                   */
    return t->proc->prio + r;
}

void thread_reprioritise(struct thread *t) { t->prio = effective_prio(t); }

static int runnable(struct thread *t)
{
    return t->state == T_READY && t->suspend_count == 0;
}

static void program_timer(void)
{
    u64 next = slice_end;
    if (tq && tq->expiry < next) next = tq->expiry;
    IO(IO_TIMER_CMP) = (u32)next;
}

void sched_init(void)
{
    IO(IO_IRQ_ENABLE) = IRQ_TIMER;
    slice_end = now_us() + SLICE_US;
    program_timer();
}

void sched_wake(struct thread *t)
{
    if (t->state == T_DEAD) return;
    t->state = T_READY;
    t->wait_obj = 0;
}

void sched_block(struct thread *t, enum tstate st) { t->state = st; }

void schedule(void)
{
    struct thread *best = 0;
    for (struct kobj *o = obj_first(O_THREAD); o; o = o->next) {
        struct thread *t = (struct thread *)o;
        if (!runnable(t) || t == idle_thread) continue;
        if (!best || t->prio > best->prio ||
            (t->prio == best->prio && (s32)(t->run_stamp - best->run_stamp) < 0))
            best = t;
    }
    /* the running thread keeps its slice against equals */
    if (best && cur && cur != best && runnable(cur) && cur != idle_thread &&
        cur->prio == best->prio && !slice_expired)
        best = cur;
    if (!best) best = idle_thread;
    if (best != cur || slice_expired) {
        slice_expired = 0;
        slice_end = now_us() + SLICE_US;
        program_timer();
    }
    if (best != cur && (kflags & DBGF_SCHED)) {
        kprintf("[sched] -> ");
        kputs16(best->o.name, best->o.namelen);
        kprintf(" (%d) pc %p\n", best->prio, best->ctx.pc);
    }
    best->run_stamp = ++run_stamp;
    cur = best;
    cur_ctx = &best->ctx;
    if (best->proc && best->proc != mapped_proc && best != idle_thread) proc_switch_in(best->proc);
}

/* Map p's data window (or nothing, if it has none). */
void proc_switch_in(struct process *p)
{
    if (p == mapped_proc) return;
    if (mapped_proc)
        for (int i = 0; i < mapped_proc->win_pages; i++) pt_set(NGVM_PT_CHUNK + i, NGVM_PT_NONE);
    mapped_proc = p;
    if (!p) return;
    for (int i = 0; i < p->win_pages; i++) pt_set(NGVM_PT_CHUNK + i, p->win[i]);
}

struct process *proc_mapped(void) { return mapped_proc; }

/* ---- the request semaphore -------------------------------------------------- */
void thread_signal(struct thread *t, int n)
{
    t->reqsem += n;
    if (t->state == T_WAIT_REQ && t->reqsem >= 0) sched_wake(t);
}

void request_complete(struct thread *t, u32 status, s32 value)
{
    if (t->state == T_DEAD) return;
    if (status) {
        struct process *was = mapped_proc;
        if (status - NGVM_DATA_BASE < NGVM_DATA_SIZE && t->proc != mapped_proc) proc_switch_in(t->proc);
        uwrite32(status, (u32)value);
        if (was && was != mapped_proc) proc_switch_in(was);
    }
    thread_signal(t, 1);
}

/* ---- semaphores and mutexes ---------------------------------------------- */
static void waitq_add(struct thread **q, struct thread *t)
{
    t->wait_next = 0;
    while (*q) q = &(*q)->wait_next;
    *q = t;
}

static struct thread *waitq_pop(struct thread **q)
{
    struct thread *t = *q;
    if (t) *q = t->wait_next;
    return t;
}

static void waitq_remove(struct thread **q, struct thread *t)
{
    for (; *q; q = &(*q)->wait_next)
        if (*q == t) { *q = t->wait_next; return; }
}

int sem_wait(struct semaphore *s)
{
    if (--s->count >= 0) return 0;
    cur->wait_obj = &s->o;
    waitq_add(&s->waiters, cur);
    sched_block(cur, T_WAIT_SEM);
    return 1;
}

void sem_signal(struct semaphore *s, int n)
{
    while (n-- > 0) {
        if (++s->count <= 0) {
            struct thread *t = waitq_pop(&s->waiters);
            if (t) sched_wake(t);
        }
    }
}

int mutex_wait(struct mutex *m)
{
    if (m->holder == cur) { m->hold++; return 0; }
    if (!m->holder) { m->holder = cur; m->hold = 1; return 0; }
    cur->wait_obj = &m->o;
    waitq_add(&m->waiters, cur);
    sched_block(cur, T_WAIT_MUTEX);
    return 1;
}

void mutex_signal(struct mutex *m)
{
    if (m->holder != cur) kprintf("[kern] mutex signalled by a thread that does not hold it\n");
    if (--m->hold > 0) return;
    m->holder = waitq_pop(&m->waiters);
    if (m->holder) { m->hold = 1; sched_wake(m->holder); }
}

/* ---- timers --------------------------------------------------------------------- */
void timer_dequeue(struct ktimer *k)
{
    if (!k->queued) return;
    for (struct ktimer **pp = &tq; *pp; pp = &(*pp)->qnext)
        if (*pp == k) { *pp = k->qnext; break; }
    k->queued = 0;
}

void timer_queue(struct ktimer *k, u64 when)
{
    timer_dequeue(k);
    k->expiry = when;
    struct ktimer **pp = &tq;
    while (*pp && (*pp)->expiry <= when) pp = &(*pp)->qnext;
    k->qnext = *pp;
    *pp = k;
    k->queued = 1;
    program_timer();
}

/* User activity: keys, and User::ResetInactivityTime.  Inactivity timers
 * count from the last of it. */
u64 last_activity;

void activity(void)
{
    last_activity = now_us();
    for (struct kobj *o = obj_first(O_TIMER); o; o = o->next) {
        struct ktimer *k = (struct ktimer *)o;
        if (k->kind != 2 || !k->thread) continue;
        if (k->queued) timer_dequeue(k);
        timer_queue(k, last_activity + (u64)k->secs * 1000000);
    }
}

void timer_tick(void)
{
    u64 now = now_us();
    while (tq && tq->expiry <= now) {
        struct ktimer *k = tq;
        tq = k->qnext;
        k->queued = 0;
        if (k->thread) request_complete(k->thread, k->status, KErrNone);
        k->thread = 0;
        if (k->kind == 9) obj_unref(&k->o);        /* User::After's own timer */
    }
    if (now >= slice_end) slice_expired = 1;
    program_timer();
}

/* ---- leaving -------------------------------------------------------------------- */
static void logons_complete(struct logon **l, s32 reason)
{
    while (*l) {
        struct logon *x = *l;
        *l = x->next;
        request_complete(x->t, x->status, reason);
        kfree(x);
    }
}

void thread_exit(struct thread *t, int type, s32 reason, const u16 *cat, int catlen)
{
    if (t->state == T_DEAD) return;
    if (kflags & DBGF_SCHED) {
        kprintf("[sched] exit ");
        kputs16(t->o.name, t->o.namelen);
        kprintf(" type %d reason %d\n", type, reason);
    }
    if (type == 2) {                    /* a panic is always worth seeing */
        kprintf("[kern] PANIC thread ");
        kputs16(t->o.name, t->o.namelen);
        kprintf(" in ");
        kputs16(t->proc->o.name, t->proc->o.namelen);
        kprintf(": ");
        kputs16(cat, catlen);
        kprintf(" %d\n", reason);
    }
    extern void notify_changes(u32 flags);
    notify_changes(0x04);               /* EChangesThreadDeath */
    extern void undertaker_notify(struct thread *);
    undertaker_notify(t);
    /* out of whatever it was waiting on */
    if (t->state == T_WAIT_SEM) waitq_remove(&((struct semaphore *)t->wait_obj)->waiters, t);
    if (t->state == T_WAIT_MUTEX) waitq_remove(&((struct mutex *)t->wait_obj)->waiters, t);
    for (struct kobj *o = obj_first(O_MUTEX); o; o = o->next) {
        struct mutex *m = (struct mutex *)o;
        if (m->holder == t) { m->hold = 1; struct thread *c = cur; cur = t; mutex_signal(m); cur = c; }
    }
    t->state = T_DEAD;
    t->exit_type = type;
    t->exit_reason = reason;
    if (catlen > 16) catlen = 16;
    memcpy(t->exit_cat, cat, catlen * 2);
    t->exit_catlen = catlen;
    /* its thread-owned handles */
    if (t->h)
        for (int i = 0; i < MAX_HANDLES; i++)
            if (t->h->e[i].obj) handle_close(t, ((u32)t->h->e[i].gen << 16) | (i + 1) | HANDLE_THREAD_OWNED);
    logons_complete(&t->logons, type == 0 ? reason : (type == 1 ? reason : reason));
    struct process *p = t->proc;
    p->nthreads--;
    if (t == p->main || p->nthreads == 0) proc_kill(p, type, reason, cat, catlen);
}

void proc_kill(struct process *p, int type, s32 reason, const u16 *cat, int catlen)
{
    if (p->exit_type != 3) return;      /* already dead */
    p->exit_type = type;
    p->exit_reason = reason;
    if (catlen > 16) catlen = 16;
    memcpy(p->exit_cat, cat, catlen * 2);
    p->exit_catlen = catlen;
    kprintf("[kern] process ");
    kputs16(p->o.name, p->o.namelen);
    kprintf(" exits: type %d reason %d\n", type, reason);
    for (struct kobj *o = obj_first(O_THREAD); o; o = o->next) {
        struct thread *t = (struct thread *)o;
        if (t->proc == p && t->state != T_DEAD) thread_exit(t, type, reason, cat, catlen);
    }
    /* close every handle the process held, so servers hear of it */
    struct thread *any = p->main;
    if (any)
        for (int i = 0; i < MAX_HANDLES; i++)
            if (p->h.e[i].obj) handle_close(any, ((u32)p->h.e[i].gen << 16) | (i + 1));
    logons_complete(&p->logons, reason);
    if (mapped_proc == p) {
        for (int i = 0; i < p->win_pages; i++) pt_set(NGVM_PT_CHUNK + i, NGVM_PT_NONE);
        mapped_proc = 0;
    }
    for (int i = 0; i < p->win_pages; i++) pg_free(p->win[i]);
    p->win_pages = 0;
}
