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
#include "mm.h"

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

/* ---- bt_driver: the Bluetooth controller's transport --------------------
 * A byte stream, as a UART is.  Request 1 sends (a1 a descriptor, a2 points
 * at its length); request 0 reads exactly the count a2 points at into the
 * descriptor a1.  hci.dll reads a packet in pieces (its reader's state
 * machine at 0x50475278): a 16-bit little-endian type, then the header,
 * then the rest: 1 command (opcode, length, parameters), 4 event (code,
 * length, parameters).  Its first write is 01 00 05 10 00, Read_Buffer_Size.
 *
 * There is no radio, so NGVM is a controller with nothing in range: every
 * command completes at once with success and plausible return parameters,
 * and an inquiry finds no one.  Games need the stack up only to offer
 * multiplayer. */
#define BT_FIFO 4096                          /* bytes from the controller */
static u8 bt_fifo[BT_FIFO];
static int bt_head, bt_count;
static struct { struct thread *t; struct channel *c; u32 st, buf; int want; } bt_rx;

static void bt_deliver(void)
{
    if (!bt_rx.t || bt_count < bt_rx.want) return;
    u8 b[260];
    int n = bt_rx.want;
    for (int i = 0; i < n; i++) b[i] = bt_fifo[(bt_head + i) % BT_FIFO];
    bt_head = (bt_head + n) % BT_FIFO;
    bt_count -= n;
    struct thread *t = bt_rx.t;
    bt_rx.t = 0;
    extern struct process *proc_mapped(void);
    struct process *was = proc_mapped();
    proc_switch_in(t->proc);
    s32 e = des_write8(bt_rx.buf, b, n);
    proc_switch_in(was);
    request_complete(t, bt_rx.st, e);
}

/* an event: its parameters are filled in through the pointer returned */
static u8 bt_ev[260];
static int bt_evlen;
static u8 *bt_event(int code, int plen)
{
    bt_ev[0] = 4; bt_ev[1] = 0; bt_ev[2] = (u8)code; bt_ev[3] = (u8)plen;
    memset(bt_ev + 4, 0, plen);
    bt_evlen = 4 + plen;
    return bt_ev + 4;
}

static void bt_send_event(void)
{
    if (bt_count + bt_evlen > BT_FIFO) { kprintf("[bt] fifo full\n"); return; }
    for (int i = 0; i < bt_evlen; i++) bt_fifo[(bt_head + bt_count + i) % BT_FIFO] = bt_ev[i];
    bt_count += bt_evlen;
}

/* Command Complete with these return parameters after the status byte */
static void bt_complete(u16 op, const u8 *ret, int n)
{
    u8 *p = bt_event(0x0E, 4 + n);
    p[0] = 1; p[1] = (u8)op; p[2] = (u8)(op >> 8); p[3] = 0;
    if (n) memcpy(p + 4, ret, n);
    bt_send_event();
}

static void bt_command(u16 op, const u8 *par, int plen)
{
    static const u8 bufsize[] = { 0x53, 0x01, 0x40, 0x08, 0x00, 0x01, 0x00 };  /* ACL 339 x8, SCO 64 x1 */
    static const u8 version[] = { 1, 0x00, 0x00, 1, 0x01, 0x00, 0x00, 0x00 };   /* HCI/LMP 1.1, Nokia */
    static const u8 features[] = { 0xFF, 0xFF, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x00 };
    static const u8 bdaddr[] = { 0x01, 0x00, 0x00, 0x47, 0x4E, 0x00 };           /* 00:4E:47:00:00:01 */
    static const u8 cod[] = { 0x04, 0x02, 0x5A };
    if (kflags & DBGF_IPC) kprintf("[bt] command %04x (ogf %x ocf %x) len %d\n", op, op >> 10, op & 0x3FF, plen);
    switch (op) {
    case 0x1005: bt_complete(op, bufsize, sizeof bufsize); return;
    case 0x1001: bt_complete(op, version, sizeof version); return;
    case 0x1003: bt_complete(op, features, sizeof features); return;
    case 0x1009: bt_complete(op, bdaddr, sizeof bdaddr); return;
    case 0x0C23: bt_complete(op, cod, sizeof cod); return;           /* Read_Class_of_Device */
    case 0x0C19: { static const u8 z[1]; bt_complete(op, z, 1); return; }   /* Read_Scan_Enable */
    case 0x0C14: {                                                   /* Read_Local_Name */
        static u8 name[248];
        memcpy(name, "N-Gage", 6);
        bt_complete(op, name, sizeof name);
        return;
    }
    case 0x0401: {                                                   /* Inquiry: no one there */
        u8 *p = bt_event(0x0F, 4);                                   /* Command Status */
        p[0] = 0; p[1] = 1; p[2] = (u8)op; p[3] = (u8)(op >> 8);
        bt_send_event();
        bt_event(0x01, 1);                                           /* Inquiry Complete, success */
        bt_send_event();
        return;
    }
    }
    bt_complete(op, 0, 0);
}

