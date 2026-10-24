/* Local drives: what EFile's TBusLocalDrive reaches through the kernel.
 *
 *   unit 0  C:  the internal drive: NOR flash under Nokia's LFFS (ELOCAL.FSY
 *               on this firmware is LFFS, not FAT).  The 1 MB save area at
 *               the top of RAM (NGVM_SAVE_BASE), through the physical alias.
 *               Games keep their saves here (C:\System\Apps\<game>\), so
 *               the Pocket loads it from the game's save file and writes it
 *               back after IO_SAVE_DIRTY.  With no save, or one LFFS did not
 *               write, it is erased to 0xFF: a factory-fresh phone, which
 *               LFFS formats on the first mount
 *   unit 1  D:  the RAM drive: FAT under ERAM.FSY, which reaches the memory
 *               directly through the caps' iBaseAddress.  Its size varies:
 *               the file system grows and shrinks it (Enlarge/ReduceSize)
 *   unit 2  E:  the memory card: the game's image at NGVM_DRIVE_BASE, or,
 *               when it is larger than the window there, a cache of it
 *               (below)
 *
 * TBusLocalDrive (EUser) is { +0 bus handle, +4 media status, +8 drive
 * handle }.  Connect asks for the bus handle (exec 0x8000B7), then for a
 * drive (executor 0x38); reads, writes and erases are execs 0x8F/0x90/0x92
 * and finish at once. */
#include "kobj.h"
#include "mm.h"

#define NUNITS 3
#define C_SIZE NGVM_SAVE_SIZE
#define C_ERASE (64 * 1024)
#define LFFS_MAGIC 0x503B3B60u      /* word 1 of every block LFFS has formatted */
#define D_MAX  (4 * 1024 * 1024)

struct ldrive { struct kobj o; int unit; u32 status; };
/* TMediaType: 3 hard disk, 5 RAM, 6 flash.  Drive attributes: 0x01 local,
 * 0x10 internal, 0x20 removable.  Media: 0x01 variable size, 0x04 formattable */
static struct {
    u32 base, size, max;
    u8  type, driveatt, mediaatt, fsid;
    u32 erase;
} media[NUNITS] = {
    { 0, 0, 0, 6, 0x11, 0x04, 0, C_ERASE },
    { 0, 0, 0, 5, 0x11, 0x05, 1, 0 },
    { NGVM_DRIVE_BASE, 0, 0, 3, 0x21, 0x04, 1, 0 },
};
static struct { struct thread *t; u32 st; } change[16];   /* by TMediaDevice */

/* ---- E: larger than its window ------------------------------------------------
 * The Pocket loads the image's first NGVM_DRIVE_MAX bytes into the window and
 * leaves the rest on the card (ngvm_hw.h).  The window is then NSLOT slots of
 * a 64 KB block each, slot i holding block i to begin with.  A block in no
 * slot is fetched into one (IO_FETCH_*), chosen by a clock over the slots'
 * referenced bits.  The clock turns from the top of the window down: a
 * game reads its files forward, and a hand moving the same way would take,
 * each time, the block the read needs next (Pathway to Glory's first 75 s:
 * 41 fetches that way, 13 this, one for each block beyond the window it
 * reads).  A slot E: was written in is never chosen again: nothing
 * writes the image on the card, so the write lives in the window only, as a
 * write to a drive that fits does.
 *
 * A request that needs a block not in the window waits for it: it is left
 * pending, and IRQ_FETCH carries it on.  The caller waits on its status
 * (EUser's TBusLocalDrive::Read calls User::WaitForRequest), and the rest
 * of the phone runs meanwhile.  Requests are served one at a time, in the
 * order they come. */
#define BLK_SHIFT 16
#define BLK       (1u << BLK_SHIFT)
#define NSLOT     (NGVM_DRIVE_MAX >> BLK_SHIFT)
#define NBLK      (NGVM_IMAGE_MAX >> BLK_SHIFT)
#define NO_SLOT   0xFFFF
#define FETCH_WAIT_US 5000000u             /* the Pocket has not answered: give up */
static int cached;
static u16 blk_slot[NBLK], slot_blk[NSLOT];
static u8  slot_ref[NSLOT], slot_pin[NSLOT];
static int hand = NSLOT - 1, fetch_slot = -1, fetch_blk;
static u64 fetch_t0;
static u32 fetches;
struct ereq { struct thread *caller, *t; u32 st, buf, pos; int write, off, left; s32 r; };
#define NREQ 8
static struct ereq rq[NREQ];
static int rq_head, rq_n;

