/* The kernel's half of the loader.  EFile's loader thread finds the file,
 * reads its header into a TLoaderInfo (e32svr.h; 0x694 bytes) and asks:
 *   0x0C LibraryCreateExact(info)   0x0D LibraryLoaded(info)
 *   0x1C ProcessCreate(info, cmd)    0x1D ProcessLoaded(info)
 *   0x4B Dll/ExeAddDependency(importer, exporter)
 * For an image in ROM the info already holds the ROM header's fields and
 * nothing is copied; the kernel makes the object and hands the loader's
 * client a handle to it. */
#include "kobj.h"
#include "mm.h"

/* TLoaderInfo offsets */
#define LI_UID        0x000
#define LI_CODESIZE   0x014
#define LI_DATASIZE   0x018
#define LI_HEAPMIN    0x01C
#define LI_HEAPMAX    0x020
#define LI_STACK      0x024
#define LI_BSSSIZE    0x028
#define LI_ENTRY      0x02C     /* RAM image: an offset into its code */
#define LI_DLLREF     0x030
#define LI_DLLREFS    0x034
#define LI_EXPDIR     0x038
#define LI_EXPCOUNT   0x03C
#define LI_TGTCODE    0x040     /* where the loader writes the code   */
#define LI_TGTCODEBASE 0x044    /* where it runs: relocated for this  */
#define LI_DATARUN    0x048     /* where the loader copies .data: a home it can reach */
#define LI_DATABASE   0x04C     /* where .data runs: relocated for this */
#define LI_FILENAME   0x050
#define LI_FROMRAM    0x668
#define LI_ISDLL      0x66C
#define LI_ALREADY    0x670
#define LI_HANDLE     0x674
#define LI_THREAD     0x678
#define LI_PROCESS    0x67C
#define LI_HANDLEMASK 0x684
#define LI_PRIORITY   0x688
#define LI_TEXTSIZE   0x68C
#define LI_LIBPTR     0x690

extern void loader_info_dump(u32 li);
extern struct process *proc_new(const u16 *path, int n);
extern void proc_setup_from_rom(struct process *p, const struct rom_image *img);

static const struct rom_image *rom_image_at(u32 code)
{
    const struct rom_image *img = (const struct rom_image *)(code - sizeof(struct rom_image));
    if (code - NGVM_ROM_BASE >= IO(IO_ROM_SIZE) || img->code_addr != code) return 0;
    return img;
}

/* the thread the loader works for, and where its handle goes */
static u32 give_handle(struct thread *t, u32 li, struct kobj *o)
{
    struct thread *client = (struct thread *)handle_lookup(t, uread32(li + LI_THREAD), O_THREAD);
    if (!client) client = t;
    u32 h = handle_make_pair(t, client, o, (uread32(li + LI_HANDLEMASK) & HANDLE_THREAD_OWNED) != 0);
    uwrite32(li + LI_HANDLE, h);
    if (kflags & DBGF_EXEC) { kprintf("[loader] handle %x for ", h); kputs16(client->o.name, client->o.namelen); kprintf("\n"); }
    uwrite32(li + LI_LIBPTR, (u32)o);
    return h;
}

static void trace(const char *what, u32 li)
{
    if (!(kflags & DBGF_EXEC)) return;
    u32 d = li + LI_FILENAME;
    kprintf("[loader] %s ", what);
    kputs16((const u16 *)(d + 8), uread32(d) & 0xFFFF);
    kprintf("\n");
}

static int li_name(u32 li, u16 *path)
{
    u32 d = li + LI_FILENAME;
    int n = uread32(d) & 0xFFFF;
    if (n > NAME_MAX) n = NAME_MAX;
    ucopy_from(path, d + 8, n * 2);
    return n;
}

static void lib_set_name(struct library *l, const u16 *path, int n)
{
    memcpy(l->fname, path, n * 2);
    l->fnamelen = n;
    int s = n, e = n;
    while (s > 0 && path[s - 1] != '\\') s--;
    for (int i = s; i < n; i++) if (path[i] == '.') e = i;
    obj_set_name(&l->o, path + s, e - s);
    l->o.global = 1;
}

/* A DLL from a file (a game's .app): EFile's loader reads the E32 image
 * itself.  The kernel gives it code memory and says where the code will
 * run; the loader writes the code there, relocates it by the difference
 * from the image's own code base, puts the DLL reference table right after
 * the code, loads each import (DllAddDependency names them) and then calls
 * LibraryLoaded.  One address space: written where it runs.  EKA1 gives a
 * RAM DLL no writable static data. */
