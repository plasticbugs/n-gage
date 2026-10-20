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

/* n pages in a row, zeroed, for what the gateware reads by RAM address */
int pg_alloc_run(int n)
{
    for (int i = KPAGES; i + n <= NPAGES; i++) {
        int j = 0;
        while (j < n && !(page_used[(i + j) / 32] & (1u << ((i + j) % 32)))) j++;
        if (j < n) { i += j; continue; }
        for (j = 0; j < n; j++) page_used[(i + j) / 32] |= 1u << ((i + j) % 32);
        free_pages -= n;
        memset((void *)(NGVM_PHYS_BASE + ((u32)i << NGVM_PAGE_SHIFT)), 0, (u32)n << NGVM_PAGE_SHIFT);
        return i;
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
    if (va - NGVM_LOW_BASE < NGVM_LOW_SIZE) return va >> NGVM_PAGE_SHIFT;
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

/* ---- reservations in chunk space ------------------------------------------
 * Three ranges: chunk space below its low name's pages, the low name
 * (NGVM_LOW_BASE, for the game's processes), and chunk space above. */
#define LOW_HIGH (NGVM_CHUNK_BASE + NGVM_LOW_BASE)   /* the low name's pages, by their high name */

static u32 reserve_in(u32 lo, u32 hi, u32 size)
{
    size = (size + NGVM_PAGE_SIZE - 1) & ~(NGVM_PAGE_SIZE - 1);
    if (!size) size = NGVM_PAGE_SIZE;
    /* first fit, leaving one unmapped page between reservations so that an
     * overrun faults instead of landing in a neighbour */
    u32 base = lo + NGVM_PAGE_SIZE;
    int at = 0;
    while (at < nres && res[at].base < lo) at++;
    for (; at < nres; at++) {
        if (base + size + NGVM_PAGE_SIZE <= res[at].base) break;
        base = res[at].base + res[at].size + NGVM_PAGE_SIZE;
    }
    if (base + size > hi || nres == MAXRES) return 0;
    for (int j = nres; j > at; j--) res[j] = res[j - 1];
    res[at].base = base; res[at].size = size; nres++;
    return base;
}

u32 vm_reserve(u32 size)
{
    u32 b = reserve_in(NGVM_CHUNK_BASE, LOW_HIGH, size);
    return b ? b : reserve_in(LOW_HIGH + NGVM_LOW_SIZE, NGVM_CHUNK_BASE + NGVM_CHUNK_SIZE, size);
}

/* low: under the low name if it has room */
u32 vm_reserve_for(int low, u32 size)
{
    u32 b = low ? reserve_in(NGVM_LOW_BASE, NGVM_LOW_BASE + NGVM_LOW_SIZE, size) : 0;
    return b ? b : vm_reserve(size);
}

/* reservations: how many, and how many bytes of chunk space they take */
u32 vm_reserved(int *count)
{
    u32 n = 0;
    for (int i = 0; i < nres; i++) n += res[i].size;
    if (count) *count = nres;
    return n;
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

/* A second mapping of pages that belong to someone else (a process's data,
 * for the loader to fill), and its removal, which frees nothing. */
void vm_alias(u32 va, u32 page)
{
    int i = pt_index(va);
    if (i < 0) kpanic("vm_alias %p outside paged space", va);
    pt_set(i, page);
}

void vm_unalias(u32 base)
{
    for (int i = 0; i < nres; i++) if (res[i].base == base) {
        for (u32 a = base; a < base + res[i].size; a += NGVM_PAGE_SIZE) pt_set(pt_index(a), NGVM_PT_NONE);
        IO(IO_CACHE_FLUSH) = 1;
        for (int j = i; j < nres - 1; j++) res[j] = res[j + 1];
        nres--;
        return;
    }
    kpanic("vm_unalias %p: not reserved", base);
}
