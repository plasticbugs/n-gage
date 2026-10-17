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
#define LI_ENTRY      0x02C
#define LI_TGTCODE    0x040
#define LI_DATARUN    0x048     /* where the loader copies .data: a home it can reach */
#define LI_FILENAME   0x050
#define LI_FROMRAM    0x668
#define LI_ISDLL      0x66C
#define LI_ALREADY    0x670
#define LI_HANDLE     0x674
#define LI_THREAD     0x678
#define LI_PROCESS    0x67C
#define LI_HANDLEMASK 0x684
#define LI_PRIORITY   0x688
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

static s32 library_create(struct thread *t, u32 li)
{
    trace("library", li);
    if (uread32(li + LI_FROMRAM)) {
        loader_info_dump(li);
        kpanic("loading a library into RAM: not yet");
    }
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

static s32 process_create(struct thread *t, u32 li, u32 cmd, int cmdlen)
{
    trace("process", li);
    if (uread32(li + LI_FROMRAM)) {
        loader_info_dump(li);
        kpanic("loading a process into RAM: not yet");
    }
    const struct rom_image *img = rom_image_at(uread32(li + LI_TGTCODE));
    if (!img) { loader_info_dump(li); kpanic("process: no ROM image at its code address"); }
    u32 d = li + LI_FILENAME;
    u16 path[NAME_MAX];
    int n = uread32(d) & 0xFFFF;
    if (n > NAME_MAX) n = NAME_MAX;
    ucopy_from(path, d + 8, n * 2);
    struct process *p = proc_new(path, n);
    proc_setup_from_rom(p, img);
    if (cmd && cmdlen > 0) {
        if (cmdlen > 256) cmdlen = 256;
        ucopy_from(p->cmd, cmd + 4, cmdlen * 2);   /* HBufC16: data after the length */
        p->cmdlen = cmdlen;
    }
    data_home(p, li);
    give_handle(t, li, &p->o);
    return KErrNone;
}

s32 loader_exec(struct thread *t, int sub, u32 args, u32 attr)
{
    u32 a0 = uread32(args), a1 = uread32(args + 4), a2 = uread32(args + 8);
    switch (sub) {
    case 0x0C: return library_create(t, des_ptr(a0));
    case 0x0D: return KErrNone;                    /* LibraryLoaded         */
    case 0x1C: return process_create(t, des_ptr(a0), a1, (int)a2);
    case 0x1D:                                     /* ProcessLoaded: .data is in */
        if (home) { vm_unalias(home); home = 0; }
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
