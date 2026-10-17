/* RChangeNotifier: one request per notifier, completed with the TChanges
 * flags that happened since the last.
 *
 *   executor 0x36  create {TPtr8(&handle), ...}
 *   exec 0x80004B  Logon(&status, handle)
 *   exec 0x80004C  LogonCancel(handle)
 *
 * As EKA1 documents it, the first Logon completes at once with every change
 * flag: 0x01 locale, 0x02 midnight, 0x04 thread death, 0x08 power, 0x10
 * system time, 0x20 free memory.  0x40, out of memory, is left out: it never
 * happened.  After that the kernel reports thread deaths (notify_changes). */
#include "kobj.h"

struct notifier {
    struct kobj o;
    struct thread *t;                         /* the waiting thread, if any */
    u32 status;
    u32 changes;                              /* not yet reported           */
};

s32 notifier_create(struct thread *t, u32 a, int towned)
{
    struct notifier *n = (struct notifier *)obj_new(O_NOTIFIER, sizeof(struct notifier), t->proc);
    n->changes = 0x3F;
    u32 h = handle_make(t, &n->o, towned);
    u32 d = uread32(a);
    uwrite32(des_ptr(d), h);
    des_setlen(d, 4);
    return KErrNone;
}

static void report(struct notifier *n)
{
    if (!n->t || !n->changes) return;
    struct thread *t = n->t;
    n->t = 0;
    s32 c = (s32)n->changes;
    n->changes = 0;
    request_complete(t, n->status, c);
}

void notify_changes(u32 flags)
{
    for (struct kobj *o = obj_first(O_NOTIFIER); o; o = o->next) {
        struct notifier *n = (struct notifier *)o;
        n->changes |= flags;
        report(n);
    }
}

s32 notifier_exec(int idx, u32 a0, u32 a1)
{
    if (idx == 0x4B) {
        struct notifier *n = (struct notifier *)handle_lookup(cur, a1, O_NOTIFIER);
        if (!n) return KErrBadHandle;
        if (n->t) return KErrInUse;
        uwrite32(a0, (u32)KRequestPending);   /* EUser does not mark it */
        n->t = cur;
        n->status = a0;
        report(n);
        return KErrNone;
    }
    struct notifier *n = (struct notifier *)handle_lookup(cur, a0, O_NOTIFIER);
    if (!n) return KErrBadHandle;
    if (n->t) {
        struct thread *t = n->t;
        n->t = 0;
        request_complete(t, n->status, KErrCancel);
    }
    return KErrNone;
}

/* ---- RUndertaker: told of every thread death ----------------------------
 *   executor 0x44  create {TPtr8(&handle), ...}
 *   executor 0x45  logon {handle, &status, &thread handle}  (EUser marks it)
 *   executor 0x46  logon cancel {handle}
 * A death completes the logon with KErrDied, and a handle to the dead
 * thread in the caller's process. */
struct undertaker {
    struct kobj o;
    struct thread *t;
    u32 status, hout;
};

s32 undertaker_executor(struct thread *t, int sub, u32 a, int towned)
{
    if (sub == 0x44) {
        struct undertaker *u = (struct undertaker *)obj_new(O_UNDERTAKER, sizeof(struct undertaker), t->proc);
        u32 h = handle_make(t, &u->o, towned);
        u32 d = uread32(a);
        uwrite32(des_ptr(d), h);
        des_setlen(d, 4);
        return KErrNone;
    }
    struct undertaker *u = (struct undertaker *)handle_lookup(t, uread32(a), O_UNDERTAKER);
    if (!u) return KErrBadHandle;
    if (sub == 0x45) {
        if (u->t) return KErrInUse;
        u->t = t;
        u->status = uread32(a + 4);
        u->hout = uread32(a + 8);
        return KErrNone;
    }
    if (u->t) {                               /* 0x46 */
        struct thread *w = u->t;
        u->t = 0;
        request_complete(w, u->status, KErrCancel);
    }
    return KErrNone;
}

void undertaker_notify(struct thread *dead)
{
    extern struct process *proc_mapped(void);
    for (struct kobj *o = obj_first(O_UNDERTAKER); o; o = o->next) {
        struct undertaker *u = (struct undertaker *)o;
        if (!u->t) continue;
        struct thread *w = u->t;
        u->t = 0;
        u32 h = handle_make(w, &dead->o, 0);
        struct process *was = proc_mapped();
        proc_switch_in(w->proc);
        uwrite32(u->hout, h);
        proc_switch_in(was);
        request_complete(w, u->status, KErrDied);
    }
}
