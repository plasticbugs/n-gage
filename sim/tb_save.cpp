// The save readout on its own (target/pocket/ngage_save.sv): the Pocket
// reading the save slot back over the bridge, a word a transaction as
// io_bridge_peripheral.sv does, against a memory port that answers late
// and an LCD that wants the same port.
//
//   obj_save/Vngage_save [-gap MIN MAX] [-lat MAX]   (sim/run_save.sh builds and runs it)
//
// The bridge: a read's address, its answer sampled 4 clk_74a later (the
// answer to the read before), bridge_rd a clock after that, then a gap of
// MIN-MAX clocks (30-100) to the next address.  Each sample is checked
// against the word the memory held, as the file's bytes, little-endian.
// The memory: a burst granted when l_req is up, its first halfword 4 to
// MAX clocks later (250, and 1 in 64 bursts up to 4 x MAX), a halfword a
// clock, l_done a clock after the last, as ngage_mem gives them.  The LCD:
// bursts of 1-32 halfwords from outside the save, checked word by word.
//
// The readouts, 1 MB each:
//   1  after a load (dl_active) into a save that already held other words
//   2  straight after 1, with no gap
//   3  paused for 4 ms at word 100,000, while C: is written at words 5,
//      100,001-100,100 and 200,000
//   4  with C: written at words 10 and 250,000 while it streams past
//      word 50,000; the words not yet read come out new
//   5  stopped at word 5,000, and 6 from word 0 again
//   7  big-endian
//   8  with the memory four times slower
// 5-8 1 ms after the last, as the Pocket's writes are seconds apart: the
// buffers are fetched again after a write once no read has come for 21 us.
// A wrong word is one the bridge sampled before the readout had it.
#include "Vngage_save.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static const int WORDS = 262144;
static const uint32_t BASE = 0x0F80000;              // halfwords
static const uint64_t HALF_C = 5208, HALF_A = 6734;  // ps: 96 MHz, 74.25 MHz

static Vngage_save *d;
static uint64_t now = 0, tc = 0, ta = 0, clk_n = 0;
static std::vector<uint16_t> mem(2 * WORDS);
static uint32_t rng = 12345;
static uint32_t rnd(uint32_t n) { rng = rng * 1103515245u + 12345u; return (rng >> 8) % n; }
static uint16_t other(uint32_t a) { uint32_t x = a * 2654435761u; return (uint16_t)(x >> 13); }
static uint16_t at(uint32_t a) { return a - BASE < 2u * WORDS ? mem[a - BASE] : other(a); }
static uint32_t word(uint32_t n) { return mem[2 * n] | (uint32_t)mem[2 * n + 1] << 16; }

// the memory port
static int lat_max = 250;
static int m_state = 0, m_wait = 0, m_i = 0, m_len = 0;
static uint32_t m_addr = 0;
static long m_bursts = 0, m_proto = 0;
// the LCD
static int lc_state = 0, lc_wait = 0, lc_len = 0, lc_got = 0;
static uint32_t lc_addr = 0;
static long lc_bursts = 0, lc_bad = 0;
// the bridge
static int gmin = 30, gmax = 100;

static void clk_cycle() {
    // sample what the cycle shows, as registers would at the edge
    bool l_req = d->l_req;
    uint32_t l_addr = d->l_addr;
    int l_len = d->l_len;
    bool a_wr = d->a_wr, a_done = d->a_done;
    int a_idx = d->a_idx;
    uint16_t a_data = d->a_data;

    // the memory: next cycle's l_wr, l_idx, l_data, l_done
    int n_wr = 0, n_idx = 0, n_done = 0;
    uint16_t n_data = 0;
    if (m_state == 0) {
        if (l_req && !d->l_done) {
            m_addr = l_addr; m_len = l_len; m_i = 0; m_state = 1; m_bursts++;
            m_wait = 4 + rnd(lat_max);
            if (rnd(64) == 0) m_wait = 4 + rnd(4 * lat_max);
        }
    } else {
        if (!l_req || l_addr != m_addr || l_len != m_len) m_proto++;
        if (m_state == 1) { if (--m_wait <= 0) m_state = 2; }
        if (m_state == 2) {
            if (m_i < m_len) { n_wr = 1; n_idx = m_i; n_data = at(m_addr + m_i); m_i++; }
            else { n_done = 1; m_state = 3; }
        } else if (m_state == 3) m_state = 0;
    }

    // the LCD: next cycle's a_req
    if (a_wr) {
        if (lc_state != 1 || a_idx >= lc_len || a_data != other(lc_addr + a_idx)) {
            if (lc_bad++ < 6) printf("  LCD: halfword %d of %d at %07x: %04x, want %04x\n",
                                     a_idx, lc_len, lc_addr, a_data, other(lc_addr + a_idx));
        } else lc_got++;
    }
    if (a_done) {
        if (lc_state != 1 || lc_got != lc_len) {
            if (lc_bad++ < 6) printf("  LCD: done with %d of %d\n", lc_got, lc_len);
        }
        lc_state = 0; lc_wait = rnd(400); lc_bursts++;
    } else if (lc_state == 0 && --lc_wait <= 0) {
        lc_state = 1; lc_len = 1 + rnd(32); lc_got = 0;
        lc_addr = 0x0100000 + rnd(0x100000);
    }

    d->clk = 1; d->eval();
    d->l_wr = n_wr; d->l_idx = n_idx; d->l_data = n_data; d->l_done = n_done;
    d->a_req = lc_state == 1;
    d->a_addr = lc_addr; d->a_len = lc_len & 63;
    d->eval();
    clk_n++;
}

