// Pocket memory gate: push an image through ngage_mem's download port at the
// APF loader's rate, then read every byte back through NGVM's bus port and
// compare.  Then masked line writes to both memories, read back, and fills
// that write a line back behind them (BC_RDWR), read back.  All the while an
// LCD agent fetches lines through the burst port the bus shares, and checks
// every halfword it gets.  Then the SRAM.
//
// An SDRAM line read starts at a random word, and each word is checked at
// the clock m_cnt counts it, as well as at m_done: the CPU side uses a word
// as soon as the count says it is in (ngvm_xbus.sv).
//
//   obj_mem/Vtb_mem_top [-gap N] [-hold N] [-quick] [-halfrd] [-slow] [-late]
//
// The image is pseudo-random, which is a harder test than a real one (no runs
// of equal words to hide a dropped or merged write) and needs nothing the
// repo may not hold.  It goes to the kernel's, the ROM's and the drive's bus
// addresses as the three slots do, the drive in pieces that cross each of
// CRAM's half and chip boundaries, and the ROM and the last drive piece
// with an odd length, so an even byte is left alone at the end.
//
// -gap   clocks between download bytes.  The loader delivers one per 7 at its
//        fastest (core_top's DIO_DELAY); smaller is harder.  A core that
//        passes at 12 and fails at 8 has the fault that blacked out two first
//        hardware runs.  The CRAM takes a halfword in 10 clocks, so below 5
//        its queue grows without end and this fails, as it should.
// -hold  clocks the write strobe is held high.  The Pocket holds it for 4 with
//        address and data stable; anything that counts, sums or pushes on the
//        strobe's level rather than its edge fails here (METHODOLOGY 5.8).
// -quick reads back every 61st line rather than every one.
//
// The SDRAM is read as the Pocket's menu reads it when left alone: a burst
// READ every clock, each word caught three clocks after its READ.
// -halfrd sets the menu's "SDRAM half-rate reads": a burst READ every 2 clocks.
// -slow   sets its "SDRAM slow bursts": a burst READ every 5 clocks.
// -late   sets its "SDRAM read late": each word caught at READ+4.  With a
//         READ every clock this must fail, as it did on the Pocket.
//
// The bus layout must match target/pocket/ngage_mem.sv.
#include "Vtb_mem_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

static Vtb_mem_top *dut;
static const uint32_t BUS_ROM = 0x2000000, BUS_DRIVE = 0x4000000;
static const int BC_RDLINE = 0, BC_WRLINE = 1, BC_RDWORD = 2, BC_RDWR = 3;

static std::unordered_map<uint32_t, uint8_t> mem;      // every byte the bench knows
static uint32_t rng = 0x2545F491;
static uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static long bad = 0, checked = 0;
static void fail(const char *what, uint32_t a, unsigned got, unsigned want)
{
    if (bad < 16) printf("  %-6s [%07X] got %04X want %04X\n", what, a, got, want);
    bad++;
}
static bool known(uint32_t a) { return mem.count(a) != 0; }

// ---- the LCD agent: fetches of 1-32 halfwords from the kernel's region,
// which nothing writes after the download, checking each halfword as it comes
static bool lcd_on = false, l_req = false;
static uint32_t l_hw;
static int l_len, l_got, l_gap;
static long l_fetches = 0, l_words = 0;
static uint32_t lcd_lo, lcd_hi;                         // bytes [lo, hi)
static void lcd_edge()
{
    if (l_req && dut->l_wr) {
        uint32_t a = (l_hw + dut->l_idx) * 2;
        unsigned want = mem[a] | mem[a + 1] << 8;
        checked++; l_words++; l_got++;
        if (dut->l_data != want) fail("lcd", a, dut->l_data, want);
    }
    if (l_req && dut->l_done) {
        if (l_got != l_len) fail("lcd n", l_hw * 2, l_got, l_len);
        l_req = false; l_fetches++; l_gap = 1 + rnd() % 40;
    } else if (!l_req && lcd_on && l_gap-- <= 0) {
        l_len = 1 + rnd() % 32;
        l_hw = (lcd_lo + rnd() % (lcd_hi - lcd_lo - 64)) / 2;
        l_got = 0; l_req = true;
    }
    dut->l_req = l_req; dut->l_addr = l_hw; dut->l_len = l_len;
}

static void tick()
{
    dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval();
    lcd_edge();
}

