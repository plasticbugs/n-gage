/* A cache model for traces from ngvm.py --memtrace: how often the core's
 * caches would miss on what the games actually run.
 *
 *   cc -O2 -o build/cachesim tools/ngvm/cachesim.c
 *   build/cachesim TRACE [ISIZE DSIZE LINE IWAYS DWAYS]...
 *
 * Each group of five numbers is one configuration (bytes, bytes, bytes,
 * ways, ways).  Virtually tagged, LRU, write-back and write-allocate for
 * data; addresses at NGVM_IO_BASE and above are uncached.  The trace keeps
 * the I and D streams apart, so their interleaving (and SDRAM contention
 * between them) is not modelled -- only miss and write-back counts.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

struct cache {
    uint32_t sets, ways, lshift;
    uint32_t *tag;      /* sets * ways; 0 = invalid, else line address | 1 */
    uint8_t  *dirty;
    uint32_t *age;      /* LRU stamp */
    uint32_t now;
    uint64_t acc, miss, wb;
};

static int lg2(uint32_t x) { int n = 0; while ((1u << n) < x) n++; return n; }

static void cinit(struct cache *c, uint32_t size, uint32_t line, uint32_t ways)
{
    memset(c, 0, sizeof *c);
    c->lshift = lg2(line);
    c->ways = ways;
    c->sets = size / line / ways;
    c->tag = calloc(c->sets * ways, 4);
    c->dirty = calloc(c->sets * ways, 1);
    c->age = calloc(c->sets * ways, 4);
}

static void caccess(struct cache *c, uint32_t a, int write)
{
    if (a >= 0xF0000000u) return;
    uint32_t la = a >> c->lshift, set = la % c->sets, t = (la << 1) | 1, *tg = c->tag + set * c->ways;
    c->acc++;
    c->now++;
    for (uint32_t w = 0; w < c->ways; w++)
        if (tg[w] == t) {
            c->age[set * c->ways + w] = c->now;
            if (write) c->dirty[set * c->ways + w] = 1;
            return;
        }
    c->miss++;
    uint32_t v = 0;
    for (uint32_t w = 1; w < c->ways; w++)
        if (c->age[set * c->ways + w] < c->age[set * c->ways + v]) v = w;
    uint32_t i = set * c->ways + v;
    if (tg[v] && c->dirty[i]) c->wb++;
    tg[v] = t;
    c->dirty[i] = (uint8_t)write;
    c->age[i] = c->now;
}

int main(int argc, char **argv)
{
    if (argc < 2 || (argc - 2) % 5) {
        fprintf(stderr, "usage: %s TRACE [ISIZE DSIZE LINE IWAYS DWAYS]...\n", argv[0]);
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    char hdr[256];
    unsigned long long insns, nb, nd;
    if (!fgets(hdr, sizeof hdr, f) || sscanf(hdr, "NGVMTRACE insns=%llu blocks=%llu data=%llu", &insns, &nb, &nd) != 3) {
        fprintf(stderr, "%s: not a memtrace\n", argv[1]);
        return 1;
    }
    uint32_t *blk = malloc(nb * 8), *dat = malloc(nd * 4);
    if (fread(blk, 8, nb, f) != nb || fread(dat, 4, nd, f) != nd) { fprintf(stderr, "short trace\n"); return 1; }
    printf("%llu instructions, %llu blocks, %llu data accesses (%.2f a instruction)\n",
           insns, nb, nd, (double)nd / insns);
    printf("%7s %7s %5s %5s | %9s %9s %9s | per 1000 instructions\n", "I", "D", "line", "ways", "I miss%", "D miss%", "D wb%");
    for (int k = 2; k < argc; k += 5) {
        uint32_t is = atoi(argv[k]), ds = atoi(argv[k + 1]), ln = atoi(argv[k + 2]);
        uint32_t iw = atoi(argv[k + 3]), dw = atoi(argv[k + 4]);
        struct cache ic, dc;
        cinit(&ic, is, ln, iw);
        cinit(&dc, ds, ln, dw);
        /* fetches: one access per line a block touches, then the hits within
         * a line are free, as they are for a fetch unit that reads a line
         * once; but count instruction words for the rate */
        uint64_t fetch_lines = 0;
        for (uint64_t b = 0; b < nb; b++) {
            uint32_t a = blk[2 * b], n = blk[2 * b + 1];
            if (!n) n = 2;
            for (uint32_t l = a >> ic.lshift; l <= (a + n - 1) >> ic.lshift; l++) {
                caccess(&ic, l << ic.lshift, 0);
                fetch_lines++;
            }
        }
        for (uint64_t d = 0; d < nd; d++) caccess(&dc, dat[d] & ~1u, dat[d] & 1);
        printf("%7u %7u %5u %2u/%-2u | %8.2f%% %8.2f%% %8.2f%% | I %.2f  D %.2f  wb %.2f\n",
               is, ds, ln, iw, dw,
               100.0 * ic.miss / ic.acc, 100.0 * dc.miss / dc.acc, 100.0 * dc.wb / dc.acc,
               1000.0 * ic.miss / insns, 1000.0 * dc.miss / insns, 1000.0 * dc.wb / insns);
        (void)fetch_lines;
    }
    return 0;
}
