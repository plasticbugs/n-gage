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

/* The ROM path ("Z:\System\Libs\EUser.dll") of the image whose code holds
 * addr, for UserSvr::DllFileName.  An entry is an image when its code
 * follows its header, as every executable in the image does. */
static int code_walk(u32 dir, u32 addr, u16 *out, int at, int max)
{
    u32 size = rd32(dir);
    u32 p = dir + 4, end = dir + 4 + size;
    while (p < end) {
        const struct rom_entry *e = (const struct rom_entry *)p;
        int n = at;
        if (n + 1 + e->name_len <= max) {
            out[n++] = '\\';
            for (int i = 0; i < e->name_len; i++) out[n++] = e->name[i];
            if (e->att & ROM_ATT_DIR) {
                int r = code_walk(e->addr, addr, out, n, max);
                if (r) return r;
            } else {
                const struct rom_image *img = (const struct rom_image *)e->addr;
                if (img->code_addr == e->addr + 0x64 && addr - img->code_addr < img->code_size) return n;
            }
        }
        p += 10 + 2 * e->name_len;
        p = (p + 3) & ~3u;
    }
    return 0;
}

int rom_path_for_code(u32 addr, u16 *out, int max)
{
    u32 list = rd32(NGVM_ROM_BASE + ROMHDR_ROOTDIRLIST);
    if (rd32(list) < 1 || max < 3) return 0;
    out[0] = 'Z'; out[1] = ':';
    return code_walk(rd32(list + 8), addr, out, 2, max);
}

/* ---- Z: as EFile sees it ---------------------------------------------------
 * EFile walks the ROM directory itself, from the root UserSvr::
 * RomRootDirectoryAddress (exec 0xB8) gives it.  NGVM gives it the image's
 * tree with a few entries added: what a phone's factory-flashed C: or a
 * variant ROM would hold and this image does not.  Each change copies the
 * directories on its path into one kernel-built, user-readable page; the
 * image itself is never written.  EKA1's ROM directories are unsorted, and a
 * directory's own entry carries size 0, so an entry is simply appended. */
#include "mm.h"

static u32 ov_base, ov_used;

static u32 ov_alloc(u32 n)
{
    n = (n + 3) & ~3u;
    if (ov_used + n > NGVM_PAGE_SIZE) kpanic("ROM overlay: page full");
    u32 a = ov_base + ov_used;
    ov_used += n;
    return a;
}

static u32 entry_len(int name_len) { return (10 + 2 * name_len + 3) & ~3u; }

/* A copy of dir (0: a new, empty one) with entry name set to {size, addr}:
 * replaced if it is there, appended with att if not. */
static u32 dir_with(u32 dir, const char *name, int len, u32 size, u32 addr, u8 att)
{
    u32 old = dir ? rd32(dir) : 0;
    u32 nd = ov_alloc(4 + old + entry_len(len));
    u32 p = dir + 4, end = dir + 4 + old, q = nd + 4;
    int found = 0;
    while (dir && p < end) {
        const struct rom_entry *e = (const struct rom_entry *)p;
        u32 n = entry_len(e->name_len);
        memcpy((void *)q, (const void *)p, n);
        if (name_eq(e->name, e->name_len, name, len)) {
            ((u32 *)q)[0] = size; ((u32 *)q)[1] = addr;
            found = 1;
        }
        p += n; q += n;
    }
    if (!found) {
        ((u32 *)q)[0] = size; ((u32 *)q)[1] = addr;
        ((u8 *)q)[8] = att; ((u8 *)q)[9] = (u8)len;
        for (int i = 0; i < len; i++) ((u8 *)q)[10 + 2 * i] = (u8)name[i], ((u8 *)q)[11 + 2 * i] = 0;
        q += entry_len(len);
    }
    *(u32 *)nd = q - nd - 4;
    return nd;
}

/* dir with a file at path ("System\\rfs\\x.txt"), directories made as needed */
static u32 dir_add_file(u32 dir, const char *path, u32 size, u32 addr)
{
    int n = 0;
    while (path[n] && path[n] != '\\') n++;
    if (!path[n]) return dir_with(dir, path, n, size, addr, 0x01);
    const struct rom_entry *e = dir ? dir_find(dir, path, n) : 0;
    u32 sub = dir_add_file(e ? e->addr : 0, path + n + 1, size, addr);
    return dir_with(dir, path, n, 0, sub, ROM_ATT_DIR);
}

/* a text file as the firmware's own .ini files are: UTF-16, a byte-order
 * mark, CRLF line ends */
static u32 dir_add_text(u32 dir, const char *path, const char *text)
{
    int n = 1;
    for (const char *t = text; *t; t++) n += *t == '\n' ? 2 : 1;
    u16 *f = (u16 *)ov_alloc(2 * n);
    int k = 0;
    f[k++] = 0xFEFF;
    for (const char *t = text; *t; t++) {
        if (*t == '\n') f[k++] = '\r';
        f[k++] = (u8)*t;
    }
    return dir_add_file(dir, path, 2 * n, (u32)f);
}

u32 rom_root_dir(void)
{
    static u32 root;
    if (root) return root;
    u32 list = rd32(NGVM_ROM_BASE + ROMHDR_ROOTDIRLIST);
    root = rd32(list + 8);
    ov_base = vm_reserve(NGVM_PAGE_SIZE);
    if (!ov_base || vm_commit(ov_base, NGVM_PAGE_SIZE)) kpanic("no memory for the ROM overlay");
    /* Starter runs this on a first boot (no C:\System\bootdata\FirstBoot.dat)
     * and treats its absence as a failed boot; a phone's factory C: has been
     * through first boot already.  An empty script restores nothing. */
    root = dir_add_file(root, "System\\rfs\\ScriptInit.txt", 0, NGVM_ROM_BASE);
    /* The active profile's settings, as SharedData publishes them, read by
     * MediaServer's sound device before the profile engine has made its
     * database (which then writes its own).  SharedDataServer takes
     * defaults from Z:\System\Shareddata\<uid>.ini, as a variant ROM
     * supplies them; these are NGVM's: General, ringing, mid volume. */
    root = dir_add_text(root, "System\\Shareddata\\100058fa.ini",
                        "RingType=0\nRingVol=4\nVibrAlert=0\nKeyVolume=1\n"
                        "WarnTone=1\nMsgAlert=1\nActive=0\n");
    return root;
}