// one bus request, held until m_done, taken only while m_free (as
// ngvm_xbus.sv takes one).  A line read's words, each as m_cnt counts it,
// go to snap[] in the order they come; narr says how many came.
static uint32_t snap[8];
static int narr;
static unsigned gray2bin(unsigned g) { g ^= g >> 2; g ^= g >> 1; return g & 15; }
static void bus(int cmd, uint32_t addr, uint32_t be = 0, const uint8_t *wd = nullptr, uint32_t waddr = 0)
{
    // the bus's contract (ngvm_sys.sv): line reads at word addresses, line
    // writes at line ones, words at word ones
    bool rd_line = cmd == BC_RDLINE || cmd == BC_RDWR;
    if (addr & (cmd == BC_WRLINE ? 31 : 3)) { printf("BENCH ERROR  command %d at %07X\n", cmd, addr); exit(2); }
    int g = 0;
    while (!dut->m_free && ++g < 20000) tick();
    if (!dut->m_free) { printf("FAIL  m_free never rose before command %d at %07X\n", cmd, addr); exit(1); }
    dut->m_cmd = cmd; dut->m_addr = addr; dut->m_waddr = waddr >> 5; dut->m_be = be;
    for (int w = 0; w < 8; w++) {
        uint32_t x = 0;
        if (wd) for (int k = 0; k < 4; k++) x |= uint32_t(wd[4 * w + k]) << 8 * k;
        dut->m_wdata[w] = x;
    }
    dut->m_req = 1;
    narr = 0;
    unsigned c = gray2bin(dut->m_cnt);
    g = 0;
    do {
        tick();
        for (unsigned now = gray2bin(dut->m_cnt); c != now; c = (c + 1) & 15) {
            if (!rd_line || narr == 8) { printf("FAIL  m_cnt moved past a %d-word answer\n", rd_line ? 8 : 0); exit(1); }
            int w = (addr >> 2) + narr & 7;
            snap[w] = dut->m_rdata[w];
            narr++;
        }
    } while (!dut->m_done && ++g < 20000);
    if (!dut->m_done) { printf("FAIL  no m_done for command %d at %07X\n", cmd, addr); exit(1); }
    dut->m_req = 0;
    tick();
}
static uint8_t rbyte(int i) { return dut->m_rdata[i / 4] >> 8 * (i % 4); }

