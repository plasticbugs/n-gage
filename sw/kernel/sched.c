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
u64 idle_us;                            /* time the idle thread has held the CPU;
                                           the host reads it to measure load */
u64 idle_since;                         /* when it last got it */
static struct process *mapped_proc;     /* whose data window is mapped     */
static u32 run_stamp;
static int slice_expired;
static int need_resched = 1;             /* a thread may now outrank cur    */
/* The threads woken since the last choice, when that is all that changed:
 * then only they can outrank cur, and schedule() need not look at every
 * ready thread.  WOKEN_ALL says anything else changed (a resume, a
 * priority), or more woke than fit. */
#define WOKEN_MAX 4
#define WOKEN_ALL (WOKEN_MAX + 1)
static struct thread *woken[WOKEN_MAX];
static int nwoken = WOKEN_ALL;
static u64 slice_end;
static struct ktimer *tq;                /* sorted by expiry                */

/* The phone's spare time.  A game that left the phone's CPU idle some of the
 * time can leave NGVM's none, and a thread the firmware runs only in spare
 * time then never runs: MediaServer finishes creating a stream on a thread
 * at EPriorityAbsoluteVeryLow (100).  So when neither the idle thread nor a
 * lent slice has run for LEND_EVERY_US, the ready thread at 1-LEND_PRIO that
 * has waited longest gets LEND_US, whatever wakes meanwhile.
 *
 * Nothing above LEND_PRIO, nor at 0, is lent: there the time would run a
 * thread while one EKA1 would run first is ready, and the order the
 * firmware starts things in changes.  Lending to every thread below the top
 * ran the game's launcher (launch.c, at 0) during the boot, and Sonic N
 * opened its window before the phone's splash screen, which covered it for
 * good. */
#define LEND_EVERY_US 50000
#define LEND_US 2000
#define LEND_PRIO 100                   /* EPriorityAbsoluteVeryLow */
static struct thread *lent;              /* holds the CPU until slice_end   */
static u64 last_spare;                   /* when the threads below the top last could run */

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

void thread_reprioritise(struct thread *t) { t->prio = effective_prio(t); need_resched = 1; nwoken = WOKEN_ALL; }

static int runnable(struct thread *t)
{
    return t->state == T_READY && t->suspend_count == 0;
}

/* The threads that may be ready.  Every ready thread but the idle one is in
 * it, so a choice looks at these and not at every thread object (the dead
 * ones included, two cache misses each).  A thread goes in when it is woken
 * or resumed, the only ways one becomes ready, and comes out when a choice
 * finds it is not.  rdy_all says more were ready than fit, and the next
 * choice rebuilds it from every thread. */
#define RDY_MAX 64
static struct thread *rdy[RDY_MAX];
static int nrdy, rdy_all;

static void rdy_add(struct thread *t)
{
    if (t->in_rdy || t == idle_thread) return;
    if (nrdy == RDY_MAX) { rdy_all = 1; return; }
    t->in_rdy = 1;
    rdy[nrdy++] = t;
}

/* One resume: the thread runs when its count reaches zero. */
void thread_resume(struct thread *t)
{
    if (t->suspend_count > 0 && --t->suspend_count == 0) {
        need_resched = 1; nwoken = WOKEN_ALL;
        rdy_add(t);
    }
}

static void program_timer(void)
{
    u64 next = slice_end;
    if (tq && tq->expiry < next) next = tq->expiry;
    if (launch_due < next) next = launch_due;
    IO(IO_TIMER_CMP) = (u32)next;
}

void sched_init(void)
{
    IO(IO_IRQ_ENABLE) = IRQ_TIMER | IRQ_VBLANK | IRQ_FETCH;
    slice_end = now_us() + SLICE_US;
    program_timer();
}

void sched_wake(struct thread *t)
{
    if (t->state == T_DEAD) return;
    t->state = T_READY;
    t->wait_obj = 0;
    need_resched = 1;
    rdy_add(t);
    if (nwoken < WOKEN_MAX) woken[nwoken++] = t;
    else nwoken = WOKEN_ALL;
}

void sched_block(struct thread *t, enum tstate st) { t->state = st; }

/* Whether t is chosen before b: the higher priority, then the one that has
 * waited longest, then the newer object -- the one a walk of every thread
 * (newest first, obj_new) meets first. */
static int before(struct thread *t, struct thread *b)
{
    if (t->prio != b->prio) return t->prio > b->prio;
    s32 d = (s32)(t->run_stamp - b->run_stamp);
    return d < 0 || (d == 0 && t->o.seq > b->o.seq);
}

/* The best of every thread object: the choice before the ready set, and the
 * fallback when too many are ready for it. */
