/* The descriptor searches EKA1 does in the kernel: Match, FindF, LocateF,
 * for 8- and 16-bit text.  `unit` is the character size in bytes. */
#include "kobj.h"

static int ch(u32 p, int i, int unit) { return unit == 1 ? *(const u8 *)(p + i) : *(const u16 *)(p + 2 * i); }
static int fold(int c, int f)
{
    if (!f) return c;
    if ((c >= 'a' && c <= 'z') || (c >= 0xE0 && c <= 0xFE && c != 0xF7)) return c - 32;
    return c;
}

static int wild(u32 p, int pn, u32 s, int sn, int unit, int f)
{
    int pi = 0, si = 0, star = -1, mark = 0;
    while (si < sn) {
        if (pi < pn && ch(p, pi, unit) == '*') { star = pi++; mark = si; continue; }
        if (pi < pn && (ch(p, pi, unit) == '?' || fold(ch(p, pi, unit), f) == fold(ch(s, si, unit), f))) { pi++; si++; continue; }
        if (star < 0) return 0;
        pi = star + 1;
        si = ++mark;
    }
    while (pi < pn && ch(p, pi, unit) == '*') pi++;
    return pi == pn;
}

/* TDesC::Match: KErrNotFound, or where the match begins -- after whatever a
 * leading '*' swallowed. */
s32 des_match(u32 d, u32 pd, int f, int unit)
{
    u32 s = des_ptr(d), p = des_ptr(pd);
    int sn = des_len(d), pn = des_len(pd);
    int k = 0;
    while (k < pn && ch(p, k, unit) == '*') k++;
    if (!k) return wild(p, pn, s, sn, unit, f) ? 0 : KErrNotFound;
    if (k == pn) return 0;
    for (int i = 0; i <= sn; i++)
        if (wild(p + k * unit, pn - k, s + i * unit, sn - i, unit, f)) return i;
    return KErrNotFound;
}

s32 des_find(u32 d, u32 str, int n, int f, int unit)
{
    u32 s = des_ptr(d);
    int sn = des_len(d);
    if (n < 0) return KErrArgument;
    if (!n) return KErrNotFound;
    for (int i = 0; i + n <= sn; i++) {
        int j = 0;
        while (j < n && fold(ch(s, i + j, unit), f) == fold(ch(str, j, unit), f)) j++;
        if (j == n) return i;
    }
    return KErrNotFound;
}

s32 des_locate(u32 d, int c, int f, int unit)
{
    u32 s = des_ptr(d);
    int sn = des_len(d);
    for (int i = 0; i < sn; i++) if (fold(ch(s, i, unit), f) == fold(c, f)) return i;
    return KErrNotFound;
}
