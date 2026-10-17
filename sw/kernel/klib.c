/* The kernel's C library: the debug console and the mem* functions gcc
 * expects to exist. */
#include "kern.h"

typedef __builtin_va_list va_list;
#define va_start __builtin_va_start
#define va_arg   __builtin_va_arg
#define va_end   __builtin_va_end

void kputc(int c) { IO(IO_DBG_PUTC) = (u32)c; }
void kputs(const char *s) { while (*s) kputc(*s++); }

static void put_num(u64 v, int base, int width, int zero, int neg)
{
    char buf[24];
    int n = 0;
    do { int d = (int)(v % base); buf[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v /= base; } while (v);
    if (neg) buf[n++] = '-';
    while (n < width) { kputc(zero ? '0' : ' '); width--; }
    while (n) kputc(buf[--n]);
}

static void vkprintf(const char *f, va_list ap)
{
    for (; *f; f++) {
        if (*f != '%') { kputc(*f); continue; }
        f++;
        int zero = 0, width = 0, lng = 0;
        if (*f == '0') { zero = 1; f++; }
        while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
        if (*f == 'l') { lng = 1; f++; if (*f == 'l') f++; }
        switch (*f) {
        case 'd': {
            s64 v = lng ? va_arg(ap, s64) : va_arg(ap, s32);
            put_num(v < 0 ? (u64)-v : (u64)v, 10, width, zero, v < 0);
            break; }
        case 'u': put_num(lng ? va_arg(ap, u64) : va_arg(ap, u32), 10, width, zero, 0); break;
        case 'x': put_num(lng ? va_arg(ap, u64) : va_arg(ap, u32), 16, width, zero, 0); break;
        case 'p': put_num(va_arg(ap, u32), 16, 8, 1, 0); break;
        case 'c': kputc(va_arg(ap, int)); break;
        case 's': { const char *s = va_arg(ap, const char *); kputs(s ? s : "(null)"); break; }
        case '%': kputc('%'); break;
        default:  kputc('%'); kputc(*f); break;
        }
    }
}

void kprintf(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt); vkprintf(fmt, ap); va_end(ap);
}

void kpanic(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    kputs("\nKERNEL PANIC: "); vkprintf(fmt, ap); kputc('\n');
    va_end(ap);
    for (;;) IO(IO_DBG_EXIT) = 1;
}

void *memcpy(void *d, const void *s, unsigned n)
{
    u8 *dp = d; const u8 *sp = s;
    if ((((u32)dp | (u32)sp | n) & 3) == 0) {
        u32 *dw = d; const u32 *sw = s;
        for (n >>= 2; n; n--) *dw++ = *sw++;
        return d;
    }
    while (n--) *dp++ = *sp++;
    return d;
}

void *memmove(void *d, const void *s, unsigned n)
{
    u8 *dp = d; const u8 *sp = s;
    if (dp <= sp || dp >= sp + n) { while (n--) *dp++ = *sp++; }
    else { dp += n; sp += n; while (n--) *--dp = *--sp; }
    return d;
}

void *memset(void *d, int v, unsigned n)
{
    u8 *dp = d;
    while (n--) *dp++ = (u8)v;
    return d;
}

int memcmp(const void *a, const void *b, unsigned n)
{
    const u8 *x = a, *y = b;
    for (; n; n--, x++, y++) if (*x != *y) return *x - *y;
    return 0;
}