static struct thread *walk_all(void)
{
    struct thread *best = 0;
    for (struct kobj *o = obj_first(O_THREAD); o; o = o->next) {
        struct thread *t = (struct thread *)o;
        if (!runnable(t) || t == idle_thread) continue;
        if (!best || t->prio > best->prio ||
            (t->prio == best->prio && (s32)(t->run_stamp - best->run_stamp) < 0))
            best = t;
    }
    return best;
}

/* The highest ready thread, of those the longest waiting; the running
 * thread keeps its slice against equals. */
static struct thread *walk_best(void)
{
    struct thread *best = 0;
    if (rdy_all) {
        for (int i = 0; i < nrdy; i++) rdy[i]->in_rdy = 0;
        nrdy = 0; rdy_all = 0;
        for (struct kobj *o = obj_first(O_THREAD); o; o = o->next)
            if (runnable((struct thread *)o)) rdy_add((struct thread *)o);
    }
    if (rdy_all) best = walk_all();
    else for (int i = 0; i < nrdy; ) {
        struct thread *t = rdy[i];
        if (!runnable(t)) { t->in_rdy = 0; rdy[i] = rdy[--nrdy]; continue; }
        if (!best || before(t, best)) best = t;
        i++;
    }
#ifdef SCHED_CHECK
    struct thread *w = walk_all();
    if (w != best) kprintf("[sched] check: the ready set chose %p, the walk %p\n", best, w);
#endif
    if (best && cur && cur != best && runnable(cur) && cur != idle_thread &&
        cur->prio == best->prio && !slice_expired)
        best = cur;
    return best;
}

