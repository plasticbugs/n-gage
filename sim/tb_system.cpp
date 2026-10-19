// Driver for sim/tb_system_top.sv: the whole machine through the Pocket's real
// memory glue.  Loads the three slots the way the Pocket's loader does, runs
// frames, and writes what the LCD scanned out.
//
//   obj_system/Vtb_system_top --rom SYM.ROM [--kernel kernel.bin]
//       [--drive game.img] [--frames N] [--snap a,b,c] [-o DIR]
//       [--gap N] [--dl BYTES | --full] [--keys "S:MASK ..."] [--wav FILE]
//
// Every byte of the kernel goes through the download port, a byte every
// --gap clocks (the APF loader's rate is one per 7-8); of the ROM and the
// drive, the first --dl bytes do (64 KB by default) and the rest are
// written straight into the chip models, because the whole 35 MB at the
// loader's rate is minutes of simulation.  --full sends it all.  Either way
// the chips are then compared with the files byte for byte.
//
// Time runs at the two real clocks: 96 MHz and CPU_HZ.  --keys sets the
// pressed set (KEY_* bits, hex) at given seconds of machine time.  --wav
// records what the Pocket would play: the audio FIFO's current sample, held,
// taken at 48 kHz of machine time as core_top's crossing takes it.
#include "Vtb_system_top.h"
#include "Vtb_system_top___024root.h"
#include "Vtb_system_top_tb_system_top.h"
#include "verilated.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <sys/stat.h>
#include <string>
#include <vector>

#ifndef SYS_HZ
#define SYS_HZ 64000000
#endif
static const double CPU_HZ = SYS_HZ, MEM_HZ = 96e6;
static const int W = 176, H = 208;
static const uint32_t BUS_ROM = 0x2000000, BUS_DRIVE = 0x4000000;

static Vtb_system_top *dut;
static uint64_t sys_cycles, cpu_cycles;
static double t_sys, t_cpu;                    // the next rising edge of each, in ns

// advance to the next rising edge of either clock (both, if they coincide)
static void step()
{
    double sh = 0.5e9 / MEM_HZ, ch = 0.5e9 / CPU_HZ;
    double t = std::min(t_sys, t_cpu);
    bool s = t_sys <= t, c = t_cpu <= t;
    if (s) dut->clk = 1;
    if (c) dut->clk_cpu = 1;
    dut->eval();
    if (s) { sys_cycles++; t_sys += 2 * sh; }
    if (c) { cpu_cycles++; t_cpu += 2 * ch; }
    // the falling edges, before the next rising one
    dut->clk = 0; dut->clk_cpu = 0;
    dut->eval();
}
// run until n more 96 MHz edges
static void tick_sys(int n) { uint64_t e = sys_cycles + n; while (sys_cycles < e) step(); }

static std::vector<uint8_t> slurp(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    std::vector<uint8_t> d;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n);
    fclose(f);
    return d;
}

static void write_png(const std::string &path, const std::vector<uint8_t> &rgb);
static void write_wav(const std::string &path, const std::vector<uint32_t> &s, int rate);

