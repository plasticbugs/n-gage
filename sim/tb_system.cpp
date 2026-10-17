// Driver for sim/tb_system_top.sv: the whole machine through the Pocket's real
// memory glue.  Loads a ROM image the way the Pocket's loader does, runs
// frames, and writes what the core drew.
//
//   obj_system/Vtb_system_top [rom] -frames N [-gap N] [-o DIR] [-snap a,b,c]
//
// With no rom a pseudo-random image is used, which is enough to exercise the
// memory path and the skeleton core; a real machine needs the real image.
//
// -gap is clocks between download bytes.  The APF loader delivers one per 8.
// A core that survives 12 and fails at 8 has the fault METHODOLOGY 5.16 is
// about, so 8 is the default and smaller is a harder test.
#include "Vtb_system_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

static const int W = 320, H = 224;
static const uint32_t IMG = 0x190000;      // must match <core>_mem.sv's layout

static Vtb_system_top *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

static void write_png(const std::string &path, const std::vector<uint8_t> &rgb);

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int frames = 10, gap = 8, hold = 4;
    std::string rom, out = ".";
    std::set<int> snaps;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&] { return std::string(argv[++i]); };
        if (a == "-frames") frames = atoi(next().c_str());
        else if (a == "-gap") gap = atoi(next().c_str());
        else if (a == "-o") out = next();
        else if (a == "-snap") {
            std::string s = next();
            for (size_t p = 0; p < s.size();) {
                size_t c = s.find(',', p); if (c == std::string::npos) c = s.size();
                snaps.insert(atoi(s.substr(p, c - p).c_str())); p = c + 1;
            }
        } else if (a[0] != '+' && a[0] != '-') rom = a;
    }
    if (hold >= gap) hold = gap - 1;
    if (snaps.empty()) snaps.insert(frames);

    std::vector<uint8_t> image(IMG);
    if (!rom.empty()) {
        FILE *f = fopen(rom.c_str(), "rb");
        if (!f || fread(image.data(), 1, IMG, f) != IMG) {
            fprintf(stderr, "cannot read %u bytes from %s\n", IMG, rom.c_str()); return 2;
        }
        fclose(f);
    } else {
        uint32_t x = 0x2545F491;
        for (auto &b : image) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; b = uint8_t(x >> 11); }
    }

    dut = new Vtb_system_top;
    dut->reset = 1; dut->pause = 0; dut->dl_we = 0;
    dut->dswa = dut->dswb = 0xff;
    dut->in0 = dut->in1 = dut->in2 = 0xff;         // active low: nothing pressed
    for (int i = 0; i < 16; i++) tick();
    long t = 0; while (!dut->mem_ready && t++ < 200000) tick();
    if (!dut->mem_ready) { printf("FAIL  the memory never came ready\n"); return 1; }

    for (uint32_t a = 0; a < IMG; a++) {
        dut->dl_addr = a; dut->dl_data = image[a]; dut->dl_we = 1;
        for (int i = 0; i < hold; i++) tick();
        dut->dl_we = 0;
        for (int i = hold; i < gap; i++) tick();
    }
    for (int i = 0; i < 400; i++) tick();
    dut->reset = 0;

    std::vector<uint8_t> frame(W * H * 3, 0);
    int px = 0, frame_no = 0, watchdogs = 0;
    bool in_vblank = true, cap = false;
    while (frame_no <= frames) {
        bool want = dut->pix_ce && dut->de;
        tick();
        if (dut->watchdog_reset) watchdogs++;
        if (cap && px < W * H) {
            frame[3 * px + 0] = (dut->rgb >> 16) & 0xff;
            frame[3 * px + 1] = (dut->rgb >> 8) & 0xff;
            frame[3 * px + 2] = dut->rgb & 0xff;
            px++;
        }
        cap = want;
        if (dut->vblank && !in_vblank) {
            if (snaps.count(frame_no) && px > 0) {
                char p[512]; snprintf(p, sizeof p, "%s/%04d.png", out.c_str(), frame_no);
                write_png(p, frame);
                printf("frame %d: %d pixels\n", frame_no, px);
            }
            frame_no++; px = 0;
            std::fill(frame.begin(), frame.end(), 0);
        }
        in_vblank = dut->vblank;
    }
    printf("%d frames, watchdog resets %d, halted %d\n", frames, watchdogs, (int)dut->dbg_halted);
    delete dut;
    return 0;
}

// --- a minimal PNG writer, so the bench needs nothing installed -------------
static void be32(std::vector<uint8_t> &v, uint32_t x) {
    v.push_back(x >> 24); v.push_back(x >> 16); v.push_back(x >> 8); v.push_back(x);
}
static uint32_t crc32_of(const uint8_t *d, size_t n) {
    static uint32_t tbl[256]; static bool init = false;
    if (!init) { for (uint32_t i = 0; i < 256; i++) { uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1; tbl[i] = c; } init = true; }
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) c = tbl[(c ^ d[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}
static void chunk(std::vector<uint8_t> &o, const char *tag, const std::vector<uint8_t> &data) {
    be32(o, (uint32_t)data.size());
    std::vector<uint8_t> td(tag, tag + 4);
    td.insert(td.end(), data.begin(), data.end());
    o.insert(o.end(), td.begin(), td.end());
    be32(o, crc32_of(td.data(), td.size()));
}
static void write_png(const std::string &path, const std::vector<uint8_t> &rgb) {
    std::vector<uint8_t> raw;
    for (int y = 0; y < H; y++) {
        raw.push_back(0);
        raw.insert(raw.end(), rgb.begin() + 3 * y * W, rgb.begin() + 3 * (y + 1) * W);
    }
    // stored (uncompressed) deflate blocks: no zlib dependency
    std::vector<uint8_t> z{0x78, 0x01};
    uint32_t a = 1, b = 0;
    for (uint8_t c : raw) { a = (a + c) % 65521; b = (b + a) % 65521; }
    for (size_t i = 0; i < raw.size(); i += 65535) {
        uint16_t n = (uint16_t)std::min<size_t>(65535, raw.size() - i);
        z.push_back(i + n >= raw.size() ? 1 : 0);
        z.push_back(n & 0xff); z.push_back(n >> 8);
        z.push_back(~n & 0xff); z.push_back((~n >> 8) & 0xff);
        z.insert(z.end(), raw.begin() + i, raw.begin() + i + n);
    }
    be32(z, (b << 16) | a);
    std::vector<uint8_t> o{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}, ihdr;
    be32(ihdr, W); be32(ihdr, H);
    ihdr.push_back(8); ihdr.push_back(2); ihdr.push_back(0); ihdr.push_back(0); ihdr.push_back(0);
    chunk(o, "IHDR", ihdr); chunk(o, "IDAT", z); chunk(o, "IEND", {});
    FILE *f = fopen(path.c_str(), "wb");
    if (f) { fwrite(o.data(), 1, o.size(), f); fclose(f); }
}
