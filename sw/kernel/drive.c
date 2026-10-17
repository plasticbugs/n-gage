/* Local drives: what EFile's TBusLocalDrive reaches through the kernel.
 *
 *   unit 0  C:  the internal drive: NOR flash under Nokia's LFFS (ELOCAL.FSY
 *               on this firmware is LFFS, not FAT).  1 MB of RAM, erased to
 *               0xFF at boot, so every run starts from a factory-fresh phone
 *               and LFFS formats it on the first mount
 *   unit 1  D:  the RAM drive: FAT under ERAM.FSY, which reaches the memory
 *               directly through the caps' iBaseAddress.  Its size varies:
 *               the file system grows and shrinks it (Enlarge/ReduceSize)
 *   unit 2  E:  the memory card: the game's image at NGVM_DRIVE_BASE
 *
 * TBusLocalDrive (EUser) is { +0 bus handle, +4 media status, +8 drive
 * handle }.  Connect asks for the bus handle (exec 0x8000B7), then for a
 * drive (executor 0x38); reads, writes and erases are execs 0x8F/0x90/0x92
 * and finish at once. */
#include "kobj.h"
#include "mm.h"

#define NUNITS 3
#define C_SIZE (1024 * 1024)
#define C_ERASE (64 * 1024)
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

void drive_init(void)
{
    u32 c = vm_reserve(C_SIZE);
    if (!c || vm_commit(c, C_SIZE)) kpanic("no memory for C:");
    memset((void *)c, 0xFF, C_SIZE);         /* erased flash */
    media[0].base = c;
    media[0].size = media[0].max = C_SIZE;
    u32 d = vm_reserve(D_MAX);
    if (!d || vm_commit(d, D_MAX)) kpanic("no memory for D:");
    media[1].base = d;
    media[1].max = D_MAX;
    media[2].size = media[2].max = IO(IO_DRIVE_SIZE);
    if (kflags & DBGF_IPC) kprintf("[drive] C: at %p, D: at %p, E: %x bytes\n", c, d, media[2].size);
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

/* NOR flash: programming only clears bits; erase sets them again */
static s32 program(struct thread *t, u32 d, u32 dst, int n, int off)
{
    static u8 b[512];
    while (n > 0) {
        int k = n > (int)sizeof b ? (int)sizeof b : n;
        from_des(t, d, (u32)b, k, off);
        for (int i = 0; i < k; i++) ((u8 *)dst)[i] &= b[i];
        dst += k; off += k; n -= k;
    }
    return KErrNone;
}

static struct ldrive *drv(u32 h) { return (struct ldrive *)handle_lookup(cur, h, O_DEVICE); }

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
    else if (write && l->unit == 0) r = program(t, buf, media[0].base + pos, len, off);
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
    else memset((void *)(media[l->unit].base + pos), 0xFF, len);
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