// the chips' arrays
static uint16_t &sdram_hw(uint32_t h) { return dut->rootp->tb_system_top->chip__DOT__mem[h]; }
static uint16_t &cram_hw(uint32_t h)
{
    // drive halfword h: h[23] the chip, h[22:0] within it (cram_ctrl.sv)
    return (h >> 23) ? dut->rootp->tb_system_top->cram1__DOT__mem[h & 0x7FFFFF]
                     : dut->rootp->tb_system_top->cram0__DOT__mem[h & 0x7FFFFF];
}
static uint8_t bus_byte(uint32_t a)
{
    uint16_t h = a >= BUS_DRIVE ? cram_hw((a - BUS_DRIVE) >> 1) : sdram_hw(a >> 1);
    return (a & 1) ? h >> 8 : h & 0xFF;
}
static void bus_poke(uint32_t a, uint8_t b)
{
    uint16_t &h = a >= BUS_DRIVE ? cram_hw((a - BUS_DRIVE) >> 1) : sdram_hw(a >> 1);
    h = (a & 1) ? (h & 0x00FF) | b << 8 : (h & 0xFF00) | b;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    const char *rom = nullptr, *kernel = "build/kernel/kernel.bin", *drive = nullptr, *wav = nullptr;
    int frames = 10, gap = 8, hold = 4;
    size_t dl = 0x10000;
    bool full = false;
    std::string out = ".";
    std::set<int> snaps;
    std::vector<std::pair<double, unsigned>> keys;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&] { if (i + 1 >= argc) { fprintf(stderr, "%s wants a value\n", a.c_str()); exit(2); } return std::string(argv[++i]); };
        if (a == "--rom") rom = argv[++i];
        else if (a == "--kernel") kernel = argv[++i];
        else if (a == "--drive") drive = argv[++i];
        else if (a == "--frames") frames = atoi(next().c_str());
        else if (a == "--gap") gap = atoi(next().c_str());
        else if (a == "--dl") dl = strtoul(next().c_str(), nullptr, 0);
        else if (a == "--full") full = true;
        else if (a == "-o") out = next();
        else if (a == "--wav") wav = argv[++i];
        else if (a == "--snap") {
            std::string s = next();
            for (size_t p = 0; p < s.size();) {
                size_t c = s.find(',', p); if (c == std::string::npos) c = s.size();
                snaps.insert(atoi(s.substr(p, c - p).c_str())); p = c + 1;
            }
        } else if (a == "--keys") {
            std::string s = next();
            for (size_t p = 0; p < s.size();) {
                size_t c = s.find(' ', p); if (c == std::string::npos) c = s.size();
                std::string k = s.substr(p, c - p);
                size_t colon = k.find(':');
                if (colon != std::string::npos)
                    keys.push_back({atof(k.substr(0, colon).c_str()), (unsigned)strtoul(k.substr(colon + 1).c_str(), nullptr, 16)});
                p = c + 1;
            }
        } else if (a[0] != '+') { fprintf(stderr, "unknown argument %s\n", a.c_str()); return 2; }
    }
    if (!rom) { fprintf(stderr, "usage: %s --rom SYM.ROM [--kernel kernel.bin] [--drive img] [--frames N]\n", argv[0]); return 2; }
    if (hold >= gap) hold = gap - 1;
    if (snaps.empty()) snaps.insert(frames);
    mkdir(out.c_str(), 0755);                      // one level, as -o names it

    struct Slot { const char *name; uint32_t base; std::vector<uint8_t> data; };
    std::vector<Slot> slots = {{"kernel", 0, slurp(kernel)}, {"ROM", BUS_ROM, slurp(rom)}};
    if (drive) slots.push_back({"drive", BUS_DRIVE, slurp(drive)});

    dut = new Vtb_system_top;
    t_sys = 0; t_cpu = 0.37;                       // the two clocks are unrelated in phase
    dut->reset = 1; dut->dl_we = 0; dut->dl_active = 0; dut->keys = 0;
    tick_sys(16);
    long t = 0; while (!dut->mem_ready && t++ < 200000) tick_sys(1);
    if (!dut->mem_ready) { printf("FAIL  the memory never came ready\n"); return 1; }

    // ------------------------------------------------------------ the load
    dut->dl_active = 1;
    for (auto &s : slots) {
        // the first n bytes and the last two through the loader, which
        // counts the size from the last
        size_t len = s.data.size();
        size_t n = (full || s.base == 0) ? len : std::min(dl, len);
        std::vector<size_t> sent;
        for (size_t i = 0; i < n; i++) sent.push_back(i);
        for (size_t i = std::max(n, len < 2 ? 0 : len - 2); i < len; i++) sent.push_back(i);
        for (size_t i = n; i < len; i++) bus_poke(s.base + i, s.data[i]);
        for (size_t i : sent) {
            dut->dl_addr = s.base + i; dut->dl_data = s.data[i]; dut->dl_we = 1;
            tick_sys(hold);
            dut->dl_we = 0;
            tick_sys(gap - hold);
        }
        printf("%-6s %9zu bytes, %zu through the loader\n", s.name, len, sent.size());
    }
    dut->dl_active = 0;
    tick_sys(400);
    int bad = 0;
    for (auto &s : slots)
        for (size_t i = 0; i < s.data.size(); i++)
            if (bus_byte(s.base + i) != s.data[i]) {
                if (bad < 8) printf("FAIL  %s byte %zx: %02x, the file has %02x\n", s.name, i, bus_byte(s.base + i), s.data[i]);
                bad++;
            }
    if (bad) { printf("FAIL  %d bytes differ after the load\n", bad); return 1; }
    printf("load   every byte in place; rom_size %u, drive_size %u\n", dut->rom_size, dut->drive_size);
    if (dut->rom_size != slots[1].data.size() || (drive && dut->drive_size != slots[2].data.size())) {
        printf("FAIL  the sizes the loader counted are wrong\n"); return 1;
    }

    // ------------------------------------------------------------ the run
    dut->reset = 0;
    uint64_t sys0 = sys_cycles;
    std::vector<uint8_t> frame(W * H * 3, 0);
    int px = 0, frame_no = 0;
    bool in_vblank = true, putc_d = false, exit_d = false;
    std::string line;
    size_t ki = 0;
    uint64_t insns = 0, insns_mark = 0, cpu_mark = 0, fetch_run = 0, fetch_max = 0;
    std::vector<uint32_t> audio;                   // 48 kHz: 96 MHz / 2000
    uint64_t played = 0;
    bool snd_tog_d = dut->snd_tog;
    while (frame_no <= frames) {
        // the colour and de are registered together at the edge that ends a
        // pix_ce cycle, as core_top's clk_vid flops then take them
        bool edge = dut->pix_ce, ret = dut->retired;
        uint64_t sc = sys_cycles, cc = cpu_cycles;
        step();
        if (cpu_cycles != cc && ret) insns++;
        double secs = (sys_cycles - sys0) / MEM_HZ;
        while (ki < keys.size() && secs >= keys[ki].first) dut->keys = keys[ki++].second;
        if (dut->putc && !putc_d) {
            char c = (char)dut->pchar;
            if (c == '\n') { printf("[%7.3f s] %s\n", secs, line.c_str()); fflush(stdout); line.clear(); }
            else line += c;
        }
        putc_d = dut->putc;
        if (dut->dexit && !exit_d) { printf("[%7.3f s] the kernel wrote IO_DBG_EXIT\n", secs); break; }
        exit_d = dut->dexit;
        if (dut->snd_tog != snd_tog_d) played++;
        snd_tog_d = dut->snd_tog;
        if (sys_cycles == sc) continue;            // a CPU edge only: the picture did not move
        if (wav && (sys_cycles - sys0) % 2000 == 0) audio.push_back(dut->snd);
        if (dut->lcd_busy) { if (++fetch_run > fetch_max) fetch_max = fetch_run; } else fetch_run = 0;
        if (edge && dut->de && px < W * H) {
            frame[3 * px + 0] = (dut->rgb >> 16) & 0xff;
            frame[3 * px + 1] = (dut->rgb >> 8) & 0xff;
            frame[3 * px + 2] = dut->rgb & 0xff;
            px++;
        }
        if (dut->vblank && !in_vblank) {
            if (snaps.count(frame_no) && px > 0) {
                char p[512]; snprintf(p, sizeof p, "%s/%04d.png", out.c_str(), frame_no);
                write_png(p, frame);
                printf("[%7.3f s] frame %d: %d pixels -> %s\n", secs, frame_no, px, p);
            }
            if (frame_no % 30 == 0) {
                double mips = (insns - insns_mark) * CPU_HZ / 1e6 / std::max<uint64_t>(1, cpu_cycles - cpu_mark);
                printf("[%7.3f s] frame %d, pc %08x, %llu instructions, %.1f MIPS lately, line fetch at most %llu clocks\n",
                       secs, frame_no, dut->dbg_pc, (unsigned long long)insns, mips, (unsigned long long)fetch_max);
                fflush(stdout);
                insns_mark = insns; cpu_mark = cpu_cycles;
            }
            frame_no++; px = 0;
            std::fill(frame.begin(), frame.end(), 0);
        }
        in_vblank = dut->vblank;
    }
    if (!line.empty()) printf("%s\n", line.c_str());
    if (wav) {
        write_wav(wav, audio, 48000);
        printf("audio: the FIFO gave out %llu samples; %zu at 48 kHz to %s\n",
               (unsigned long long)played, audio.size(), wav);
    }
    int errs = dut->rootp->tb_system_top->chip__DOT__errors
             + dut->rootp->tb_system_top->cram0__DOT__errors
             + dut->rootp->tb_system_top->cram1__DOT__errors;
    printf("%d frames in %.3f s of machine time; %llu instructions; the longest line fetch %llu of 6328 clocks; "
           "%d memory protocol errors\n", frame_no, (sys_cycles - sys0) / MEM_HZ, (unsigned long long)insns,
           (unsigned long long)fetch_max, errs);
    delete dut;
    return errs ? 1 : 0;
}

