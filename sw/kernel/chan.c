/* Logical channels: the user side's door to device drivers.
 *
 * EKA1 runs the LDD and PDD from the ROM in the kernel; NGVM does not run
 * kernel-side code at all, so each device a game or server opens is modelled
 * here at its channel interface, keyed by the LDD's name:
 *
 *   executor 0x0A  create: {TPtr8(&handle), LDD name, PDD name, TBuf8 info}
 *                  info = {TVersion, unit, info des, -}
 *   exec 0xC0000E  DoControl(fn, a1, a2, handle)
 *   exec 0xC0000C  DoRequest(fn, &status, &{a1, a2}, handle)
 *   exec 0xC0000D  DoCancel(mask, -, -, handle)
 *
 * A device with no model panics with its name: each one is added when the
 * firmware first reaches for it, from what it asks. */
#include "kobj.h"

extern int des_to_ascii(u32 d, char *out, int max);

struct channel;
struct devmodel {
    const char *ldd;
    s32 (*open)(struct channel *c);
    s32 (*control)(struct channel *c, int fn, u32 a1, u32 a2);
    s32 (*request)(struct channel *c, int fn, u32 status, u32 a1, u32 a2);
    void (*cancel)(struct channel *c, u32 mask);
};

struct channel {
    struct kobj o;
    const struct devmodel *m;
    int unit;
    u32 info;                                 /* the opener's info descriptor */
    struct thread *owner;
};

/* ---- HelperDrv (helper.ldd): startup reasons ---------------------------
 * Its callers are EStart and the DosServer's plug-in, Nokia.dsy:
 *   control 0  read the hardware startup reason (Starter_Arm.RSC resource 2
 *              knows 0, 1, 4, 5, 7; 0 is an ordinary power-on)
 *   request 1  the software startup reason, as the completion code
 *   control 6  set the software startup reason (an int), for the next boot
 *   control 1, 3, 8  read a word; 9 writes one and is kept nowhere
 *   control 5  no argument; 7 a caller's pointer -- meanings not yet read
 * The software reason survives a reset on a phone.  A factory-fresh NGVM
 * starts at 105 ('i'), the deep restore: EStart formats C: when LFFS will
 * not mount it, and Starter runs its first-boot restore, then sets 100. */
static s32 sw_reason = 'i';

static s32 helper_control(struct channel *c, int fn, u32 a1, u32 a2)
{
    if (kflags & DBGF_IPC) kprintf("[helper] control %d (%x %x)\n", fn, a1, a2);
    switch (fn) {
    case 0: case 1: case 3: case 8: uwrite32(a1, 0); return KErrNone;
    case 6: sw_reason = (s32)uread32(a1); return KErrNone;
    case 9: return KErrNone;
    case 5: case 7:
        kprintf("[helper] control %d (%x %x): not modelled, accepted\n", fn, a1, a2);
        return KErrNone;
    }
    kpanic("HelperDrv control %d (%x %x)", fn, a1, a2);
}

static s32 helper_request(struct channel *c, int fn, u32 st, u32 a1, u32 a2)
{
    if (fn != 1) kpanic("HelperDrv request %d (%x %x)", fn, a1, a2);
    request_complete(cur, st, sw_reason);
    return KErrNone;
}

/* ---- devices with nothing behind them -----------------------------------
 * NOSDRIVER (nosdriver.ldd) carries ISI messages to the cellular modem;
 * LesterDrv (lesterdrv.ldd) and adspctrl carry AudioServer's and adspserver's messages
 * to the audio DSP.  There is no modem, and the DSP is not modelled yet.
 * Controls are accepted; a request waits until it is cancelled, which is
 * what EStart's SIM-language query expects of a modem that does not answer
 * in time.  Every call is logged with its channel, so the protocols can be
 * read from the traces. */
#define MUTE_PENDING 16
static struct { struct thread *t; struct channel *c; u32 st; int fn; } mute_wait[MUTE_PENDING];