static s32 bt_request(struct channel *c, int fn, u32 st, u32 a1, u32 a2)
{
    if (fn == 0) {
        if (bt_rx.t) kpanic("bt_driver: two reads");
        bt_rx.t = cur; bt_rx.c = c; bt_rx.st = st; bt_rx.buf = a1;
        bt_rx.want = (int)uread32(a2);
        if (bt_rx.want <= 0 || bt_rx.want > 255 || bt_rx.want > des_maxlen(a1)) kpanic("bt_driver: read of %d", bt_rx.want);
        bt_deliver();
        return KErrNone;
    }
    if (fn == 1) {
        u8 m[260];
        int n = des_len(a1);
        if (n > (int)sizeof m) n = sizeof m;
        ucopy_from(m, des_ptr(a1), n);
        if (n >= 5 && m[0] == 1 && m[1] == 0) bt_command(m[2] | m[3] << 8, m + 5, m[4]);
        else {
            kprintf("[bt] send %d:", n);
            for (int i = 0; i < n && i < 16; i++) kprintf(" %02x", m[i]);
            kprintf("\n");
        }
        request_complete(cur, st, KErrNone);
        bt_deliver();
        return KErrNone;
    }
    return mute_request(c, fn, st, a1, a2);
}

static void bt_cancel(struct channel *c, u32 mask)
{
    if ((mask & 1) && bt_rx.t && bt_rx.c == c) {
        request_complete(bt_rx.t, bt_rx.st, KErrCancel);
        bt_rx.t = 0;
    }
    mute_cancel(c, mask);
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

/* ---- Audioldd (audio.ldd): the DSP's shared memory ---------------------
 * audio.ldd is a shim of 1460 bytes.  Control 0 writes three words: at a1
 * the shared memory's address and the constant 0x0a061000, at a2 its size
 * (both from the variant's virtuals at +0xf0 and +0xf4).  Controls 1 and 2
 * switch something in the variant on and off (an object's call with 2, then
 * 0).  SoundDevice.mda (MediaServer's sound device) is its one client; it
 * reads and writes the memory directly.  The size is a guess until the DSP
 * side is understood. */
#define AUDIO_SHM_SIZE 0x10000
static u32 audio_shm;

static s32 audio_control(struct channel *c, int fn, u32 a1, u32 a2)
{
    if (fn == 0) {
        if (!audio_shm) {
            audio_shm = vm_reserve(AUDIO_SHM_SIZE);
            if (!audio_shm || vm_commit(audio_shm, AUDIO_SHM_SIZE)) kpanic("no memory for the DSP's shared memory");
            memset((void *)audio_shm, 0, AUDIO_SHM_SIZE);
        }
        if (a1) { uwrite32(a1, audio_shm); uwrite32(a1 + 4, 0x0a061000); }
        if (a2) uwrite32(a2, AUDIO_SHM_SIZE);
        if (kflags & DBGF_IPC) kprintf("[Audioldd] shared memory %x+%x\n", audio_shm, AUDIO_SHM_SIZE);
        return KErrNone;
    }
    if (fn == 1 || fn == 2) return mute_control(c, fn, a1, a2);
    return KErrNotSupported;
}

/* ---- Lcd (lcd.ldd) ------------------------------------------------------ */
static s32 lcd_control(struct channel *c, int fn, u32 a1, u32 a2)
{
    /* The window server's update, 30 times a second while anything moves,
     * always lines 0-208 ({0xa, 0, 0xd0} at a1): what the phone sends to
     * its display (docs/hardware.md) */
    if (fn == 8194) { IO(IO_LCD_SHOW) = 1; return KErrNone; }
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
static struct { struct channel *c; u32 seq; u8 m[ISI_LEN]; } isi_q[ISI_REPLIES];
static u32 isi_seq;                           /* queued messages go out in order */
static struct { struct channel *c; struct thread *t; u32 st, buf; } isi_rx[16];

static void isi_deliver(struct channel *c)
{
    for (int r = 0; r < 16; r++) {
        if (!isi_rx[r].t || isi_rx[r].c != c) continue;
        int q = -1;
        for (int i = 0; i < ISI_REPLIES; i++)
            if (isi_q[i].c == c && (q < 0 || (s32)(isi_q[i].seq - isi_q[q].seq) < 0)) q = i;
        if (q >= 0) {
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

/* ---- the DSP's PCM player (ISI resource 0xE8) ----------------------------
 * SoundDevice.mda plays a stream through two buffers in the Audioldd shared
 * memory, which the DSP addresses from 0x0a061000.  Read from its code and
 * its traffic:
 *   0x20 start   [10] 0x82  [11] 2 or 3  [12..13] capacity (samples)
 *                [14..17] buffer 0, [18..21] buffer 1 (DSP addresses)
 *                [22..23] 0x32 (8 kHz) or 0x46 (16 kHz)           -> 0x21
 *   0x23 filled  [10] buffer  [11] 2, or 1 for the last  [12..13] samples
 *                                                                  -> 0x24
 *   0x27 filled  as 0x23, once playing: the buffer last asked for -> 0x28
 *   0x2a stop    (no body)               -> 0x2b [10..11] the bytes played
 *   0x26 (from the DSP) [11] a buffer to fill
 * 0x24 moves SoundDevice from starting to playing.  It fills one buffer
 * at the start and one for each 0x26, so the DSP asks for the other buffer
 * as it starts to play one: double buffering.  isimsg.dll builds the
 * requests (0x19, 0x1c, 0x1e, 0x20, 0x23, 0x27, 0x28, 0x2a); SoundDevice
 * takes 0x1a, 0x1b, 0x1d, 0x1f, 0x21, 0x22, 0x24, 0x25, 0x26 and 0x2b (its
 * table at 0x505b46dc).  A game stops its stream between screens (Puyo
 * Pop): unanswered, the stop left SoundDevice playing nothing for good.
 * 0x2b stops SoundDevice's side whatever its state (0x505b495e), so it is
 * also sent after the last buffer (flag 1), which is not yet checked
 * against a game that ends a stream.  Samples are 16-bit little endian,
 * mono; the FIFO takes them as L = R. */
#define DSP_BASE 0x0a061000u
static struct {
    struct channel *c;
    u8 hdr[3];                                /* media, its device, ours     */
    u8 obj, us;                               /* its object, and ours        */
    u32 buf[2]; int len[2], full[2], last[2];
    int cur, pos, playing, rate;
    int want;                                 /* the buffer asked for, or -1 */
} dsp;

static void isi_post(struct channel *c, const u8 *m)
{
    for (int q = 0; q < ISI_REPLIES; q++)
        if (!isi_q[q].c) {
            memcpy(isi_q[q].m, m, ISI_LEN);
            isi_q[q].c = c;
            isi_q[q].seq = isi_seq++;
            isi_deliver(c);
            return;
        }
    kprintf("[isi] reply queue full\n");
}

static void dsp_send(u8 id, u8 b10, u8 b11, u8 b12, u8 b13)
{
    u8 m[ISI_LEN] = { dsp.hdr[0], dsp.hdr[1], dsp.hdr[2], 0xE8, 0, ISI_LEN - 6, dsp.obj, dsp.us, 0, id, b10, b11, b12, b13 };
    if (kflags & DBGF_IPC) kprintf("[dsp] send %02x: %02x %02x\n", id, b10, b11);
    isi_post(dsp.c, m);
}

static u32 be32(const u8 *p) { return (u32)p[0] << 24 | (u32)p[1] << 16 | (u32)p[2] << 8 | p[3]; }

/* a request to the player: fill in the reply r, or return 0 for the
 * generic one */
static int dsp_request(struct channel *c, const u8 *m, int n, u8 *r)
{
    switch (m[9]) {
    case 0x20:
        if (n < 24) break;
        dsp.c = c; dsp.obj = m[7]; dsp.us = m[6];
        dsp.hdr[0] = m[0]; dsp.hdr[1] = m[2]; dsp.hdr[2] = m[1];
        dsp.buf[0] = be32(m + 14); dsp.buf[1] = be32(m + 18);
        dsp.rate = m[23] == 0x32 ? 8000 : 16000;
        dsp.full[0] = dsp.full[1] = 0; dsp.cur = dsp.pos = 0; dsp.playing = 0; dsp.want = -1;
        IO(IO_AUDIO_RATE) = dsp.rate;
        if (kflags & DBGF_IPC)
            kprintf("[dsp] start: buffers %x %x of %d samples, %d Hz\n", dsp.buf[0], dsp.buf[1], m[12] << 8 | m[13], dsp.rate);
        r[9] = 0x21; r[10] = 0; r[11] = 0;
        return 1;
    case 0x23:
    case 0x27: {
        int i = m[9] == 0x23 ? m[10] & 1 : dsp.want;
        if (i < 0) { kprintf("[dsp] a buffer filled that was not asked for\n"); i = dsp.cur ^ 1; }
        if (i == dsp.want) dsp.want = -1;
        dsp.full[i] = 1; dsp.last[i] = m[11] == 1; dsp.len[i] = m[12] << 8 | m[13];
        if (kflags & DBGF_IPC) kprintf("[dsp] buffer %d: %d samples%s\n", i, dsp.len[i], dsp.last[i] ? ", last" : "");
        dsp.playing = 1;
        IO(IO_IRQ_ENABLE) |= IRQ_AUDIO;
        r[9] = m[9] + 1; r[10] = 0; r[11] = 0;
        return 1;
    }
    case 0x2a: {
        int b = dsp.playing ? dsp.pos * 2 : 0;
        if (kflags & DBGF_IPC) kprintf("[dsp] stop after %d bytes\n", b);
        dsp.playing = 0; dsp.full[0] = dsp.full[1] = 0; dsp.pos = 0; dsp.want = -1;
        IO(IO_IRQ_ENABLE) &= ~IRQ_AUDIO;
        r[9] = 0x2b; r[10] = b >> 8; r[11] = b;
        return 1;
    }
    }
    kprintf("[dsp] request %02x not modelled\n", m[9]);
    return 0;
}

/* IRQ_AUDIO: the FIFO is half empty.  Play from the current buffer; a
 * buffer played goes back to SoundDevice. */
void dsp_pump(void)
{
    if (!dsp.playing) { IO(IO_IRQ_ENABLE) &= ~IRQ_AUDIO; return; }
    int room = (int)IO(IO_AUDIO_SIZE) - (int)IO(IO_AUDIO_LEVEL);
    while (room > 0 && dsp.full[dsp.cur]) {
        int i = dsp.cur;
        if (dsp.pos == 0 && !dsp.full[i ^ 1] && dsp.want < 0 && !dsp.last[i]) {
            dsp.want = i ^ 1;
            dsp_send(0x26, 0, i ^ 1, 0, 0);
        }
        const u16 *p = (const u16 *)(audio_shm + (dsp.buf[i] - DSP_BASE));
        while (room > 0 && dsp.pos < dsp.len[i]) {
            u32 v = (u16)p[dsp.pos++];
            IO(IO_AUDIO_DATA) = v | v << 16;
            room--;
        }
        if (dsp.pos < dsp.len[i]) break;
        dsp.full[i] = 0; dsp.pos = 0; dsp.cur ^= 1;
        if (dsp.last[i]) {
            int b = dsp.len[i] * 2;
            dsp_send(0x2b, b >> 8, b, 0, 0);
            dsp.playing = 0;
            break;
        }
    }
    /* nothing to play: stop asking until SoundDevice fills a buffer */
    if (!dsp.full[dsp.cur]) IO(IO_IRQ_ENABLE) &= ~IRQ_AUDIO;
}

/* ---- the DSP's tone player (ISI resource 0x1F) ---------------------------
 * SoundDevice.mda starts a key click or a tone with message 0x01 and holds
 * the audio device (its state 14) until the DSP says the tone has ended:
 * message 0x03 with [10] anything but 0x14, or 0x06 with [10] 0x0d (its
 * receive handler, 0x505b4460).  While it holds it, a stream of lower
 * priority than the tone's -- every game's -- is refused with KErrInUse
 * (0x505b11a4, then 0x505b138e).  A game that pressed a key in its menus
 * then never sounds again, and one that retries the stream (Puzzle Bobble,
 * every 117 ms) waits on each try.  NGVM has no tone generator, so a tone
 * ends as soon as it starts. */
static void tone_ended(struct channel *c, const u8 *m)
{
    u8 e[ISI_LEN] = { m[0], m[2], m[1], 0x1F, 0, ISI_LEN - 6, m[7], m[6], m[8], 0x03, 0, 0, 0, 0 };
    if (kflags & DBGF_IPC) kprintf("[tone] ended\n");
    isi_post(c, e);
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
        if (kflags & DBGF_DUMP) { kprintf("  from:"); stack_scan(cur, 16); }
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
        if (m[3] == 0xE8) dsp_request(c, m, n, r);
        isi_q[q].c = c;
        isi_q[q].seq = isi_seq++;
        isi_deliver(c);
        if (m[3] == 0x1F && m[9] == 0x01) tone_ended(c, m);
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
    { "Audioldd", 0, audio_control, mute_request, mute_cancel },
    { "Comm", absent_open, 0, 0, 0 },
    { "bt_driver", 0, mute_control, bt_request, bt_cancel },
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

/* The last handle is gone.  EKA1's logical channels cancel what is still
 * outstanding when they are closed, so a client that closes first and then
 * waits on its request (gendll's destructor in adspserver does) gets
 * KErrCancel; and nothing may keep pointing at the channel after it. */
void chan_destroy(struct kobj *o)
{
    struct channel *c = (struct channel *)o;
    if (kflags & DBGF_IPC) trace_name("close", c, 0, 0, 0);
    if (c->m->cancel) c->m->cancel(c, ~0u);
    for (int q = 0; q < ISI_REPLIES; q++)
        if (isi_q[q].c == c) isi_q[q].c = 0;
}

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