// --- 16-bit stereo WAV: each word is L in 15:0, R in 31:16 -----------------
static void write_wav(const std::string &path, const std::vector<uint32_t> &s, int rate)
{
    auto le32 = [](std::vector<uint8_t> &v, uint32_t x) { for (int k = 0; k < 4; k++) v.push_back(x >> 8 * k); };
    std::vector<uint8_t> h{'R', 'I', 'F', 'F'};
    uint32_t n = (uint32_t)s.size() * 4;
    le32(h, 36 + n);
    for (char c : std::string("WAVEfmt ")) h.push_back(c);
    le32(h, 16); h.push_back(1); h.push_back(0); h.push_back(2); h.push_back(0);
    le32(h, rate); le32(h, rate * 4); h.push_back(4); h.push_back(0); h.push_back(16); h.push_back(0);
    for (char c : std::string("data")) h.push_back(c);
    le32(h, n);
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) { perror(path.c_str()); return; }
    fwrite(h.data(), 1, h.size(), f);
    for (uint32_t w : s) { uint8_t b[4] = {(uint8_t)w, (uint8_t)(w >> 8), (uint8_t)(w >> 16), (uint8_t)(w >> 24)}; fwrite(b, 1, 4, f); }
    fclose(f);
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
    if (!f) { perror(path.c_str()); exit(2); }
    fwrite(o.data(), 1, o.size(), f);
    fclose(f);
}