static void mute_log(struct channel *c, const char *what, int fn, u32 a1, u32 a2)
{
    kprintf("[");
    kputs16(c->o.name, c->o.namelen);
    kprintf("] %s %d (%x %x)\n", what, fn, a1, a2);
}

static s32 mute_control(struct channel *c, int fn, u32 a1, u32 a2)
{
    mute_log(c, "control", fn, a1, a2);
    return KErrNone;
}

static s32 mute_request(struct channel *c, int fn, u32 st, u32 a1, u32 a2)
{
    mute_log(c, "request, pending:", fn, a1, a2);
    for (int i = 0; i < MUTE_PENDING; i++)
        if (!mute_wait[i].t) {
            mute_wait[i].t = cur; mute_wait[i].c = c; mute_wait[i].st = st; mute_wait[i].fn = fn;
            return KErrNone;
        }
    kpanic("too many waiting requests on silent devices");
}

static void mute_cancel(struct channel *c, u32 mask)
{
    for (int i = 0; i < MUTE_PENDING; i++)
        if (mute_wait[i].t && mute_wait[i].c == c && (mask & (1u << mute_wait[i].fn))) {
            request_complete(mute_wait[i].t, mute_wait[i].st, KErrCancel);
            mute_wait[i].t = 0;
        }
}

/* ---- devices this phone does not have ------------------------------------
 * Comm (ecomm.ldd), the serial ports C32 opens for IrDA and the cable: with
 * no physical driver for a unit, EKA1's channel create fails KErrNotFound. */
static s32 absent_open(struct channel *c)
{
    kprintf("[chan] ");
    kputs16(c->o.name, c->o.namelen);
    kprintf(" unit %d: not present\n", c->unit);
    return KErrNotFound;
}

/* ---- Lcd (lcd.ldd) ------------------------------------------------------ */
static s32 lcd_control(struct channel *c, int fn, u32 a1, u32 a2)
{
    kprintf("[lcd] control %d (%x %x) from ", fn, a1, a2);
    kputs16(cur->proc->o.name, cur->proc->o.namelen);
    kprintf("\n");
    return KErrNone;
}

static s32 lcd_request(struct channel *c, int fn, u32 st, u32 a1, u32 a2)
{
    kpanic("Lcd request %d (%x %x)", fn, a1, a2);
}

/* ---- NOSDRIVER: Phonet, ISI messages to the modem ----------------------
 * Control 4 (and 6) sends one message: a1 is a TDes8 over it.  A Phonet
 * frame: media, receiver device, sender device, resource, length (big
 * endian, of what follows byte 5), receiver object, sender object, then the
 * ISI body: transaction id, message id, ...  Request 0 receives one into
 * the TDes8 at a1.
 *
 * There is no modem, so NGVM answers as an ISI modem answers a service it
 * does not have: COMMON_MESSAGE (0xF0), COMM_SERVICE_NOT_IDENTIFIED_RESP
 * (0x01), the request's message id, back to the sender's object with its
 * transaction id.  Clients take their error paths instead of waiting for
 * ever (MediaServer waited on ETel, and the game on MediaServer). */
#define ISI_REPLIES 32
#define ISI_LEN 14
static struct { struct channel *c; u8 m[ISI_LEN]; } isi_q[ISI_REPLIES];
static struct { struct channel *c; struct thread *t; u32 st, buf; } isi_rx[16];