static s32 library_create_ram(struct thread *t, u32 li)
{
    extern int u16_eq_fold(const u16 *, int, const u16 *, int);
    u16 path[NAME_MAX];
    int n = li_name(li, path);
    for (struct kobj *o = obj_first(O_LIBRARY); o; o = o->next) {
        struct library *l = (struct library *)o;
        if (l->rom || !u16_eq_fold(l->fname, l->fnamelen, path, n)) continue;
        uwrite32(li + LI_TGTCODE, l->code_base);
        uwrite32(li + LI_TGTCODEBASE, l->code_base);
        uwrite32(li + LI_ALREADY, 1);
        give_handle(t, li, &l->o);
        return KErrNone;
    }
    if (uread32(li + LI_DATASIZE) || uread32(li + LI_BSSSIZE)) {
        loader_info_dump(li);
        kpanic("a RAM DLL with static data");
    }
    u32 code = uread32(li + LI_CODESIZE);
    u32 refs = uread32(li + LI_DLLREFS);
    u32 size = code + 4 + 8 * refs;           /* the code, then the reference table */
    struct library *l = (struct library *)obj_new(O_LIBRARY, sizeof(struct library), 0);
    l->chunk = vm_reserve(size);
    if (!l->chunk || vm_commit(l->chunk, size)) { obj_unref(&l->o); return KErrNoMemory; }
    for (int i = 0; i < 3; i++) l->uid[i] = uread32(li + LI_UID + 4 * i);
    l->code_base = l->chunk;
    l->code_size = code;
    l->text_size = uread32(li + LI_TEXTSIZE);
    l->entry = l->code_base + uread32(li + LI_ENTRY);
    lib_set_name(l, path, n);
    uwrite32(li + LI_TGTCODE, l->code_base);
    uwrite32(li + LI_TGTCODEBASE, l->code_base);
    uwrite32(li + LI_ALREADY, 0);
    if (kflags & DBGF_IPC) {
        kprintf("[loader] RAM library ");
        kputs16(path, n);
        kprintf(" code %p+%x entry %p\n", l->code_base, code, l->entry);
    }
    give_handle(t, li, &l->o);
    return KErrNone;
}

/* LibraryLoaded: the loader has written the export directory's address */
static s32 library_loaded(u32 li)
{
    struct library *l = (struct library *)uread32(li + LI_LIBPTR);
    if (!l || l->rom || l->loaded) return KErrNone;
    l->export_dir = uread32(li + LI_EXPDIR);
    l->export_count = uread32(li + LI_EXPCOUNT);
    l->loaded = 1;
    IO(IO_CACHE_FLUSH) = 1;                   /* code was written as data */
    return KErrNone;
}

static s32 library_create(struct thread *t, u32 li)
{
    trace("library", li);
    if (uread32(li + LI_FROMRAM)) return library_create_ram(t, li);
    const struct rom_image *img = rom_image_at(uread32(li + LI_TGTCODE));
    if (!img) { loader_info_dump(li); kpanic("library: no ROM image at its code address"); }
    struct library *l = lib_for_rom(img);
    u32 d = li + LI_FILENAME;
    if (!l->fnamelen) {
        int n = uread32(d) & 0xFFFF;
        if (n > NAME_MAX) n = NAME_MAX;
        ucopy_from(l->fname, d + 8, n * 2);
        l->fnamelen = n;
        int s = n, e = n;
        while (s > 0 && l->fname[s - 1] != '\\') s--;
        for (int i = s; i < n; i++) if (l->fname[i] == '.') e = i;
        obj_set_name(&l->o, l->fname + s, e - s);
        l->o.global = 1;
    }
    uwrite32(li + LI_ALREADY, 1);              /* ROM code needs no loading */
    give_handle(t, li, &l->o);
    return KErrNone;
}

/* After ProcessCreate, EFile's loader copies the image's .data to
 * LI_DATARUN itself.  EKA1 put the new process's data home address there;
 * NGVM's process data lives in pages seen only through the data window, so
 * the same pages are mapped again in chunk space until ProcessLoaded. */
static u32 home;                              /* the alias awaiting ProcessLoaded */

static void data_home(struct process *p, u32 li)
{
    if (!p->win_pages) return;                /* fixed process, or no data */
    if (home) vm_unalias(home);
    home = vm_reserve(p->win_pages << NGVM_PAGE_SHIFT);
    if (!home) kpanic("no address space for a data home");
    for (int i = 0; i < p->win_pages; i++) vm_alias(home + ((u32)i << NGVM_PAGE_SHIFT), p->win[i]);
    uwrite32(li + LI_DATARUN, home + (p->data_base - NGVM_DATA_BASE));
}