void drive_init(void)
{
    u32 c = NGVM_PHYS_BASE + NGVM_SAVE_BASE;
    int saved = 0;
    if (IO(IO_SAVE_SIZE) == C_SIZE)
        for (u32 b = 0; b < C_SIZE && !saved; b += C_ERASE) saved = ((u32 *)(c + b))[1] == LFFS_MAGIC;
    if (!saved) memset((void *)c, 0xFF, C_SIZE);    /* erased flash */
    media[0].base = c;
    media[0].size = media[0].max = C_SIZE;
    u32 d = vm_reserve(D_MAX);
    if (!d || vm_commit(d, D_MAX)) kpanic("no memory for D:");
    media[1].base = d;
    media[1].max = D_MAX;
    media[2].size = media[2].max = IO(IO_DRIVE_SIZE);
    cached = media[2].size > NGVM_DRIVE_MAX;
    if (cached) {
        if (media[2].size > NGVM_IMAGE_MAX) media[2].size = media[2].max = NGVM_IMAGE_MAX;
        /* a fetch is of whole words (ngvm_hw.h), so the last block is too;
         * an image is whole sectors, and this loses nothing of one */
        media[2].size = media[2].max = media[2].size & ~3u;
        for (u32 b = 0; b < NBLK; b++) blk_slot[b] = b < NSLOT ? b : NO_SLOT;
        for (u32 s = 0; s < NSLOT; s++) slot_blk[s] = s;
    }
    if (kflags & (DBGF_IPC | DBGF_DRIVE)) kprintf("[drive] C: at %p (%s), D: at %p, E: %x bytes%s\n",
                                   c, saved ? "the save" : "erased", d, media[2].size,
                                   cached ? ", larger than its window" : "");
}

/* ---- copies between media and a thread's descriptor ------------------------- */
extern struct process *proc_mapped(void);

/* n bytes from kernel-addressable src into t's descriptor d, at offset off */
static s32 to_des(struct thread *t, u32 d, u32 src, int n, int off)
{
    struct process *was = proc_mapped();
    s32 r = KErrNone;
    proc_switch_in(t->proc);
    if (off + n > des_maxlen(d)) r = KErrOverflow;
    else {
        memcpy((void *)(des_ptr(d) + off), (const void *)src, n);
        des_setlen(d, off + n);
    }
    proc_switch_in(was);
    return r;
}

static s32 from_des(struct thread *t, u32 d, u32 dst, int n, int off)
{
    struct process *was = proc_mapped();
    proc_switch_in(t->proc);
    if (off + n > des_len(d)) n = des_len(d) - off;
    if (n > 0) memcpy((void *)dst, (const void *)(des_ptr(d) + off), n);
    proc_switch_in(was);
    return KErrNone;
}

/* NOR flash: programming only clears bits; erase sets them again.  C: is
 * uncached, so whole words where they line up. */
static s32 program(struct thread *t, u32 d, u32 dst, int n, int off)
{
    static u32 b[128];
    while (n > 0) {
        int k = n > (int)sizeof b ? (int)sizeof b : n;
        from_des(t, d, (u32)b, k, off);
        int i = 0;
        if (!(dst & 3)) for (; i + 4 <= k; i += 4) ((u32 *)dst)[i / 4] &= b[i / 4];
        for (; i < k; i++) ((u8 *)dst)[i] &= ((u8 *)b)[i];
        dst += k; off += k; n -= k;
    }
    return KErrNone;
}

static struct ldrive *drv(u32 h) { return (struct ldrive *)handle_lookup(cur, h, O_DEVICE); }

/* ---- E:'s cache ------------------------------------------------------------- */
/* The fetch failed, or the Pocket never answered: the game cannot go on.
 * The screen says which, for the person holding the Pocket (docs/bringup.md):
 * red with a white band for each unit of the Pocket's error code, or blue. */