// one clk_74a cycle: the bridge's next inputs are set after the edge
static int b_rd = 0;
static uint32_t b_addr = 0;
static void a_cycle() {
    d->clk_74a = 1; d->eval();
    d->bridge_rd = b_rd; d->bridge_addr = b_addr;
    d->eval();
}

// run time forward until clk_74a's next rising edge has been taken
static void step_a() {
    for (;;) {
        if (tc <= ta) {
            now = tc; tc += HALF_C;
            if (!d->clk) clk_cycle(); else { d->clk = 0; d->eval(); }
        } else {
            now = ta; ta += HALF_A;
            if (!d->clk_74a) { a_cycle(); return; }
            d->clk_74a = 0; d->eval();
        }
    }
}
static void wait_a(long n) { while (n-- > 0) step_a(); }

// the save as the Pocket's file would hold it, set in memory
static void set_word(uint32_t n, uint32_t v) { mem[2 * n] = v & 0xFFFF; mem[2 * n + 1] = v >> 16; }
static void dirty() { d->save_t = !d->save_t; }

typedef void (*hook_t)(int n);
static long bad_total = 0;

// one readout from word 0 to `upto` (the whole save and one read more, as
// the bridge's answers come one read late)
static long readout(const char *name, bool little, int upto, hook_t hook) {
    long bad = 0;
    uint64_t c0 = clk_n;
    d->bridge_endian_little = little;
    uint32_t prev = 0;
    for (int n = 0; n <= upto; n++) {
        if (hook) hook(n);
        b_addr = 0x20000000u + 4u * (uint32_t)n;
        wait_a(4);
        uint32_t got = d->bridge_rd_data;
        if (n > 0) {
            uint32_t w = word(n - 1);
            uint32_t want = little ? w : __builtin_bswap32(w);
            (void)prev;
            if (got != want && bad++ < 6)
                printf("  %s: word %d got %08x want %08x\n", name, n - 1, got, want);
        }
        b_rd = 1; wait_a(1); b_rd = 0;
        wait_a(gmin + rnd(gmax - gmin + 1));
    }
    printf("%-34s %6d words, %ld wrong, %.1f ms\n", name, upto, bad, (clk_n - c0) / 96000.0);
    bad_total += bad;
    return bad;
}

static void pause_hook(int n) {
    if (n != 100000) return;
    wait_a(150000);                         // 2 ms
    set_word(5, 0xA5A50005); for (int i = 100001; i <= 100100; i++) set_word(i, 0xC0DE0000u + i);
    set_word(200000, 0x5EEDBEEF); dirty();
    wait_a(150000);
}
static void stream_hook(int n) {
    if (n != 50000) return;
    set_word(10, 0x0B0B0010); set_word(250000, 0xFACE0250); dirty();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-gap") && i + 2 < argc) { gmin = atoi(argv[i + 1]); gmax = atoi(argv[i + 2]); i += 2; }
        else if (!strcmp(argv[i], "-lat") && i + 1 < argc) lat_max = atoi(argv[++i]);
    }
    d = new Vngage_save;
    d->clk = 0; d->clk_74a = 0; d->rst = 1; d->dl_active = 0; d->save_t = 0;
    d->bridge_rd = 0; d->bridge_addr = 0; d->bridge_endian_little = 1;
    d->a_req = 0; d->l_wr = 0; d->l_done = 0;
    d->eval();
    // before the load: memory as the last run left it
    for (int i = 0; i < 2 * WORDS; i++) mem[i] = other(BASE + i) ^ 0x5555;
    wait_a(20);
    d->rst = 0;
    wait_a(2000);
    // the load: the slot's words arrive while dl_active is up
    d->dl_active = 1;
    wait_a(500);
    for (int i = 0; i < 2 * WORDS; i++) mem[i] = (uint16_t)(rnd(65536));
    wait_a(500);
    d->dl_active = 0;
    wait_a(20000);

    readout("1 after the load", true, WORDS, nullptr);
    readout("2 straight after", true, WORDS, nullptr);
    readout("3 paused, C: written meanwhile", true, WORDS, pause_hook);
    readout("4 C: written while it streams", true, WORDS, stream_hook);
    wait_a(74250);
    readout("5 stopped at word 5000", true, 5000, nullptr);
    wait_a(74250);
    readout("6 from word 0 again", true, WORDS, nullptr);
    wait_a(74250);
    readout("7 big-endian", false, WORDS, nullptr);
    wait_a(74250);
    lat_max *= 4;
    readout("8 the memory four times slower", true, WORDS, nullptr);

    printf("memory: %ld bursts, %ld protocol errors; LCD: %ld bursts, %ld wrong\n",
           m_bursts, m_proto, lc_bursts, lc_bad);
    bool ok = bad_total == 0 && m_proto == 0 && lc_bad == 0 && lc_bursts > 1000;
    printf("%s\n", ok ? "save readout: PASS" : "save readout: FAIL");
    delete d;
    return ok ? 0 : 1;
}