static void isi_deliver(struct channel *c)
{
    for (int r = 0; r < 16; r++) {
        if (!isi_rx[r].t || isi_rx[r].c != c) continue;
        for (int q = 0; q < ISI_REPLIES; q++) {
            if (isi_q[q].c != c) continue;
            struct thread *t = isi_rx[r].t;
            isi_rx[r].t = 0;
            extern struct process *proc_mapped(void);
            struct process *was = proc_mapped();
            proc_switch_in(t->proc);
            s32 e = des_write8(isi_rx[r].buf, isi_q[q].m, ISI_LEN);
            proc_switch_in(was);
            isi_q[q].c = 0;
            if (kflags & DBGF_IPC) {
                kprintf("[isi] reply res %02x tid %02x to ", isi_q[q].m[3], isi_q[q].m[8]);
                kputs16(t->proc->o.name, t->proc->o.namelen);
                kprintf(": %d\n", e);
            }
            request_complete(t, isi_rx[r].st, e);
            return;
        }
    }
}

static s32 nos_control(struct channel *c, int fn, u32 a1, u32 a2)
{
    if (fn != 4 && fn != 6) return mute_control(c, fn, a1, a2);
    u8 m[24];
    int n = des_len(a1);
    ucopy_from(m, des_ptr(a1), n < 24 ? n : 24);
    if (kflags & DBGF_IPC) {
        kprintf("[isi] send res %02x len %d obj %02x->%02x tid %02x msg %02x:", m[3], n, m[7], m[6], m[8], m[9]);
        for (int i = 10; i < n && i < 24; i++) kprintf(" %02x", m[i]);
        kprintf(" (from ");
        kputs16(cur->proc->o.name, cur->proc->o.namelen);
        kprintf(")\n");
    }
    if (n < 10 || m[9] == 0xF0) return KErrNone;   /* not a request */
    for (int q = 0; q < ISI_REPLIES; q++) {
        if (isi_q[q].c) continue;
        u8 *r = isi_q[q].m;
        r[0] = m[0]; r[1] = m[2]; r[2] = m[1]; r[3] = m[3];
        r[4] = 0; r[5] = ISI_LEN - 6;
        r[6] = m[7]; r[7] = m[6];
        r[8] = m[8]; r[9] = 0xF0; r[10] = 0x01; r[11] = m[9]; r[12] = 0; r[13] = 0;
        if (m[3] == 0x1C && m[9] == 0x10) {   /* accessory mode: PHONETSY reads one byte */
            r[9] = 0x11; r[10] = 0; r[11] = 0;     /* 0: no accessory */
        }
        isi_q[q].c = c;
        isi_deliver(c);
        return KErrNone;
    }
    kprintf("[isi] reply queue full\n");
    return KErrNone;
}

static s32 nos_request(struct channel *c, int fn, u32 st, u32 a1, u32 a2)
{
    if (kflags & DBGF_IPC) {
        kprintf("[isi] receive %d (%x %x) from ", fn, a1, a2);
        kputs16(cur->proc->o.name, cur->proc->o.namelen);
        kprintf("\n");
    }
    if (fn != 0) return mute_request(c, fn, st, a1, a2);
    for (int r = 0; r < 16; r++)
        if (!isi_rx[r].t) {
            isi_rx[r].c = c; isi_rx[r].t = cur; isi_rx[r].st = st; isi_rx[r].buf = a1;
            isi_deliver(c);
            return KErrNone;
        }
    kpanic("NOSDRIVER: too many receives");
}

static void nos_cancel(struct channel *c, u32 mask)
{
    if (mask & 1)
        for (int r = 0; r < 16; r++)
            if (isi_rx[r].t && isi_rx[r].c == c) {
                request_complete(isi_rx[r].t, isi_rx[r].st, KErrCancel);
                isi_rx[r].t = 0;
            }
    mute_cancel(c, mask);
}

static const struct devmodel models[] = {
    { "Lcd", 0, lcd_control, lcd_request, 0 },
    { "NOSDRIVER", 0, nos_control, nos_request, nos_cancel },
    { "LesterDrv", 0, mute_control, mute_request, mute_cancel },
    { "adspctrl", 0, mute_control, mute_request, mute_cancel },
    { "Audioldd", 0, mute_control, mute_request, mute_cancel },
    { "Comm", absent_open, 0, 0, 0 },
    { "HelperDrv", 0, helper_control, helper_request, 0 },
    { 0 }
};

