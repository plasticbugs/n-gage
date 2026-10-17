/* Raw events: the window server's input.
 *
 * The window server captures the event hook (exec 0xC00077) and asks for
 * events one at a time (0xC00079, a TPckgBuf<TRawEvent> and a status).  The
 * kernel queues what the keys and the system add (0xC0007B, and
 * event_add from the key hardware) until it is asked.
 *
 * EKA1's TRawEvent is 12 bytes: { TType iType; union { TPoint pos;
 * TInt scanCode } iU }. */
#include "kobj.h"

#define NEVENTS 64
static struct { u32 w[3]; } q[NEVENTS];
static int qhead, qtail;
static struct thread *hook;                   /* the window server's thread */
static struct thread *waiter;
static u32 wait_des, wait_status;

static void deliver(void)
{
    if (!waiter || qhead == qtail) return;
    struct thread *t = waiter;
    waiter = 0;
    extern struct process *proc_mapped(void);
    struct process *was = proc_mapped();
    proc_switch_in(t->proc);
    s32 r = des_write8(wait_des, (const u8 *)q[qhead].w, 12);
    proc_switch_in(was);
    qhead = (qhead + 1) % NEVENTS;
    request_complete(t, wait_status, r);
}

/* from the kernel: the key hardware, the power button */
void event_add(u32 type, u32 a, u32 b)
{
    int n = (qtail + 1) % NEVENTS;
    if (n == qhead) return;                   /* full: drop, as a busy phone would */
    q[qtail].w[0] = type; q[qtail].w[1] = a; q[qtail].w[2] = b;
    qtail = n;
    if (kflags & DBGF_IPC) kprintf("[event] add %d (%x %x)\n", type, a, b);
    deliver();
}

s32 event_exec(int idx, u32 a0, u32 a1)
{
    switch (idx) {
    case 0x77:                                /* CaptureEventHook */
        if (hook && hook != cur && hook->state != T_DEAD) return KErrInUse;
        hook = cur;
        return KErrNone;
    case 0x78:                                /* ReleaseEventHook */
        if (hook == cur) hook = 0;
        return KErrNone;
    case 0x79:                                /* RequestEvent(TRawEventBuf&, TRequestStatus&) */
        if (cur != hook) return KErrAccessDenied;
        uwrite32(a1, (u32)KRequestPending);   /* the stub is bare: the kernel marks it */
        waiter = cur;
        wait_des = a0;
        wait_status = a1;
        deliver();
        return KErrNone;
    case 0x7A:                                /* RequestEventCancel */
        if (waiter == cur) {
            waiter = 0;
            request_complete(cur, wait_status, KErrCancel);
        }
        return KErrNone;
    case 0x7B:                                /* AddEvent(const TRawEvent&) */
        event_add(uread32(a0), uread32(a0 + 4), uread32(a0 + 8));
        return KErrNone;
    }
    return KErrNotSupported;
}
