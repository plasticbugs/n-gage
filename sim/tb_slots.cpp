// Driver for sim/tb_slots_top.sv: the drive's fetches and the save's writes
// through ngage_slots, core_bridge_cmd and data_io, against a Pocket host
// that varies everything its firmware is free to (sim/apf_host.h, random).
//
//   obj_slots/Vtb_slots_top [-n FETCHES] [-seed N]
//
// The kernel's side asks for fetches one at a time, as IO_FETCH_* does: the
// words set, then the toggle, then nothing until the answer's toggle.  Most
// are short, so that many run; some are 64 KB, the kernel's block; some end
// at the window's end or the image's.  Between fetches, now and then, a
// write to C: (save_t) and the Pocket's menu opened and shut, so the save's
// writes come and contend with the fetches for the one command interface.
//
// The bytes are taken as ngage_mem takes them, once on each strobe's rise,
// and each reaches this bench's memory 2-20 clocks after the one before it
// (now and then 400), dl_idle low while any has not: a fetch is answered
// only once its last byte is in.  Before each, its span of the window is
// filled with bytes it is not, so a byte the answer comes before is caught.
//
// Fails on: a fetch answered before all its bytes are in, or with a byte
// wrong; a byte anywhere else; a byte strobed while the download path is
// shut (core_top would drop it); an error code that is not the host's; a
// request the host would refuse; a fetch not answered in 300 ms; the
// loader's FIFO written while full (the host too fast: a bench fault).
#include "Vtb_slots_top.h"
#include "verilated.h"
#include "apf_host.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>
#include <vector>

static Vtb_slots_top *dut;
static uint64_t sys_cycles, a_cycles;
static double t_sys, t_a;
static const double MEM_HZ = 96e6, A_HZ = 74.25e6;
static const uint32_t BUS_DRIVE = 0x4000000, WINDOW = 0x2000000, IMAGE = 0x3C00000;

