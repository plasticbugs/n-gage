/* User memory and Symbian descriptors, seen from the kernel.
 *
 * There is one address space, so a user pointer is dereferenced as it is --
 * except in the data window, which shows the running process's data.  Code
 * that touches another thread's memory switches that thread's process in
 * first (proc_switch_in) and the current one back after. */
#include "kobj.h"

u32  uread32(u32 a) { return *(volatile u32 *)a; }
void uwrite32(u32 a, u32 v) { *(volatile u32 *)a = v; }
void ucopy_from(void *dst, u32 src, u32 n) { memcpy(dst, (const void *)src, n); }
void ucopy_to(u32 dst, const void *src, u32 n) { memcpy((void *)dst, src, n); }

/* word 0 of every descriptor: type << 28 | length */
int des_type(u32 d) { return uread32(d) >> 28; }
int des_len(u32 d) { return uread32(d) & 0x0FFFFFFF; }

int des_maxlen(u32 d)
{
    switch (des_type(d)) {
    case 2: case 3: case 4: return uread32(d + 4);
    default: return des_len(d);           /* constant: no room beyond it */
    }
}

/* Where the characters are. */
u32 des_ptr(u32 d)
{
    switch (des_type(d)) {
    case 0: return d + 4;                 /* TBufC */
    case 1: return uread32(d + 4);        /* TPtrC */
    case 2: return uread32(d + 8);        /* TPtr  */
    case 3: return d + 8;                 /* TBuf  */
    case 4: return uread32(d + 8) + 4;    /* TPtr over a TBufC */
    }
    kpanic("descriptor %p: type %d", d, des_type(d));
}

void des_setlen(u32 d, int len)
{
    uwrite32(d, (uread32(d) & 0xF0000000u) | (u32)len);
    if (des_type(d) == 4) {               /* the TBufC it points at, too */
        u32 b = uread32(d + 8);
        uwrite32(b, (uread32(b) & 0xF0000000u) | (u32)len);
    }
}

int des_read16(u32 d, u16 *buf, int max)
{
    int n = des_len(d);
    if (n > max) n = max;
    ucopy_from(buf, des_ptr(d), n * 2);
    return n;
}

int des_read8(u32 d, u8 *buf, int max)
{
    int n = des_len(d);
    if (n > max) n = max;
    ucopy_from(buf, des_ptr(d), n);
    return n;
}

int des_write16(u32 d, const u16 *buf, int n)
{
    if (n > des_maxlen(d)) return KErrOverflow;
    ucopy_to(des_ptr(d), buf, n * 2);
    des_setlen(d, n);
    return KErrNone;
}

int des_write8(u32 d, const u8 *buf, int n)
{
    if (n > des_maxlen(d)) return KErrOverflow;
    ucopy_to(des_ptr(d), buf, n);
    des_setlen(d, n);
    return KErrNone;
}

void kputs16(const u16 *s, int n)
{
    for (int i = 0; i < n; i++) kputc(s[i] < 128 ? s[i] : '?');
}

void kputdes16(u32 d)
{
    u16 b[128];
    int n = des_read16(d, b, 128);
    kputs16(b, n);
}

/* ASCII copy of a 16-bit descriptor, for the kernel's own use */
int des_to_ascii(u32 d, char *out, int max)
{
    u16 b[256];
    int n = des_read16(d, b, max - 1 < 256 ? max - 1 : 256);
    for (int i = 0; i < n; i++) out[i] = b[i] < 128 ? (char)b[i] : '?';
    out[n] = 0;
    return n;
}

int u16_eq_fold(const u16 *a, int an, const u16 *b, int bn)
{
    if (an != bn) return 0;
    for (int i = 0; i < an; i++) {
        int x = a[i], y = b[i];
        if (x >= 'a' && x <= 'z') x -= 32;
        if (y >= 'a' && y <= 'z') y -= 32;
        if (x != y) return 0;
    }
    return 1;
}

/* Can the kernel read [a, a+n) without faulting?  For traces only. */
int uaddr_ok(u32 a, u32 n)
{
    extern int vm_mapped(u32 va);
    u32 e = a + n;
    if (e < a) return 0;
    if (a >= NGVM_ROM_BASE && e <= NGVM_ROM_BASE + IO(IO_ROM_SIZE)) return 1;
    if (a >= NGVM_KSEC_BASE && e <= NGVM_KSEC_BASE + NGVM_KSEC_SIZE) return 1;
    for (u32 p = a & ~(NGVM_PAGE_SIZE - 1); p < e; p += NGVM_PAGE_SIZE)
        if (!vm_mapped(p)) return 0;
    return (a >= NGVM_CHUNK_BASE && e <= NGVM_CHUNK_BASE + NGVM_CHUNK_SIZE) ||
           (a >= NGVM_DATA_BASE && e <= NGVM_DATA_BASE + NGVM_DATA_SIZE);
}

/* If d looks like a descriptor of text, print it in quotes. */
void trace_des(u32 d)
{
    if ((d & 3) || !uaddr_ok(d, 12)) return;
    u32 w = uread32(d);
    int t = w >> 28, n = w & 0x0FFFFFFF;
    if (t > 4 || n == 0 || n > 256) return;
    u32 p = des_ptr(d);
    if (!uaddr_ok(p, n * 2)) return;
    const u16 *s = (const u16 *)p;
    int text16 = !(p & 1);
    for (int i = 0; i < n && text16; i++) if (s[i] < 32 || s[i] > 126) text16 = 0;
    if (text16) { kputs(" \""); kputs16(s, n); kputs("\""); return; }
    const u8 *b = (const u8 *)p;
    for (int i = 0; i < n; i++) if (b[i] < 32 || b[i] > 126) return;
    kputs(" '");
    for (int i = 0; i < n; i++) kputc(b[i]);
    kputs("'");
}