void schedule(void)
{
    /* Nothing has woken, resumed or changed priority since the last choice,
     * and cur can still run: it stays.  Most execs end here. */
    if (!need_resched && !slice_expired && cur && (cur == idle_thread || runnable(cur)))
        return;
    need_resched = 0;
    u64 now = now_us();
    struct thread *best;
    /* Only wakes since the last choice, which left no ready thread above
     * cur, and cur can go on: a woken thread above cur runs, else cur keeps
     * its slice -- what the walk would choose.  A kernel built with
     * SCHED_CHECK walks as well and says when the two differ, as it does
     * for the ready set against every thread. */
    if (nwoken <= WOKEN_MAX && cur && cur != idle_thread && runnable(cur) && !slice_expired &&
        !lent && now - last_spare < LEND_EVERY_US) {
        best = cur;
        for (int i = 0; i < nwoken; i++) {
            struct thread *t = woken[i];
            if (!runnable(t) || t == idle_thread || t == best || t->prio < best->prio) continue;
            if (t->prio > best->prio || (best != cur && (s32)(t->run_stamp - best->run_stamp) < 0))
                best = t;
        }
#ifdef SCHED_CHECK
        struct thread *w = walk_best();
        if (w != best) kprintf("[sched] check: the woken chose %p, the walk %p\n", best, w);
#endif
        nwoken = 0;
        goto chosen;
    }
    nwoken = 0;
    best = walk_best();
    if (cur == idle_thread) last_spare = now;
    if (lent) {                         /* a lent slice runs out, or its thread waits */
        if (lent == cur && runnable(cur) && !slice_expired) best = cur;
        else { lent = 0; last_spare = now; }
    } else if (best && now - last_spare >= LEND_EVERY_US) {
        /* and only to the highest ready thread of its process, so that one
         * never runs while its own process has a thread EKA1 would run first */
        static u32 pass;
        pass++;
        for (struct kobj *o = obj_first(O_THREAD); o; o = o->next) {
            struct thread *t = (struct thread *)o;
            if (!runnable(t) || t == idle_thread) continue;
            if (t->proc->ready_pass != pass || t->prio > t->proc->ready_top) {
                t->proc->ready_pass = pass;
                t->proc->ready_top = t->prio;
            }
        }
        struct thread *s = 0;
        for (struct kobj *o = obj_first(O_THREAD); o; o = o->next) {
            struct thread *t = (struct thread *)o;
            if (!runnable(t) || t->prio < 1 || t->prio > LEND_PRIO ||
                t->prio >= best->prio || t->prio < t->proc->ready_top) continue;
            if (!s || (s32)(t->run_stamp - s->run_stamp) < 0) s = t;
        }
        if (s) best = lent = s;
        else last_spare = now;          /* nothing below the top is waiting */
    }
    if (!best) best = idle_thread;
    if (best == idle_thread) last_spare = now;
chosen:
    if (best != cur || slice_expired) {
        slice_expired = 0;
        slice_end = now + (best == lent ? LEND_US : SLICE_US);
        program_timer();
    }
    if (best != cur && (kflags & DBGF_SCHED)) {
        kprintf("[sched] -> ");
        kputs16(best->o.name, best->o.namelen);
        kprintf(" (%d) pc %p%s\n", best->prio, best->ctx.pc, best == lent ? " lent" : "");
    }
    best->run_stamp = ++run_stamp;
    if (best != cur) {
        if (cur == idle_thread) idle_us += now - idle_since;
        if (best == idle_thread) idle_since = now;
    }
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
    IO(IO_WIN_ID) = p ? (u32)p->winid : 0;
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

/* When a user's timer ends.  EKA1 served RTimer::After and At and
 * User::After from its 1/64 s tick, so a short wait ended at the next tick
 * and the threads below the waiter ran meanwhile.  To the microsecond,
 * After(0) and After(1) ended at once: Atari Masterpieces Vol. 1 polled with
 * After(1) 807 times a second, Rayman 3 with After(0), the threads they
 * waited on never ran, and on the RTL, whose timer is exact, both hung (the
 * reference's timer fires at its slice's end, 0.67 ms late at 30 MIPS, and
 * let them through).  A millisecond is room enough for those threads.  The
 * tick itself would be more than games can spare on a CPU slower than the
 * phone's: Virtua Cop waits After(1000) between frames, and rounded to the
 * tick it drew a quarter fewer of them. */
u64 user_expiry(u64 when)
{
    u64 soonest = now_us() + MIN_WAIT_US;
    return when < soonest ? soonest : when;
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
    u32 was = kflags;
    kflags = IO(IO_DBG_FLAGS);            /* the host may change them as it runs */
    if (kflags & ~was & DBGF_THREADS) thread_dump();
    while (tq && tq->expiry <= now) {
        struct ktimer *k = tq;
        tq = k->qnext;
        k->queued = 0;
        if (k->kind == 10) {                        /* a session waiting for its server */
            extern void session_wait_tick(struct ktimer *);
            session_wait_tick(k);
            continue;
        }
        if (k->thread) request_complete(k->thread, k->status, KErrNone);
        k->thread = 0;
        if (k->kind == 9) obj_unref(&k->o);        /* User::After's own timer */
    }
    if (now >= slice_end) slice_expired = 1;
    launch_poll();
    drive_poll();
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
        if (t == cur) {                 /* its own: from where */
            u32 sp = t->ctx.r[13];
            kprintf("  pc %p lr %p sp %p:", t->ctx.pc, t->ctx.r[14], sp);
            for (int i = 0; i < 24 && sp >= t->stack_base && sp + 4 * i < t->stack_base + t->stack_size; i++)
                kprintf(" %x", *(u32 *)(sp + 4 * i));
            kprintf("\n");
        }
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
    /* the caches may hold the window's lines, tagged with its number: they
     * go before the pages or the number are handed out again */
    if (p->win_pages) {
        IO(IO_CACHE_FLUSH) = 1;
        winid_free(p->winid);
    }
    p->win_pages = 0;
    if (p->chunk) { vm_release(p->chunk); p->chunk = 0; }   /* a RAM image (vm_release flushes) */
}

/* Every live thread: its state, where it stopped, and the ROM code
 * addresses on its stack (return addresses among them), for reading where
 * a thread waits without tracing every exec. */
void stack_scan(struct thread *t, int max)
{
    u32 rom_end = NGVM_ROM_BASE + IO(IO_ROM_SIZE);
    u32 sp = t->ctx.r[13], top = t->stack_base + t->stack_size;
    int n = 0;
    if (t->stack_base && sp >= t->stack_base && sp < top)
        for (u32 a = sp & ~3u; a < top && n < max; a += 4) {
            u32 w = *(u32 *)a;
            if (w > NGVM_ROM_BASE && w < rom_end) { kprintf(" %x", w); n++; }
        }
    kprintf("\n");
}

void thread_dump(void)
{
    static const char st[] = "CRQSMUD";
    for (struct kobj *o = obj_first(O_THREAD); o; o = o->next) {
        struct thread *t = (struct thread *)o;
        if (t->state == T_DEAD) continue;
        kputs16(t->proc->o.name, t->proc->o.namelen);
        kprintf("::");
        kputs16(t->o.name, t->o.namelen);
        kprintf(" %c prio %d req %d pc %p lr %p sp %p stack %p+%x:", st[t->state], t->prio, t->reqsem,
                t->ctx.pc, t->ctx.r[14], t->ctx.r[13], t->stack_base, t->stack_size);
        stack_scan(t, 10);
    }
}
