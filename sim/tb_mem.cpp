// Pocket memory gate: push an image through mycore_mem's download port at the
// APF loader's rate, then read every region back through the core's ports
// and compare.  Then the same for the SRAM.
//
//   obj_mem/Vtb_mem_top [rom] [-gap N] [-hold N] [-quick]
//
// With no rom a pseudo-random image is used, which is a harder test than a
// real one (no runs of equal words to hide a dropped or merged write) and
// needs nothing the repo may not hold.
//
// -gap   clocks between download bytes.  The loader delivers one per 8;
//        smaller is harder.  A core that passes at 12 and fails at 8 has the
//        fault that blacked out two first hardware runs.
// -hold  clocks the write strobe is held high.  The Pocket holds it for 4 with
//        address and data stable; anything that counts, sums or pushes on the
//        strobe's level rather than its edge fails here (METHODOLOGY 5.8).
//
// The layout constants must match target/pocket/mycore_mem.sv.
#include "Vtb_mem_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vtb_mem_top *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

static const uint32_t SND_B = 0x080000, GFX_B = 0x090000, IMG = 0x190000;
static const uint32_t PROG_WORDS = SND_B / 2, SND_BYTES = GFX_B - SND_B, GFX_WORDS = (IMG - GFX_B) / 4;

static std::vector<uint8_t> rom;
static uint16_t be16(uint32_t o) { return (uint16_t(rom[o]) << 8) | rom[o + 1]; }
static uint32_t be32(uint32_t o) { return (uint32_t(be16(o)) << 16) | be16(o + 2); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int gap = 8, hold = 4; bool quick = false; std::string path;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-gap" && i + 1 < argc) gap = atoi(argv[++i]);
        else if (a == "-hold" && i + 1 < argc) hold = atoi(argv[++i]);
        else if (a == "-quick") quick = true;
        else if (a[0] != '+' && a[0] != '-') path = a;
    }
    if (hold >= gap) hold = gap - 1;
    if (hold < 1) hold = 1;

    rom.resize(IMG);
    if (!path.empty()) {
        FILE *f = fopen(path.c_str(), "rb");
        if (!f || fread(rom.data(), 1, IMG, f) != IMG) { fprintf(stderr, "cannot read %u bytes from %s\n", IMG, path.c_str()); return 2; }
        fclose(f);
    } else {
        uint32_t x = 0x2545F491;
        for (auto &b : rom) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; b = uint8_t(x >> 11); }
    }

    dut = new Vtb_mem_top;
    dut->init = 1; dut->rd_late = 1; dut->burst_slow = 0;
    dut->dl_we = 0; dut->dl_active = 1;
    dut->mrom_req = dut->srom_req = dut->gfxl_req = dut->gfxs_req = dut->vram_req = 0;
    for (int i = 0; i < 16; i++) tick();
    dut->init = 0;
    long t = 0; while (!dut->ready && t++ < 200000) tick();
    printf("sdram ready after %ld clocks\n", t);
    if (!dut->ready) { printf("FAIL  the controller never came ready\n"); return 1; }

    printf("downloading %u bytes, one per %d clocks, strobe held %d...\n", IMG, gap, hold);
    for (uint32_t a = 0; a < IMG; a++) {
        dut->dl_addr = a; dut->dl_data = rom[a]; dut->dl_we = 1;
        for (int i = 0; i < hold; i++) tick();
        dut->dl_we = 0;
        for (int i = hold; i < gap; i++) tick();
    }
    for (int i = 0; i < 400; i++) tick();
    dut->dl_active = 0;

    long bad = 0, checked = 0;
    auto fail = [&](const char *port, uint32_t idx, uint64_t got, uint64_t want) {
        if (bad < 12) printf("  %-5s [%06X] got %08llX want %08llX\n", port, idx,
                             (unsigned long long)got, (unsigned long long)want);
        bad++;
    };
    const uint32_t step = quick ? 61 : 1;       // a prime stride still visits every row

    for (uint32_t w = 0; w < PROG_WORDS; w += step) {
        dut->mrom_addr = w; dut->mrom_req = 1;
        int g = 0; while (!dut->mrom_ack && g++ < 4000) tick();
        dut->mrom_req = 0; tick();
        checked++; if (dut->mrom_q != be16(w * 2)) fail("prog", w, dut->mrom_q, be16(w * 2));
    }
    for (uint32_t b = 0; b < SND_BYTES; b += step) {
        dut->srom_addr = b; dut->srom_req = 1;
        int g = 0; while (!dut->srom_ack && g++ < 4000) tick();
        dut->srom_req = 0; tick();
        checked++; if (dut->srom_q != rom[SND_B + b]) fail("snd", b, dut->srom_q, rom[SND_B + b]);
    }
    for (uint32_t r = 0; r < GFX_WORDS; r += step) {
        dut->gfxl_addr = r; dut->gfxl_req = 1;
        int g = 0; while (!dut->gfxl_ack && g++ < 4000) tick();
        dut->gfxl_req = 0; tick();
        checked++; if (dut->gfxl_q != be32(GFX_B + r * 4)) fail("gfxl", r, dut->gfxl_q, be32(GFX_B + r * 4));
    }
    // the burst port: 32 image words a request, each with its own ack
    for (uint32_t r = 0; r + 32 <= GFX_WORDS; r += 32 * step) {
        dut->gfxs_addr = r; dut->gfxs_req = 1;
        int got = 0, g = 0;
        while (got < 32 && g++ < 40000) {
            tick();
            if (dut->gfxs_ack) {
                uint32_t want = be32(GFX_B + (r + got) * 4);
                checked++; if (dut->gfxs_q != want) fail("gfxs", r + got, dut->gfxs_q, want);
                got++;
            }
        }
        if (got < 32) fail("gfxs", r, got, 32);
        dut->gfxs_req = 0;
        for (int i = 0; i < 8; i++) tick();
    }
    printf("SDRAM: %ld words checked through the core's ports, %ld wrong\n", checked, bad);

    // ---- SRAM: write a pattern with byte enables, read it back
    long sbad = 0;
    auto vram = [&](bool we, uint32_t a, uint16_t d, int ben) {
        dut->vram_we = we; dut->vram_addr = a; dut->vram_din = d; dut->vram_ben = ben; dut->vram_req = 1;
        int g = 0; while (!dut->vram_ack && g++ < 4000) tick();
        dut->vram_req = 0; tick();
        return (uint16_t)dut->vram_q;
    };
    for (uint32_t a = 0; a < 32768; a += step) vram(true, a, uint16_t(a * 0x9E37 + 0x1234), 3);
    for (uint32_t a = 0; a < 32768; a += step) if (vram(false, a, 0, 3) != uint16_t(a * 0x9E37 + 0x1234)) sbad++;
    vram(true, 5, 0xFFFF, 3); vram(true, 5, 0x00AB, 1);            // low byte only
    if (vram(false, 5, 0, 3) != 0xFFAB) { sbad++; printf("  sram byte enables: got %04X want FFAB\n", dut->vram_q); }
    printf("SRAM:  %ld wrong\n", sbad);

    delete dut;
    if (bad || sbad) { printf("FAIL  what came back is not what was sent\n"); return 1; }
    printf("PASS  every region reads back byte-for-byte\n");
    return 0;
}
