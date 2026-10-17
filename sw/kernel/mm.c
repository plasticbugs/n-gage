/* Memory: RAM pages, chunk-space addresses, and the page table that joins
 * them.  One address space for everything, so the kernel reaches user
 * memory at the user's own addresses (bar another process's data window). */
#include "kern.h"
#include "mm.h"

#define NPAGES      (NGVM_RAM_SIZE >> NGVM_PAGE_SHIFT)
#define KPAGES      (NGVM_KERN_SIZE >> NGVM_PAGE_SHIFT)

static u32 page_used[NPAGES / 32];
static u16 pt[NGVM_PT_ENTRIES];
static u32 free_pages;

/* chunk-space reservations: a sorted list of [base, base+size) in use */
#define MAXRES 512
static struct { u32 base, size; } res[MAXRES];
static int nres;

void mm_init(void)
{
    for (int i = 0; i < NGVM_PT_ENTRIES; i++) pt[i] = NGVM_PT_NONE;
    for (int i = 0; i < KPAGES; i++) page_used[i / 32] |= 1u << (i % 32);
    free_pages = NPAGES - KPAGES;
}

u32 mm_free_bytes(void) { return free_pages << NGVM_PAGE_SHIFT; }

int pg_alloc(void)
{
    static int hint = KPAGES;
    for (int n = 0; n < NPAGES; n++) {
        int i = hint + n; if (i >= NPAGES) i -= NPAGES - KPAGES;
        if (!(page_used[i / 32] & (1u << (i % 32)))) {
            page_used[i / 32] |= 1u << (i % 32);
            free_pages--;
            hint = i + 1 < NPAGES ? i + 1 : KPAGES;
            memset((void *)(NGVM_PHYS_BASE + ((u32)i << NGVM_PAGE_SHIFT)), 0, NGVM_PAGE_SIZE);
            return i;
        }
    }
    return -1;
}

void pg_free(int p)
{
    if (p < KPAGES || p >= NPAGES) kpanic("pg_free %d", p);
    page_used[p / 32] &= ~(1u << (p % 32));
    free_pages++;
}

static int pt_index(u32 va)
{
    if (va - NGVM_CHUNK_BASE < NGVM_CHUNK_SIZE) return (va - NGVM_CHUNK_BASE) >> NGVM_PAGE_SHIFT;
    if (va - NGVM_DATA_BASE < NGVM_DATA_SIZE) return NGVM_PT_CHUNK + ((va - NGVM_DATA_BASE) >> NGVM_PAGE_SHIFT);
    return -1;
}

void pt_set(int i, u32 page)
{
    pt[i] = (u16)page;
    IO(IO_PT_INDEX) = (u32)i;
    IO(IO_PT_DATA) = page;
}

u32 pt_get_va(u32 va)
{
    int i = pt_index(va);
    return i < 0 ? NGVM_PT_NONE : pt[i];
}

int vm_mapped(u32 va) { return pt_get_va(va) != NGVM_PT_NONE; }

/* ---- reservations in chunk space ------------------------------------------ */
u32 vm_reserve(u32 size)
{
    size = (size + NGVM_PAGE_SIZE - 1) & ~(NGVM_PAGE_SIZE - 1);
    if (!size) size = NGVM_PAGE_SIZE;
    /* first fit, leaving one unmapped page between reservations so that an
     * overrun faults instead of landing in a neighbour */
    u32 base = NGVM_CHUNK_BASE + NGVM_PAGE_SIZE;
    int at = 0;
    for (; at < nres; at++) {
        if (base + size + NGVM_PAGE_SIZE <= res[at].base) break;
        base = res[at].base + res[at].size + NGVM_PAGE_SIZE;
    }
    if (base + size > NGVM_CHUNK_BASE + NGVM_CHUNK_SIZE || nres == MAXRES) return 0;
    for (int j = nres; j > at; j--) res[j] = res[j - 1];
    res[at].base = base; res[at].size = size; nres++;
    return base;
}

void vm_release(u32 base)
{
    for (int i = 0; i < nres; i++) if (res[i].base == base) {
        vm_decommit(base, res[i].size);
        for (int j = i; j < nres - 1; j++) res[j] = res[j + 1];
        nres--;
        return;
    }
    kpanic("vm_release %p: not reserved", base);
}

int vm_commit(u32 va, u32 size)
{
    u32 end = va + size;
    for (u32 a = va & ~(NGVM_PAGE_SIZE - 1); a < end; a += NGVM_PAGE_SIZE) {
        int i = pt_index(a);
        if (i < 0) kpanic("vm_commit %p outside paged space", a);
        if (pt[i] != NGVM_PT_NONE) continue;
        int p = pg_alloc();
        if (p < 0) return -1;
        pt_set(i, (u32)p);
    }
    return 0;
}

void vm_decommit(u32 va, u32 size)
{
    u32 end = va + size;
    for (u32 a = va & ~(NGVM_PAGE_SIZE - 1); a < end; a += NGVM_PAGE_SIZE) {
        int i = pt_index(a);
        if (i < 0 || pt[i] == NGVM_PT_NONE) continue;
        pg_free(pt[i]);
        pt_set(i, NGVM_PT_NONE);
    }
    IO(IO_CACHE_FLUSH) = 1;
}