static void __attribute__((noreturn)) fetch_fail(u32 err)
{
    volatile u16 *fb = (volatile u16 *)IO(IO_LCD_BASE);
    if (fb) {
        for (int y = 0; y < LCD_H; y++)
            for (int x = 0; x < LCD_W; x++)
                fb[y * LCD_W + x] = !err ? 0x000F : (y % 24 < 12 && y / 24 < (int)err) ? 0x0FFF : 0x0F00;
        IO(IO_LCD_SHOW) = 1;
    }
    if (err) kpanic("E: the fetch of block %x failed, error %d", fetch_blk, err);
    kpanic("E: the fetch of block %x was not answered in %d ms", fetch_blk, FETCH_WAIT_US / 1000);
}

/* fetch block b into a slot the clock chooses; 0 if every slot is pinned */
static int fetch(u32 b)
{
    int s, n = 0;
    for (;; hand = (hand + NSLOT - 1) % NSLOT) {
        if (++n > 2 * NSLOT) return 0;
        s = hand;
        if (slot_pin[s]) continue;
        if (slot_ref[s]) { slot_ref[s] = 0; continue; }
        break;
    }
    hand = (hand + NSLOT - 1) % NSLOT;
    if (slot_blk[s] != NO_SLOT) blk_slot[slot_blk[s]] = NO_SLOT;
    u32 old = slot_blk[s];
    slot_blk[s] = NO_SLOT;
    fetch_slot = s; fetch_blk = b;
    u32 src = b << BLK_SHIFT, len = media[2].size - src;
    if (len > BLK) len = BLK;
    fetch_t0 = now_us();
    fetches++;
    if (kflags & DBGF_DRIVE) kprintf("[drive] E: fetch %d: block %x into slot %x (block %x was there)\n",
                                     fetches, b, s, old);
    IO(IO_FETCH_SRC) = src;
    IO(IO_FETCH_DST) = (u32)s << BLK_SHIFT;
    IO(IO_FETCH_LEN) = len;
    return 1;
}

/* carry request q on; 0 while it waits for a fetch */
static int e_step(struct ereq *q)
{
    if (q->t->state == T_DEAD || q->caller->state == T_DEAD) { q->r = KErrDied; return 1; }
    while (q->left > 0) {
        u32 b = q->pos >> BLK_SHIFT, o = q->pos & (BLK - 1);
        int n = BLK - o;
        if (n > q->left) n = q->left;
        u32 s = blk_slot[b];
        if (s == NO_SLOT) {
            if (fetch(b)) return 0;
            q->r = KErrDiskFull;
            return 1;
        }
        u32 a = NGVM_DRIVE_BASE + (s << BLK_SHIFT) + o;
        slot_ref[s] = 1;
        if (q->write) { from_des(q->t, q->buf, a, n, q->off); slot_pin[s] = 1; }
        else if ((q->r = to_des(q->t, q->buf, a, n, q->off)) != KErrNone) return 1;
        q->pos += n; q->off += n; q->left -= n;
    }
    return 1;
}

/* serve the queue's requests in turn, until one waits for a fetch */
static void e_run(void)
{
    while (rq_n && fetch_slot < 0) {
        struct ereq *q = &rq[rq_head];
        if (!e_step(q)) return;
        if (kflags & DBGF_DRIVE) kprintf("[drive] E: done -> %d\n", q->r);
        if (q->caller->state != T_DEAD) request_complete(q->caller, q->st, q->r);
        obj_unref(&q->caller->o);
        obj_unref(&q->t->o);
        rq_head = (rq_head + 1) % NREQ;
        rq_n--;
    }
}

/* IRQ_FETCH: the block is in its slot */
void drive_fetched(void)
{
    if (fetch_slot < 0) return;
    u32 st = IO(IO_FETCH_STAT);
    if (st & 1) return;
    if (st >> 1) fetch_fail(st >> 1);
    blk_slot[fetch_blk] = fetch_slot;
    slot_blk[fetch_slot] = fetch_blk;
    slot_ref[fetch_slot] = 1;
    if (kflags & DBGF_DRIVE) kprintf("[drive] E: fetched block %x in %d us\n", fetch_blk, (u32)(now_us() - fetch_t0));
    fetch_slot = -1;
    e_run();
}