static void trace_name(const char *what, struct channel *c, int fn, u32 a1, u32 a2)
{
    if (!(kflags & DBGF_IPC)) return;
    kprintf("[chan] %s ", what);
    kputs16(c->o.name, c->o.namelen);
    kprintf(" fn %d (%x %x)\n", fn, a1, a2);
}

/* executor 0x0A */
s32 chan_create(struct thread *t, u32 a, int towned)
{
    char ldd[32];
    des_to_ascii(uread32(a + 4), ldd, sizeof ldd);
    u32 info = uread32(a + 12);
    u32 ip = des_ptr(info);
    int unit = (int)uread32(ip + 4);
    if (kflags & DBGF_IPC) {
        kprintf("[chan] open %s unit %d", ldd, unit);
        extern void kputdes16(u32);
        u32 pdd = uread32(a + 8);              /* -1 or small: none */
        if (pdd >= 0x1000 && pdd != 0xFFFFFFFFu) { kprintf(" pdd "); kputdes16(pdd); } else kprintf(" pdd arg %x", pdd);
        kprintf(" ver %x info %x\n", uread32(ip), uread32(ip + 8));
    }
    const struct devmodel *m = 0;
    extern int u16_eq_fold(const u16 *, int, const u16 *, int);
    for (const struct devmodel *d = models; d->ldd; d++) {
        u16 n[32];
        int k = 0;
        while (d->ldd[k]) { n[k] = (u8)d->ldd[k]; k++; }
        u16 w[32];
        int wn = 0;
        while (ldd[wn]) { w[wn] = (u8)ldd[wn]; wn++; }
        if (u16_eq_fold(n, k, w, wn)) { m = d; break; }
    }
    if (!m) kpanic("no model for device %s (unit %d)", ldd, unit);
    struct channel *c = (struct channel *)obj_new(O_CHANNEL, sizeof(struct channel), t->proc);
    obj_set_name_a(&c->o, ldd);
    c->m = m;
    c->unit = unit;
    c->info = uread32(ip + 8);
    c->owner = t;
    s32 r = m->open ? m->open(c) : KErrNone;
    if (r != KErrNone) { obj_unref(&c->o); return r; }
    u32 h = handle_make(t, &c->o, towned);
    u32 d = uread32(a);
    uwrite32(des_ptr(d), h);
    des_setlen(d, 4);
    return KErrNone;
}

static struct channel *chan(u32 h) { return (struct channel *)handle_lookup(cur, h, O_CHANNEL); }

s32 chan_exec(int idx, u32 a0, u32 a1, u32 a2, u32 a3)
{
    struct channel *c = chan(a3);
    if (!c) return KErrBadHandle;
    switch (idx) {
    case 0x0E:
        trace_name("control", c, (int)a0, a1, a2);
        if (!c->m->control) break;
        return c->m->control(c, (int)a0, a1, a2);
    case 0x0C: {
        u32 x1 = a2 ? uread32(a2) : 0, x2 = a2 ? uread32(a2 + 4) : 0;
        trace_name("request", c, (int)a0, x1, x2);
        if (!c->m->request) break;
        uwrite32(a1, (u32)KRequestPending);
        return c->m->request(c, (int)a0, a1, x1, x2);
    }
    case 0x0D:
        trace_name("cancel", c, (int)a0, a1, a2);
        if (c->m->cancel) c->m->cancel(c, a0);
        return KErrNone;
    }
    char n[40];
    int k = c->o.namelen < 39 ? c->o.namelen : 39;
    for (int i = 0; i < k; i++) n[i] = (char)c->o.name[i];
    n[k] = 0;
    kpanic("device %s: exec %x fn %d (%x %x) not modelled", n, idx, (int)a0, a1, a2);
}