// compare the answer to a line read at a (or a word) with the bytes the
// bench knows; an SDRAM line's words as they were counted in, too
static void compare(int cmd, uint32_t a, const char *what)
{
    int n = cmd == BC_RDWORD ? 4 : 32;
    if (n == 32) a &= ~31u;
    bool sd = n == 32 && a < BUS_DRIVE;
    if (sd && narr != 8) { fail("count", a, narr, 8); return; }
    for (int i = 0; i < n; i += 2) {
        if (!known(a + i) && !known(a + i + 1)) continue;
        unsigned got = rbyte(i) | rbyte(i + 1) << 8, want = 0, mask = 0;
        if (known(a + i)) { want |= mem[a + i]; mask |= 0x00FF; }
        if (known(a + i + 1)) { want |= mem[a + i + 1] << 8; mask |= 0xFF00; }
        checked++;
        if ((got & mask) != want) fail(what, a + i, got & mask, want);
        if (sd) {
            unsigned early = (snap[i / 4] >> 8 * (i % 4)) & 0xFFFF;
            if ((early & mask) != want) fail("early", a + i, early & mask, want);
        }
    }
}
// read a line (from a random first word) or a word back, and compare
static void check(int cmd, uint32_t a, const char *what)
{
    uint32_t ra = cmd == BC_RDLINE ? a + 4 * (rnd() % 8) : a;
    bus(cmd, ra);
    compare(cmd, ra, what);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    int gap = 7, hold = 4; bool quick = false, fastrd = true, slow = false, late = false;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-gap" && i + 1 < argc) gap = atoi(argv[++i]);
        else if (a == "-hold" && i + 1 < argc) hold = atoi(argv[++i]);
        else if (a == "-quick") quick = true;
        else if (a == "-halfrd") fastrd = false;
        else if (a == "-slow") slow = true;
        else if (a == "-late") late = true;
        else if (a[0] != '+') { fprintf(stderr, "unknown argument %s\n", a.c_str()); return 2; }
    }
    if (hold >= gap) hold = gap - 1;
    if (hold < 1) hold = 1;

    dut = new Vtb_mem_top;
    dut->init = 1; dut->rd_late = late; dut->burst_slow = slow; dut->rd_fast = fastrd;
    dut->dl_we = 0; dut->dl_active = 0; dut->m_req = 0; dut->l_req = 0; dut->vram_req = 0;
    for (int i = 0; i < 16; i++) tick();
    dut->init = 0;
    long t = 0; while (!dut->ready && t++ < 200000) tick();
    printf("sdram ready after %ld clocks\n", t);
    if (!dut->ready) { printf("FAIL  the controller never came ready\n"); return 1; }

    // ---- the download: each piece a slot of its own, as the loader sends them
    struct Piece { uint32_t base, len; const char *what; };
    const Piece pieces[] = {
        {0x0000000, 0x10000, "kernel"},
        {BUS_ROM,   0x20001, "ROM, odd length"},
        {BUS_DRIVE, 0x4000,  "drive, CRAM0 low half"},
        {BUS_DRIVE + 0x07FF000, 0x2000, "drive, across CRAM0's halves"},
        {BUS_DRIVE + 0x0FFF000, 0x2000, "drive, across the chips"},
        {BUS_DRIVE + 0x17FF000, 0x1801, "drive, across CRAM1's halves, odd length"},
        {BUS_DRIVE + 0x1FFE000, 0x1FFF, "drive, CRAM1's last 8 KB, odd length"},
    };
    uint32_t want_rom = 0, want_drive = 0;
    for (const Piece &p : pieces) {
        printf("downloading %6u bytes to %07X (%s), one per %d clocks, strobe held %d\n",
               p.len, p.base, p.what, gap, hold);
        dut->dl_active = 1;
        for (int i = 0; i < 20; i++) tick();
        for (uint32_t a = p.base; a < p.base + p.len; a++) {
            uint8_t b = rnd() >> 11;
            mem[a] = b;
            dut->dl_addr = a; dut->dl_data = b; dut->dl_we = 1;
            for (int i = 0; i < hold; i++) tick();
            dut->dl_we = 0;
            for (int i = hold; i < gap; i++) tick();
        }
        dut->dl_active = 0;
        for (int i = 0; i < 2000; i++) tick();
        if (p.base >= BUS_DRIVE) want_drive = p.base + p.len - BUS_DRIVE;
        else if (p.base >= BUS_ROM) want_rom = p.base + p.len - BUS_ROM;
    }
    long sbad = 0;
    if (dut->rom_size != want_rom) { printf("  rom_size %u, want %u\n", dut->rom_size, want_rom); sbad++; }
    if (dut->drive_size != want_drive) { printf("  drive_size %u, want %u\n", dut->drive_size, want_drive); sbad++; }
    printf("sizes: ROM %u, drive %u bytes%s\n", dut->rom_size, dut->drive_size, sbad ? " -- WRONG" : "");

    // ---- read it all back, with the LCD fetching alongside
    lcd_lo = 0; lcd_hi = 0x8000; lcd_on = true;
    const uint32_t step = quick ? 61 : 1;               // a prime stride still visits every row
    long lines = 0;
    for (const Piece &p : pieces) {
        uint32_t lo = p.base & ~31u, hi = (p.base + p.len + 31) & ~31u;
        for (uint32_t a = lo; a < hi; a += 32 * step, lines++) {
            check(BC_RDLINE, a, p.base >= BUS_DRIVE ? "cram" : "sdram");
            check(BC_RDWORD, a + 4 * (rnd() % 8), p.base >= BUS_DRIVE ? "cram w" : "sdram w");
        }
    }
    printf("read back: %ld lines and as many words, %ld halfwords checked, %ld wrong\n", lines, checked, bad);

    // ---- masked line writes, read back: random byte masks over lines the
    // bench knows, outside the LCD's region; a mask may leave whole
    // halfwords out, which CRAM skips and SDRAM masks with DQM
    long wbad = bad;
    std::vector<uint32_t> targets;
    for (const Piece &p : pieces)
        for (uint32_t a = (p.base + 31) & ~31u; a + 32 <= p.base + p.len; a += 32)
            if (a >= 0x8000) targets.push_back(a);
    for (int n = 0; n < 2000; n++) {
        uint32_t a = targets[rnd() % targets.size()];
        uint32_t be;
        switch (rnd() % 4) {
        case 0:  be = 0xFFFFFFFF; break;                // a whole line
        case 1:  be = 0xF << 4 * (rnd() % 8); break;    // one word
        case 2:  be = 1u << rnd() % 32; break;          // one byte
        default: be = rnd() | 1; break;                 // anything
        }
        uint8_t wd[32];
        for (int i = 0; i < 32; i++) { wd[i] = rnd() >> 7; if (be >> i & 1) mem[a + i] = wd[i]; }
        bus(BC_WRLINE, a, be, wd);
        long b0 = bad;
        int cmd = rnd() & 1 ? BC_RDLINE : BC_RDWORD;
        uint32_t ra = a + (cmd == BC_RDLINE ? 0 : 4 * (rnd() % 8));
        check(cmd, ra, a >= BUS_DRIVE ? "cram wr" : "sdram wr");
        if (bad > b0 && b0 == wbad)
            printf("  the first wrong: write %d, a line to %07X with mask %08X, read back by %s at %07X\n",
                   n, a, be, cmd == BC_RDLINE ? "a line" : "a word", ra);
    }
    for (uint32_t a : targets) check(BC_RDLINE, a, a >= BUS_DRIVE ? "cram wr" : "sdram wr");
    printf("masked writes: 2000, then %zu lines read back, %ld wrong\n", targets.size(), bad - wbad);

    // ---- fills that write a line back behind them: the read must see the
    // memory before the write-back (or after it, when the two lines are one),
    // and the write-back must have landed before anything that follows
    long fbad = bad;
    std::vector<uint32_t> sdl;
    for (uint32_t a : targets) if (a < BUS_DRIVE) sdl.push_back(a);
    for (int n = 0; n < 2000; n++) {
        uint32_t ra = sdl[rnd() % sdl.size()] + 4 * (rnd() % 8);
        uint32_t wa = rnd() % 16 == 0 ? ra & ~31u : sdl[rnd() % sdl.size()];
        uint8_t wd[32];
        for (int i = 0; i < 32; i++) wd[i] = rnd() >> 7;
        bool same = wa == (ra & ~31u);
        if (same) for (int i = 0; i < 32; i++) mem[wa + i] = wd[i];
        bus(BC_RDWR, ra, 0xFFFFFFFF, wd, wa);
        long b0 = bad;
        compare(BC_RDLINE, ra, "rdwr rd");
        if (!same) for (int i = 0; i < 32; i++) mem[wa + i] = wd[i];
        // straight away: the next request waits for the write-back
        if (rnd() & 1) check(BC_RDLINE, wa, "rdwr wb");
        else check(BC_RDWORD, wa + 4 * (rnd() % 8), "rdwr wbw");
        if (bad > b0 && b0 == fbad)
            printf("  the first wrong: fill %d, %07X, writing back %07X\n", n, ra, wa);
    }
    printf("fills with write-backs: 2000, %ld wrong\n", bad - fbad);
    lcd_on = false;
    for (int i = 0; i < 400; i++) tick();
    printf("LCD agent: %ld fetches, %ld halfwords alongside the bus\n", l_fetches, l_words);

    // ---- SRAM: write a pattern with byte enables, read it back
    long rbad = 0;
    auto vram = [&](bool we, uint32_t a, uint16_t d, int ben) {
        dut->vram_we = we; dut->vram_addr = a; dut->vram_din = d; dut->vram_ben = ben; dut->vram_req = 1;
        int g = 0; while (!dut->vram_ack && g++ < 4000) tick();
        dut->vram_req = 0; tick();
        return (uint16_t)dut->vram_q;
    };
    for (uint32_t a = 0; a < 32768; a += step) vram(true, a, uint16_t(a * 0x9E37 + 0x1234), 3);
    for (uint32_t a = 0; a < 32768; a += step) if (vram(false, a, 0, 3) != uint16_t(a * 0x9E37 + 0x1234)) rbad++;
    vram(true, 5, 0xFFFF, 3); vram(true, 5, 0x00AB, 1);            // low byte only
    if (vram(false, 5, 0, 3) != 0xFFAB) { rbad++; printf("  sram byte enables: got %04X want FFAB\n", dut->vram_q); }
    printf("SRAM:  %ld wrong\n", rbad);

    unsigned errs = dut->errors;
    printf("%u memory protocol errors\n", errs);
    delete dut;
    if (bad || sbad || rbad || errs) { printf("FAIL  what came back is not what was sent\n"); return 1; }
    printf("PASS  every byte reads back, through the bus and the LCD's fetch\n");
    return 0;
}