/* at each timer tick: a fetch the Pocket has not answered */
void drive_poll(void)
{
    if (fetch_slot >= 0 && now_us() - fetch_t0 > FETCH_WAIT_US) fetch_fail(0);
}

/* Read/Write(&{pos64, &len}, &{buf, thread, offset}, &status, drive) */
static s32 rw(int write, u32 a0, u32 a1, u32 st, u32 h)
{
    struct ldrive *l = drv(h);
    if (!l) return KErrBadHandle;
    u32 pos = uread32(a0), poshi = uread32(a0 + 4);
    int len = (int)uread32(uread32(a0 + 8));
    u32 buf = uread32(a1);
    struct thread *t = (struct thread *)handle_lookup(cur, uread32(a1 + 4), O_THREAD);
    int off = (int)uread32(a1 + 8);
    s32 r;
    u32 size = media[l->unit].size;
    if (!t) r = KErrBadHandle;
    else if (!media[l->unit].max) r = KErrNotReady;
    else if (poshi || len < 0 || pos > size || len > (int)(size - pos)) r = KErrArgument;
    else if (l->unit == 2 && cached) {
        if (kflags & DBGF_DRIVE) kprintf("[drive] E: %s %x+%x%s\n", write ? "write" : "read", pos, len,
                                         rq_n ? ", queued" : "");
        if (rq_n == NREQ) kpanic("E: more than %d requests at once", NREQ);
        struct ereq *q = &rq[(rq_head + rq_n++) % NREQ];
        q->caller = cur; q->t = t; q->st = st; q->buf = buf; q->pos = pos;
        q->write = write; q->off = off; q->left = len; q->r = KErrNone;
        obj_ref(&cur->o);
        obj_ref(&t->o);
        e_run();
        return KErrNone;
    }
    else if (write && l->unit == 0) { r = program(t, buf, media[0].base + pos, len, off); IO(IO_SAVE_DIRTY) = 1; }
    else if (write) r = from_des(t, buf, media[l->unit].base + pos, len, off);
    else r = to_des(t, buf, media[l->unit].base + pos, len, off);
    if (kflags & DBGF_IPC) {
        kprintf("[drive] %d %s %x+%x -> %d (des %p off %d):", l->unit, write ? "write" : "read", pos, len, r, buf, off);
        for (int i = 0; i < len && i < 16; i++) kprintf(" %02x", ((u8 *)(media[l->unit].base + pos))[i]);
        kprintf("\n");
    }
    request_complete(cur, st, r);
    return KErrNone;
}

/* Format(&pos64, &len, &status, drive): erase, as flash does, to 0xFF */
static s32 erase(u32 a0, u32 a1, u32 st, u32 h)
{
    struct ldrive *l = drv(h);
    if (!l) return KErrBadHandle;
    u32 pos = uread32(a0), poshi = uread32(a0 + 4);
    int len = (int)uread32(a1);
    u32 size = media[l->unit].size;
    s32 r = KErrNone;
    if (!media[l->unit].max) r = KErrNotReady;
    else if (poshi || len < 0 || pos > size || len > (int)(size - pos)) r = KErrArgument;
    else if (l->unit == 2 && cached) r = KErrNotSupported;
    else {
        memset((void *)(media[l->unit].base + pos), 0xFF, len);
        if (l->unit == 0) IO(IO_SAVE_DIRTY) = 1;
    }
    if (kflags & DBGF_IPC) kprintf("[drive] %d erase %x+%x -> %d\n", l->unit, pos, len, r);
    request_complete(cur, st, r);
    return KErrNone;
}

static s32 caps(u32 d, u32 h)
{
    struct ldrive *l = drv(h);
    if (!l) return KErrBadHandle;
    int u = l->unit;
    u32 w[10] = {
        media[u].size, 0,                          /* iSize                       */
        media[u].max ? media[u].type : 0,          /* iType (0: not present)      */
        0,                                         /* iBattery                    */
        media[u].driveatt,
        media[u].mediaatt,
        media[u].type == 5 ? media[u].base : 0,    /* iBaseAddress: RAM only      */
        media[u].fsid,                             /* iFileSystemId               */
        0,                                         /* V2: iHiddenSectors          */
        media[u].erase,                            /* V2: iEraseBlockSize         */
    };
    int n = des_maxlen(d);
    if (n > (int)sizeof w) n = sizeof w;
    return des_write8(d, (const u8 *)w, n);
}

