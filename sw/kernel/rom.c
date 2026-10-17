/* The firmware image: its header, its directory tree, its image headers.
 * Layouts are EKA1's (Symbian 6.1), read from the image itself; see
 * docs/hardware.md. */
#include "kern.h"
#include "rom.h"

#define ROMHDR_ROOTDIRLIST  0x94

static u32 rd32(u32 a) { return *(volatile u32 *)a; }

static int fold(int c) { return (c >= 'a' && c <= 'z') ? c - 32 : c; }

/* Compare a UTF-16 ROM name with an ASCII component, ignoring case. */
static int name_eq(const u16 *u, int ulen, const char *a, int alen)
{
    if (ulen != alen) return 0;
    for (int i = 0; i < ulen; i++)
        if (fold(u[i]) != fold((u8)a[i])) return 0;
    return 1;
}

static const struct rom_entry *dir_find(u32 dir, const char *name, int len)
{
    u32 size = rd32(dir);
    u32 p = dir + 4, end = dir + 4 + size;
    while (p < end) {
        const struct rom_entry *e = (const struct rom_entry *)p;
        if (name_eq(e->name, e->name_len, name, len)) return e;
        p += 10 + 2 * e->name_len;
        p = (p + 3) & ~3u;
    }
    return 0;
}

/* Path like "\\System\\Libs\\EUser.dll" (or with Z: in front, or with '/'). */
const struct rom_entry *rom_find(const char *path)
{
    u32 list = rd32(NGVM_ROM_BASE + ROMHDR_ROOTDIRLIST);
    if (rd32(list) < 1) return 0;
    u32 dir = rd32(list + 8);                    /* first root dir's address */
    if (path[0] && path[1] == ':') path += 2;
    const struct rom_entry *e = 0;
    while (*path) {
        while (*path == '\\' || *path == '/') path++;
        if (!*path) break;
        int n = 0;
        while (path[n] && path[n] != '\\' && path[n] != '/') n++;
        if (e && !(e->att & ROM_ATT_DIR)) return 0;
        e = dir_find(e ? e->addr : dir, path, n);
        if (!e) return 0;
        path += n;
    }
    return e;
}

const struct rom_image *rom_image(const char *path)
{
    const struct rom_entry *e = rom_find(path);
    if (!e || (e->att & ROM_ATT_DIR)) return 0;
    return (const struct rom_image *)e->addr;
}

int rom_valid(void)
{
    return rd32(NGVM_ROM_BASE + 0x8C) == NGVM_ROM_BASE && IO(IO_ROM_SIZE) > 0x100000;
}
