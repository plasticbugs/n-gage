/* Processes, threads, and the code they run.
 *
 * A thread starts in user mode at thread_tramp (start.S), which builds its
 * heap with EUser's own UserHeap::ChunkHeap, installs it with
 * User::SwitchHeap, and calls User::StartThread(func, ptr): EUser then
 * attaches the DLLs (exec StaticCallList), runs the function and exits.  EKA1
 * built the heap in the kernel; doing it in user mode with the ROM's code
 * gives the same heap without a second implementation of RHeap. */
#include "kobj.h"
#include "mm.h"

#define EUSER_CHUNKHEAP   166      /* UserHeap::ChunkHeap(const TDesC*, TInt, TInt, TInt) */
#define EUSER_STARTTHREAD 1105     /* User::StartThread(TThreadFunction, TAny*)           */
#define EUSER_SWITCHHEAP  1127     /* User::SwitchHeap(RHeap*)                            */

extern char thread_tramp[];
static u32 next_id = 1;
u32 euser_export(int ord)
{
    static const struct rom_image *eu;
    if (!eu) eu = rom_image("\\System\\Libs\\EUser.dll");
    if (!eu) kpanic("EUser.dll not in ROM");
    return uread32(eu->export_dir + 4 * (ord - 1));
}

/* "Z:\System\Libs\EFile.exe" -> name "EFile" */
static void name_from_path(struct kobj *o, const u16 *path, int n)
{
    int s = n, e = n;
    while (s > 0 && path[s - 1] != '\\') s--;
    for (int i = s; i < n; i++) if (path[i] == '.') e = i;
    obj_set_name(o, path + s, e - s);
}

struct thread *thread_create(struct process *p, u32 func, u32 ptr, u32 stack, u32 heap,
                             u32 heap_min, u32 heap_max, int first)
{
    struct thread *t = (struct thread *)obj_new(O_THREAD, sizeof(struct thread), p);
    t->proc = p;
    t->id = next_id++;
    t->exit_type = 3;
    if (stack < 0x1000) stack = 0x1000;
    stack = (stack + NGVM_PAGE_SIZE - 1) & ~(NGVM_PAGE_SIZE - 1);
    t->stack_base = vm_reserve(stack);
    if (!t->stack_base || vm_commit(t->stack_base, stack)) kpanic("no memory for a %u-byte stack", stack);
    t->stack_size = stack;
    t->first_in_process = first;
    t->heap = heap;
    struct ctx *c = &t->ctx;
    memset(c, 0, sizeof *c);
    c->r[4] = func;
    c->r[5] = ptr;
    c->r[6] = heap ? 0 : heap_min;
    c->r[7] = heap_max;
    c->r[8] = euser_export(EUSER_CHUNKHEAP);
    c->r[9] = euser_export(EUSER_SWITCHHEAP);
    c->r[10] = euser_export(EUSER_STARTTHREAD);
    c->r[13] = t->stack_base + stack;
    c->pc = (u32)thread_tramp;
    c->cpsr = 0x10;
    t->prio_rel = 0;
    t->state = T_READY;
    t->suspend_count = 1;              /* runs when resumed */
    thread_reprioritise(t);
    p->nthreads++;
    if (first) p->main = t;
    return t;
}

/* The data window's numbers (IO_WIN_ID), 1-63: a process with a window has
 * one while it lives, and the caches tell its window's lines apart by it. */
static u64 winids = 1;                  /* bit 0: none */
int winid_alloc(void)
{
    for (int i = 1; i < 64; i++)
        if (!(winids >> i & 1)) { winids |= (u64)1 << i; return i; }
    kpanic("no data window number left");
}
void winid_free(int id) { winids &= ~((u64)1 << id); }

/* Initialised data and bss: in the kernel section for fixed processes (they
 * were linked there), else in pages of the data window. */
static void proc_load_data(struct process *p, u32 src)
{
    u32 total = p->data_size + p->bss_size;
    if (!total) return;
    u32 b = p->data_base;
    if (b - NGVM_KSEC_BASE < NGVM_KSEC_SIZE) {
        if (b + total > NGVM_KSEC_BASE + NGVM_KSEC_SIZE) kpanic("data of %p overruns the kernel section", b);
        memcpy((void *)b, (const void *)src, p->data_size);
        memset((void *)(b + p->data_size), 0, p->bss_size);
        return;
    }
    if (b - NGVM_DATA_BASE >= NGVM_DATA_SIZE) kpanic("process data at %p: not a data address", b);
    u32 end = b + total - NGVM_DATA_BASE;
    int n = (end + NGVM_PAGE_SIZE - 1) >> NGVM_PAGE_SHIFT;
    if (n > 64) kpanic("process data of %u bytes: window too small", total);
    for (int i = 0; i < n; i++) {
        int pg = pg_alloc();
        if (pg < 0) kpanic("no memory for process data");
        p->win[i] = (u16)pg;
    }
    p->win_pages = n;
    p->winid = winid_alloc();
    /* fill through the RAM alias, so the window need not be mapped */
    for (u32 off = 0; off < p->data_size; off++) {
        u32 va = b - NGVM_DATA_BASE + off;
        *(u8 *)(NGVM_PHYS_BASE + ((u32)p->win[va >> NGVM_PAGE_SHIFT] << NGVM_PAGE_SHIFT) + (va & (NGVM_PAGE_SIZE - 1))) =
            *(const u8 *)(src + off);
    }
}