s32 drive_exec(int idx, u32 a0, u32 a1, u32 a2, u32 a3)
{
    switch (idx) {
    case 0xB7: {                                   /* bus device: {name, unit} */
        int unit = (int)uread32(a0 + 4);
        return unit < NUNITS ? unit + 1 : -1;
    }
    case 0x8F: return rw(0, a0, a1, a2, a3);
    case 0x90: return rw(1, a0, a1, a2, a3);
    case 0x91: return caps(a0, a1);
    case 0x92: return erase(a0, a1, a2, a3);
    }
    kpanic("drive exec %x (%x %x %x %x)", idx, a0, a1, a2, a3);
}

/* executor 0x38: connect {unit, &status, &changed, TPtr8(&handle)};
 *          0x39: disconnect {handle, &status}
 *          0x3B: mount, completing the TRequestStatus at +4
 *          0x3C/0x3D: Enlarge/ReduceSize, for variable-size media
 *          0x3E: media change notification */
s32 drive_executor(struct thread *t, int sub, u32 a)
{
    if (sub == 0x38) {
        int unit = (int)uread32(a);
        if (unit >= NUNITS) return KErrNotSupported;
        struct ldrive *l = (struct ldrive *)obj_new(O_DEVICE, sizeof(struct ldrive), t->proc);
        l->unit = unit;
        u32 h = handle_make(t, &l->o, 0);
        u32 d = uread32(a + 12);
        uwrite32(des_ptr(d), h);
        des_setlen(d, 4);
        uwrite32(uread32(a + 4), media[unit].max ? KErrNone : (u32)KErrNotReady);
        return KErrNone;
    }
    if (sub == 0x3B) {                         /* mount: {handle, &TRequestStatus, start result, mount info} */
        struct ldrive *l = (struct ldrive *)handle_lookup(t, uread32(a), O_DEVICE);
        s32 r = !l ? KErrBadHandle : media[l->unit].max ? KErrNone : KErrNotReady;
        request_complete(t, uread32(a + 4), r);
        return KErrNone;
    }
    if (sub == 0x3C || sub == 0x3D) {          /* Enlarge {h, len}; ReduceSize {h, pos, len} */
        struct ldrive *l = (struct ldrive *)handle_lookup(t, uread32(a), O_DEVICE);
        if (!l) return KErrBadHandle;
        int u = l->unit;
        if (!(media[u].mediaatt & 0x01)) return KErrNotSupported;
        u32 b = media[u].base, size = media[u].size;
        s32 r = KErrNone;
        if (sub == 0x3C) {
            u32 n = uread32(a + 4);
            if (n > media[u].max - size) r = KErrDiskFull;
            else { memset((void *)(b + size), 0, n); media[u].size = size + n; }
        } else {
            u32 pos = uread32(a + 4), n = uread32(a + 8);
            if (pos > size || n > size - pos) r = KErrArgument;
            else { memmove((void *)(b + pos), (void *)(b + pos + n), size - pos - n); media[u].size = size - n; }
        }
        if (kflags & DBGF_IPC) kprintf("[drive] %d %s -> size %x (%d)\n", u, sub == 0x3C ? "enlarge" : "reduce", media[u].size, r);
        return r;
    }
    if (sub == 0x3E) {                         /* {1, device, &status}: MediaChangeNotify;
                                                  {0, device}: ForceRemountMedia */
        int dev = (int)uread32(a + 4);
        if (dev < 0 || dev >= 16) return KErrArgument;
        if (uread32(a) == 1) {
            change[dev].t = t;                 /* the card never changes: it stays pending */
            change[dev].st = uread32(a + 8);
            uwrite32(change[dev].st, (u32)KRequestPending);
        } else if (change[dev].t) {
            request_complete(change[dev].t, change[dev].st, KErrNone);
            change[dev].t = 0;
        }
        return KErrNone;
    }
    if (sub == 0x39) {
        handle_close(t, uread32(a));
        uwrite32(uread32(a + 4), (u32)KErrNotReady);
        return KErrNone;
    }
    return KErrNotSupported;
}
