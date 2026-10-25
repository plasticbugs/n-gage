/* Raw events: the window server's input.
 *
 * The window server captures the event hook (exec 0xC00077) and asks for
 * events one at a time (0xC00079, a TPckgBuf<TRawEvent> and a status).  The
 * kernel queues what the keys and the system add (0xC0007B, and
 * event_add from the key hardware) until it is asked.
 *
 * EKA1's TRawEvent is 16 bytes: { TType iType; TUint iTicks; union {
 * TPoint pos; TInt scanCode; TInt modifiers } iU } (e32svr.h).  Ticks are
 * the 64 Hz ticks of exec 0x70. */
#include "kobj.h"

#define NEVENTS 64
static struct { u32 w[4]; } q[NEVENTS];
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
    s32 r = des_write8(wait_des, (const u8 *)q[qhead].w, 16);
    proc_switch_in(was);
    qhead = (qhead + 1) % NEVENTS;
    request_complete(t, wait_status, r);
}

/* from the kernel: the key hardware, the power button */
void event_add(u32 type, u32 a, u32 b)
{
    int n = (qtail + 1) % NEVENTS;
    if (n == qhead) return;                   /* full: drop, as a busy phone would */
    q[qtail].w[0] = type; q[qtail].w[1] = (u32)(now_us() / 15625);
    q[qtail].w[2] = a; q[qtail].w[3] = b;
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
        event_add(uread32(a0), uread32(a0 + 8), uread32(a0 + 12));
        return KErrNone;
    }
    return KErrNotSupported;
}

/* The keys: IO_KEYS is read at each vblank, each button pressed holds a
 * phone key, and each phone key that goes down or up becomes a raw key
 * event with an N-Gage standard scan code (e32keys.h).  The game keys of
 * the phone are 5 and 7; the soft keys and the OK key run the menus.  The
 * menu can put A, B, X, Y, L or R on any digit key, * or # instead
 * (IO_KEYMAP), so two buttons may hold one key: it goes up when the last
 * is let go.
 *
 * Bits 12-26 are the on-screen keypad's keys (KEY_PAD_*, ngvm_hw.h): the
 * digits, *, #, the soft keys and C, which the pad has no button for.  The
 * scan codes for * and C are S60's ('*', EStdKeyBackspace), as # (0x7F) and
 * the soft keys already were here; that the firmware's key tables turn them
 * into '*' and the clear key has not been seen in a game yet. */
static const u8 scan[KEY_BITS] = {
    0x10, 0x11, 0x0E, 0x0F,     /* d-pad: EStdKey{Up,Down,Left,Right}Arrow */
    '5',  '7',                  /* A, B: the N-Gage's game keys            */
    0xA7, '9',                  /* X: OK (EStdKeyDevice3), Y: 9            */
    0xA4, 0xA5,                 /* L, R: left and right soft keys          */
    0x7F, 0xA7,                 /* select: #, start: OK                    */
    '0', '1', '2', '3', '4',    /* the keypad: 0-9                         */
    '5', '6', '7', '8', '9',
    '*',  0x7F,                 /* *, # (EStdKeyHash)                      */
    0xA4, 0xA5,                 /* left and right soft keys                */
    0x01,                       /* C: EStdKeyBackspace                     */
};

void keys_poll(void)
{
    static u8 held[KEY_BITS];                 /* the phone keys down, distinct */
    static int nheld;
    u32 now = IO(IO_KEYS) & ((1u << KEY_BITS) - 1), map = IO(IO_KEYMAP);
    u8 down[KEY_BITS];
    int n = 0;
    for (int i = 0; i < KEY_BITS; i++) {
        if (!(now & (1u << i))) continue;
        u8 k = scan[i];
        if (i >= 4 && i <= 9) {               /* A B X Y L R: 4 bits each, A first */
            u32 f = (map >> (4 * (i - 4))) & 15;
            if (f >= 1 && f <= 10) k = (u8)('0' + f - 1);
            else if (f == 11) k = '*';
            else if (f == 12) k = 0x7F;       /* # (EStdKeyHash) */
        }
        int j = 0;
        while (j < n && down[j] != k) j++;
        if (j == n) down[n++] = k;
    }
    int ch = 0;
    for (int i = 0; i < nheld; i++) {         /* up: held before, not now */
        int j = 0;
        while (j < n && down[j] != held[i]) j++;
        if (j == n) { event_add(4, held[i], 0); ch = 1; }            /* EKeyUp */
    }
    for (int j = 0; j < n; j++) {             /* down: held now, not before */
        int i = 0;
        while (i < nheld && held[i] != down[j]) i++;
        if (i == nheld) { event_add(3, down[j], 0); ch = 1; }        /* EKeyDown */
    }
    for (int j = 0; j < n; j++) held[j] = down[j];
    nheld = n;
    if (ch) activity();
}