struct process *proc_new(const u16 *path, int pathlen)
{
    struct process *p = (struct process *)obj_new(O_PROCESS, sizeof(struct process), 0);
    p->id = next_id++;
    p->exit_type = 3;
    p->o.global = 1;
    if (pathlen > NAME_MAX) pathlen = NAME_MAX;
    memcpy(p->fname, path, pathlen * 2);
    p->fnamelen = pathlen;
    name_from_path(&p->o, path, pathlen);
    return p;
}

void proc_setup_from_rom(struct process *p, const struct rom_image *img)
{
    p->rom = img;
    p->uid[0] = img->uid1; p->uid[1] = img->uid2; p->uid[2] = img->uid3;
    p->entry = img->entry;
    p->heap_min = img->heap_min;
    p->heap_max = img->heap_max;
    p->stack_size = img->stack_size;
    p->code_base = img->code_addr;
    p->code_size = img->code_size;
    p->text_size = img->text_size;
    p->data_base = img->data_bss_base;
    p->data_size = img->data_size;
    p->bss_size = img->bss_size;
    p->prio = img->priority;
    p->dllref = img->dll_ref_table;
    proc_load_data(p, img->data_addr);
    p->loaded = 1;
    thread_create(p, p->entry, 0, p->stack_size, 0, p->heap_min, p->heap_max, 1);
    obj_set_name_a(&p->main->o, "Main");
}

struct process *proc_from_rom(const struct rom_image *img, const char *fname)
{
    u16 path[NAME_MAX];
    int n = 0;
    while (fname[n] && n < NAME_MAX) { path[n] = (u8)fname[n]; n++; }
    struct process *p = proc_new(path, n);
    proc_setup_from_rom(p, img);
    return p;
}

/* ---- the static call list -------------------------------------------------
 * A ROM image's TDllRefTable is {u16 flags, u16 count} then count pairs of
 * (entry point, that DLL's own table).  Dependencies come before the DLLs
 * that need them; each DLL once. */
static int call_list_walk(u32 table, u32 *list, int n, int max)
{
    if (!table) return n;
    int cnt = uread32(table) >> 16;
    for (int i = 0; i < cnt; i++) {
        u32 entry = uread32(table + 4 + 8 * i);
        u32 sub = uread32(table + 8 + 8 * i);
        int seen = 0;
        for (int j = 0; j < n; j++) if (list[j] == entry) { seen = 1; break; }
        if (seen) continue;
        if (n >= max) return n;
        list[n++] = entry;                    /* claim it, so cycles end    */
        int at = n - 1;
        n = call_list_walk(sub, list, n, max);
        /* move it after its dependencies */
        for (int j = at; j < n - 1; j++) list[j] = list[j + 1];
        list[n - 1] = entry;
    }
    return n;
}

/* A library the loader linked: its own dependencies first (a ROM DLL's
 * table, or what the loader added to a RAM DLL), then it. */
static int lib_walk(struct library *l, u32 *list, int n, int max)
{
    for (int j = 0; j < n; j++) if (list[j] == l->entry) return n;
    if (n >= max) return n;
    list[n++] = l->entry;                     /* claimed, as in call_list_walk */
    int at = n - 1;
    if (l->rom) n = call_list_walk(l->dllref, list, n, max);
    else for (int i = 0; i < l->ndeps; i++) if (l->deps[i]->entry) n = lib_walk(l->deps[i], list, n, max);
    for (int j = at; j < n - 1; j++) list[j] = list[j + 1];
    list[n - 1] = l->entry;
    return n;
}

/* A ROM process's list comes from its TDllRefTable; a RAM process has none,
 * and its imports are what the loader added (exec 0x4B), each with its own. */
u32 proc_static_calls(struct process *p, u32 *list, int max)
{
    int n = call_list_walk(p->dllref, list, 0, max);
    for (int i = 0; i < p->nram_deps; i++)
        if (p->ram_deps[i]->entry) n = lib_walk(p->ram_deps[i], list, n, max);
    return n;
}

/* ---- libraries ----------------------------------------------------------- */
struct library *lib_for_rom(const struct rom_image *img)
{
    for (struct kobj *o = obj_first(O_LIBRARY); o; o = o->next)
        if (((struct library *)o)->rom == img) return (struct library *)o;
    struct library *l = (struct library *)obj_new(O_LIBRARY, sizeof(struct library), 0);
    l->rom = img;
    l->uid[0] = img->uid1; l->uid[1] = img->uid2; l->uid[2] = img->uid3;
    l->code_base = img->code_addr;
    l->code_size = img->code_size;
    l->text_size = img->text_size;
    l->entry = img->entry;
    l->export_dir = img->export_dir;
    l->export_count = img->export_count;
    l->dllref = img->dll_ref_table;
    l->loaded = 1;
    obj_ref(&l->o);                           /* ROM code never goes away  */
    return l;
}

void lib_add_dep(struct library *l, struct library *dep)
{
    for (int i = 0; i < l->ndeps; i++) if (l->deps[i] == dep) return;
    if (l->ndeps < MAX_LDEPS) l->deps[l->ndeps++] = dep;
}

void proc_add_dep(struct process *p, struct library *dep)
{
    for (int i = 0; i < p->nram_deps; i++) if (p->ram_deps[i] == dep) return;
    if (p->nram_deps < MAX_PDEPS) p->ram_deps[p->nram_deps++] = dep;
}

/* Which ROM image's code holds addr (for UserSvr::DllFileName and traces)? */
const struct rom_entry *rom_entry_for_code(u32 addr);