static void proc_cmdline(struct process *p, u32 cmd, int cmdlen)
{
    if (cmd && cmdlen > 0) {
        if (cmdlen > 256) cmdlen = 256;
        ucopy_from(p->cmd, cmd + 4, cmdlen * 2);   /* HBufC16: data after the length */
        p->cmdlen = cmdlen;
    }
    if (kflags & DBGF_IPC) {
        kprintf("[loader] process ");
        kputs16(p->fname, p->fnamelen);
        kprintf(" cmd \"");
        kputs16(p->cmd, p->cmdlen);
        kprintf("\"\n");
    }
}

/* An EXE from a file: System Rush's game, and the small servers some games
 * start (Payload's lmsmssrv, the Airplay games' .nax).  Like a RAM DLL with a
 * process around it and static data: the code, the DLL reference table the
 * loader puts after it (LI_CODESIZE counts it), .data and .bss, in one
 * chunk.  EKA1's moving model ran such data at 0x400000; every one of these
 * images has relocations, so the loader moves code and data to wherever the
 * chunk is, and the process needs no data window.  The loader copies .data
 * in itself; the chunk's pages come zeroed, which is .bss. */
static s32 process_create_ram(struct thread *t, u32 li, u32 cmd, int cmdlen)
{
    u16 path[NAME_MAX];
    int n = li_name(li, path);
    u32 code = (uread32(li + LI_CODESIZE) + 3) & ~3u;
    u32 data = uread32(li + LI_DATASIZE), bss = uread32(li + LI_BSSSIZE);
    u32 base = vm_reserve(code + data + bss);
    if (!base) return KErrNoMemory;
    if (vm_commit(base, code + data + bss)) { vm_release(base); return KErrNoMemory; }
    struct process *p = proc_new(path, n);
    p->chunk = base;
    for (int i = 0; i < 3; i++) p->uid[i] = uread32(li + LI_UID + 4 * i);
    p->entry = base + uread32(li + LI_ENTRY);
    p->heap_min = uread32(li + LI_HEAPMIN);
    p->heap_max = uread32(li + LI_HEAPMAX);
    p->stack_size = uread32(li + LI_STACK);
    p->code_base = base;
    p->code_size = code;
    p->text_size = uread32(li + LI_TEXTSIZE);
    p->data_base = base + code;
    p->data_size = data;
    p->bss_size = bss;
    p->prio = (int)uread32(li + LI_PRIORITY);
    p->loaded = 1;
    thread_create(p, p->entry, 0, p->stack_size, 0, p->heap_min, p->heap_max, 1);
    obj_set_name_a(&p->main->o, "Main");
    uwrite32(li + LI_TGTCODE, base);
    uwrite32(li + LI_TGTCODEBASE, base);
    uwrite32(li + LI_DATARUN, p->data_base);
    uwrite32(li + LI_DATABASE, p->data_base);
    if (kflags & DBGF_IPC) {
        kprintf("[loader] RAM process ");
        kputs16(path, n);
        kprintf(" code %p+%x data %p+%x+%x entry %p\n", base, code, p->data_base, data, bss, p->entry);
    }
    proc_cmdline(p, cmd, cmdlen);
    give_handle(t, li, &p->o);
    return KErrNone;
}

static s32 process_create(struct thread *t, u32 li, u32 cmd, int cmdlen)
{
    trace("process", li);
    if (uread32(li + LI_FROMRAM)) return process_create_ram(t, li, cmd, cmdlen);
    const struct rom_image *img = rom_image_at(uread32(li + LI_TGTCODE));
    if (!img) { loader_info_dump(li); kpanic("process: no ROM image at its code address"); }
    u16 path[NAME_MAX];
    int n = li_name(li, path);
    struct process *p = proc_new(path, n);
    proc_setup_from_rom(p, img);
    proc_cmdline(p, cmd, cmdlen);
    data_home(p, li);
    give_handle(t, li, &p->o);
    return KErrNone;
}

s32 loader_exec(struct thread *t, int sub, u32 args, u32 attr)
{
    u32 a0 = uread32(args), a1 = uread32(args + 4), a2 = uread32(args + 8);
    switch (sub) {
    case 0x0C: return library_create(t, des_ptr(a0));
    case 0x0D: return library_loaded(des_ptr(a0));
    case 0x1C: return process_create(t, des_ptr(a0), a1, (int)a2);
    case 0x1D:                                     /* ProcessLoaded: .data is in */
        if (home) { vm_unalias(home); home = 0; }
        IO(IO_CACHE_FLUSH) = 1;                    /* a RAM image's code was written as data */
        return KErrNone;
    case 0x4B: {                                   /* (0 | importing dll, exporter, importing exe) */
        struct library *exp = (struct library *)a1;
        if (a0) lib_add_dep((struct library *)a0, exp);
        else if (a2) proc_add_dep((struct process *)a2, exp);
        return KErrNone;
    }
    }
    kpanic("loader executor %x", attr);
}