static uint32_t rng = 0x9E3779B9u;
static uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static uint8_t img(uint64_t o)
{
    uint32_t x = (uint32_t)o * 0x9E3779B1u;
    x ^= x >> 15; x *= 0x85EBCA77u; x ^= x >> 13;
    return (uint8_t)x;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    int nfetch = 400;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-n" && i + 1 < argc) nfetch = atoi(argv[++i]);
        else if (a == "-seed" && i + 1 < argc) rng = (uint32_t)strtoul(argv[++i], nullptr, 0) | 1;
        else if (a[0] != '+') { fprintf(stderr, "unknown argument %s\n", a.c_str()); return 2; }
    }
    dut = new Vtb_slots_top;
    ApfHost host;
    host.wr = &dut->bridge_wr; host.rd = &dut->bridge_rd;
    host.addr = &dut->bridge_addr; host.wdata = &dut->bridge_wr_data; host.rdata = &dut->bridge_rd_data;
    host.image_size = IMAGE;
    host.image = img;
    host.random = true;
    host.rng = rnd() | 1;

    std::vector<uint8_t> win(WINDOW, 0);
    struct Byte { uint32_t a; uint8_t d; uint64_t ready; };
    std::deque<Byte> sq;
    uint64_t last_ready = 0;
    bool we_d = false, io_d = false;

    // the fetch in flight
    enum { K_BOOT, K_IDLE, K_ARM, K_WAIT } ks = K_BOOT;
    uint32_t f_src = 0, f_dst = 0, f_len = 0, f_in = 0;
    uint64_t f_t0 = 0, k_gap = 0;
    int done = 0, bad = 0, stray = 0, lost = 0, saves_asked = 0, menus = 0, big = 0, errs = 0;
    double lat_max = 0, lat_big = 0;
    bool menu_open = false;
    auto failf = [&](const char *msg) { if (bad++ < 12) printf("FAIL  fetch %d (%x bytes, %x -> %x): %s\n", done, f_len, f_src, f_dst, msg); };

    dut->clk = 0; dut->clk_74a = 0; dut->setup_done = 0; dut->dl_idle = 1;
    dut->save_t = 0; dut->fetch_t = 0;
    t_sys = 0; t_a = 0.37;
    uint64_t t_end = 0;
    while (true) {
        double sh = 0.5e9 / MEM_HZ, ah = 0.5e9 / A_HZ;
        double t = std::min(t_sys, t_a);
        bool s = t_sys <= t, a = t_a <= t;
        if (s) dut->clk = 1;
        if (a) dut->clk_74a = 1;
        dut->eval();
        if (a) {
            a_cycles++; t_a += 2 * ah;
            if (a_cycles == 100) dut->setup_done = 1;
            if (a_cycles == 2000) host.boot();      // the load is done
            host.edge();
        }
        if (s) {
            sys_cycles++; t_sys += 2 * sh;
            uint64_t now = sys_cycles;
            // ngage_mem's side
            bool we = dut->dl_we;
            if (we && !we_d) {
                last_ready = std::max(last_ready, now) + 2 + rnd() % 19 + (rnd() % 300 ? 0 : 400);
                sq.push_back({dut->dl_addr, dut->dl_data, last_ready});
            }
            we_d = we;
            bool io = dut->io_wr;
            if (io && !io_d && !dut->dl_open && lost++ < 4) printf("FAIL  a byte strobed in at %07x while the path is shut\n", dut->dl_addr);
            io_d = io;
            while (!sq.empty() && sq.front().ready <= now) {
                Byte b = sq.front(); sq.pop_front();
                uint32_t o = b.a - BUS_DRIVE;
                if (b.a >= BUS_DRIVE && o < WINDOW && ks == K_WAIT && o - f_dst < f_len) { win[o] = b.d; f_in++; }
                else if (stray++ < 4) printf("FAIL  a byte at %07x, outside the fetch in flight\n", b.a);
            }
            dut->dl_idle = sq.empty();

            // the kernel's side
            switch (ks) {
            case K_BOOT:
                if (host.loaded) { ks = K_IDLE; k_gap = now + 1000; }
                else if (now > (uint64_t)(0.05 * MEM_HZ)) {
                    printf("FAIL  the host's all-complete not answered in 50 ms: 0x0140 %llu, allcomplete %d, bridge %08x\n",
                           (unsigned long long)host.ready, dut->allcomplete, dut->bridge_rd_data);
                    bad++; goto out;
                }
                break;
            case K_IDLE: {
                if (now < k_gap) break;
                if (done == nfetch) { if (!t_end) t_end = now + 2000000; break; }
                unsigned r = rnd() % 100;
                f_len = r < 40 ? 4 + 4 * (rnd() % 16) : r < 80 ? 4 * (16 + rnd() % 1009)
                      : r < 95 ? 4 * (1024 + rnd() % 3073) : 0x10000;
                f_dst = 4 * (rnd() % ((WINDOW - f_len) / 4 + 1));
                f_src = 4 * (rnd() % ((IMAGE - f_len) / 4 + 1));
                if (rnd() % 20 == 0) f_dst = WINDOW - f_len;
                if (rnd() % 20 == 0) f_src = IMAGE - f_len;
                for (uint32_t i = 0; i < f_len; i++) win[f_dst + i] = ~img(f_src + i);
                dut->fetch_src = f_src; dut->fetch_dst = f_dst; dut->fetch_len = f_len;
                f_in = 0;
                ks = K_ARM;
                break;
            }
            case K_ARM:
                dut->fetch_t = !dut->fetch_t;
                f_t0 = now;
                ks = K_WAIT;
                break;
            case K_WAIT:
                if (dut->fetch_done_t != dut->fetch_t) {
                    if (now - f_t0 > (uint64_t)(0.3 * MEM_HZ)) { failf("not answered in 300 ms"); goto out; }
                    break;
                }
                {
                    double us = (now - f_t0) / 96.0;
                    lat_max = std::max(lat_max, us);
                    if (f_len == 0x10000) { big++; lat_big = std::max(lat_big, us); }
                    int err = dut->fetch_err;
                    if (err != host.last_err) failf(("error " + std::to_string(err) + ", the host's " + std::to_string(host.last_err)).c_str());
                    if (err) {
                        errs++;
                        if (f_in) failf("bytes came with an error");
                    } else if (f_in != f_len) {
                        failf(("answered with " + std::to_string(f_in) + " bytes in").c_str());
                    } else {
                        int wrong = 0;
                        for (uint32_t i = 0; i < f_len; i++) if (win[f_dst + i] != img(f_src + i)) wrong++;
                        if (wrong) failf((std::to_string(wrong) + " bytes wrong").c_str());
                    }
                }
                done++;
                ks = K_IDLE;
                k_gap = now + (rnd() % 4 ? rnd() % 20000 : 0);
                if (rnd() % 30 == 0) { dut->save_t = !dut->save_t; saves_asked++; }
                if (rnd() % 60 == 0) { menu_open = !menu_open; host.menu(menu_open); menus++; }
                if (done % 100 == 0) { printf("  %d fetches, %.1f ms\n", done, sys_cycles / 96e3); fflush(stdout); }
                break;
            }
        }
        dut->clk = 0; dut->clk_74a = 0;
        dut->eval();
        if (t_end && sys_cycles >= t_end && !host.in_cmd) break;
        if (bad > 50) break;
    }
out:
    printf("%d fetches (%d of 64 KB, the longest answered in %.0f us; any, %.0f us), %d answered with an error\n",
           done, big, lat_big, lat_max, errs);
    printf("host: %llu reads, %llu writes, %llu words in, %llu out; 0x0140 %llu; errors injected %llu; "
           "request write first %llu, all-complete after %llu; no \"bu\" %llu; \"ok\" at once %llu\n",
           (unsigned long long)host.reads, (unsigned long long)host.writes, (unsigned long long)host.words_in,
           (unsigned long long)host.words_out, (unsigned long long)host.ready, (unsigned long long)host.injected,
           (unsigned long long)host.reqwrites, (unsigned long long)host.completes, (unsigned long long)host.no_bu,
           (unsigned long long)host.ok_at_once);
    printf("save: C: written %d times, the menu opened or shut %d times\n", saves_asked, menus);
    if (host.failures) bad++;
    if (!host.ready) { printf("FAIL  no 0x0140\n"); bad++; }
    if (!host.writes || (saves_asked && host.writes < 2)) { printf("FAIL  the save was not written\n"); bad++; }
    if (dut->fifo_overflows) { printf("FAIL  the loader's FIFO overflowed %u times\n", dut->fifo_overflows); bad++; }
    if (stray || lost) bad++;
    printf("%s  %.1f ms of machine time\n", bad ? "FAIL" : "ok  ", sys_cycles / 96e3);
    delete dut;
    return bad ? 1 : 0;
}
