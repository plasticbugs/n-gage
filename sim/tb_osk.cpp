// The on-screen keypad on its own (rtl/ngage_osk.sv): does it draw what the
// panel generator drew, does each key it shows press the key the generator
// says it presses, and does the machine see nothing of the pad that drives
// it -- the d-pad, A and B, and the SELECT + R chord?
//
//   obj_osk/Vngage_osk [-out DIR]        (sim/run_osk.sh builds and runs it)
//
// The bench is the LCD's raster (rtl/ngvm_lcd.sv, docs/core-design.md 2):
// 452 x 253 dots, one every 14 clocks, 176 x 208 visible from line 24,
// vsync on lines 248-250, and de and vsync changing at the cen_pix edge that
// starts each dot, as the LCD registers them.  The keypad's outputs for a dot
// are read just after that edge, which is when core_top's mux sees them
// beside the LCD's colour for the same dot.
//
// The turned picture's lookup (TATE, for the Analogizer) is asked about the
// same dot by its place, t_gx and t_gy, with t_cen a clock before the next
// cen_pix, and must answer as the upright one did, at every dot of every
// frame the bench runs.  Where the turned raster puts each place is the
// LCD's bench's business (sim/tb_lcd.cpp).
//
// IO_KEYS is read where the kernel reads it, once a frame at line 232 (the
// LCD's frame pulse, NGVM's vblank), and also watched at every clock, so a
// leak that lasts less than a frame still counts.
//
// The truth is tools/make_osk_panel.py's output, rtl/osk/ngage_osk_panel.hex:
// the bitmap for every pixel, and its key map (0x2D0) for every press.  The
// RTL reads the first and works the second out for itself.
#include "Vngage_osk.h"
#include "verilated.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static const int W = 176, H = 208, HTOTAL = 452, VTOTAL = 253, VIS_Y0 = 24;
static const int VS0 = 248, VS1 = 251, POLL_LINE = 232, DOT = 14;
static const int X0 = 52, Y_LOW = 124, Y_HIGH = 4, PW = 72, PH = 80, CW = 24, CH = 16;
static const int MAP_BASE = 0x2D0;
enum { K_UP, K_DOWN, K_LEFT, K_RIGHT, K_A, K_B, K_X, K_Y, K_L, K_R, K_SELECT, K_START };
static const char *PAD_NAME[15] = {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
                                   "*", "#", "left soft", "right soft", "C"};

static Vngage_osk *dut;
static std::vector<uint8_t> rom;
static unsigned pad = 0;                    // the buttons held
static uint32_t keys_or = 0;                // every IO_KEYS bit seen at any clock since cleared
static std::vector<uint32_t> polls;         // IO_KEYS where the kernel reads it, a frame each
static int bad = 0;
static long t_dots = 0, t_wrong = 0;        // the turned lookup: dots asked, answers unlike the upright one's

static void tick() {
    dut->pad = pad;
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    keys_or |= dut->keys;
}

struct Pic {
    std::vector<uint8_t> act, pix, held;
    Pic() : act(W * H, 0), pix(W * H, 0), held(W * H, 0) {}
};

// n lines of raster from where the last call left it; the keypad acts on the
// pad once a frame, at vsync (line 248)
static int at_line = 0;
static void lines(int n, Pic *p = nullptr) {
    for (; n > 0; n--, at_line = (at_line + 1) % VTOTAL)
        for (int h = 0; h < HTOTAL; h++) {
            int line = at_line;
            dut->cen_pix = 1;
            tick();                                         // the edge that starts the dot
            dut->de = (h < W && line >= VIS_Y0 && line < VIS_Y0 + H);
            dut->vsync = (line >= VS0 && line < VS1);
            dut->cen_pix = 0;
            bool vis = dut->de;
            dut->t_vis = vis; dut->t_gx = vis ? h : 0; dut->t_gy = vis ? line - VIS_Y0 : 0;
            dut->eval();
            int act = dut->active, pix = dut->pix, held = dut->held;
            if (p && vis) {
                int i = (line - VIS_Y0) * W + h;
                p->act[i] = act; p->pix[i] = pix; p->held[i] = held;
            }
            if (h == 0 && line == POLL_LINE) polls.push_back(dut->keys);
            for (int c = 1; c < DOT; c++) { dut->t_cen = c == DOT - 1; tick(); }
            dut->t_cen = 0;
            t_dots += vis;
            if (dut->t_active != act || (act && (dut->t_pix != pix || dut->t_held != held))) {
                if (t_wrong++ < 6) printf("  turned lookup at (%d, line %d): %d%d%d, upright %d%d%d\n", h, line,
                                          dut->t_active, dut->t_pix, dut->t_held, act, pix, held);
            }
        }
}
// one frame, from line 0
static void frame(Pic *p = nullptr) { lines(VTOTAL - at_line, p); }
static void frames(int n) { for (int i = 0; i < n; i++) frame(); }

static void check(bool ok, const char *what) {
    printf("  %-66s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) bad++;
}

// The picture the generator says: the bitmap, the key under the cursor filled
// inside its outline (2-21 across, 2-13 down) with its glyph dark, and the
// key that is down marked over its whole cell.
static long compare(const Pic &p, bool vis, bool top, int ccol, int crow, int kcol, int krow,
                    long *wrong_held = nullptr) {
    long wrong = 0, wh = 0;
    int y0 = top ? Y_HIGH : Y_LOW;
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            int i = y * W + x;
            bool inside = vis && x >= X0 && x < X0 + PW && y >= y0 && y < y0 + PH;
            if (p.act[i] != inside) { wrong++; continue; }
            if (!inside) continue;
            int px = x - X0, py = y - y0;
            int bit = (rom[py * (PW / 8) + px / 8] >> (7 - (px & 7))) & 1;
            int col = px / CW, row = py / CH, lx = px % CW, ly = py % CH;
            bool inner = lx >= 2 && lx <= 21 && ly >= 2 && ly <= 13;
            int want = bit ^ (inner && col == ccol && row == crow ? 1 : 0);
            if (p.pix[i] != want) wrong++;
            if (p.held[i] != (col == kcol && row == krow ? 1 : 0)) wh++;
        }
    if (wrong_held) *wrong_held = wh;
    return wrong;
}

// core_top's colours over a test picture, to look at
static void write_png(const std::string &path, const std::vector<uint8_t> &rgb, int w, int h);
static void snapshot(const Pic &p, const std::string &path) {
    std::vector<uint8_t> fb(W * H * 3);
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            int i = y * W + x;
            uint8_t r = (uint8_t)(x * 255 / W), g = (uint8_t)(y * 255 / H), b = 0x60;
            if (p.act[i]) {
                if (!p.pix[i]) r = g = b = 0;
                else if (p.held[i]) { r = 0xFF; g = 0xC0; b = 0x00; }
                else r = g = b = 0xFF;
            }
            fb[i * 3] = r; fb[i * 3 + 1] = g; fb[i * 3 + 2] = b;
        }
    write_png(path, fb, W, H);
    printf("  wrote %s\n", path.c_str());
}

// the cursor, as the bench keeps it
static int ccol = 1, crow = 2;                      // it opens on 5
static void tap(int k) {
    pad = 1u << k; frame();
    pad = 0;       frame();
    if (k == K_UP)    crow = (crow + 4) % 5;
    if (k == K_DOWN)  crow = (crow + 1) % 5;
    if (k == K_LEFT)  ccol = (ccol + 2) % 3;
    if (k == K_RIGHT) ccol = (ccol + 1) % 3;
}
static void go_to(int col, int row) {
    while (crow != row) tap(row > crow ? K_DOWN : K_UP);
    while (ccol != col) tap(col > ccol ? K_RIGHT : K_LEFT);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string out = "artifacts/osk";
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "-out") && i + 1 < argc) out = argv[++i];

    FILE *f = fopen("rtl/osk/ngage_osk_panel.hex", "r");
    if (!f) { fprintf(stderr, "run me from the repository root (sim/run_osk.sh does)\n"); return 2; }
    unsigned v;
    while (fscanf(f, "%x", &v) == 1) rom.push_back((uint8_t)v);
    fclose(f);
    printf("panel image: %zu bytes, key map at 0x%03X\n", rom.size(), MAP_BASE);

    dut = new Vngage_osk;
    dut->clk = 0; dut->cen_pix = 0; dut->de = 0; dut->vsync = 0; dut->pad = 0;
    dut->rst = 1;
    for (int i = 0; i < 16; i++) tick();
    dut->rst = 0;
    frames(2);

    // ---------------------------------------------------------- keypad down
    printf("keypad down\n");
    Pic p;
    keys_or = 0;
    frame(&p);
    check(compare(p, false, false, 0, 0, -1, -1) == 0 && !dut->visible,
          "no pixel of a whole frame is the keypad's (the picture is the LCD's)");
    check(keys_or == 0, "IO_KEYS reads 0 with nothing pressed");

    // every button but SELECT and R reaches the machine as it is
    unsigned straight = (1u << K_UP) | (1u << K_DOWN) | (1u << K_LEFT) | (1u << K_RIGHT) | (1u << K_A) |
                        (1u << K_B) | (1u << K_X) | (1u << K_Y) | (1u << K_L) | (1u << K_START);
    for (int k = 0; k < 12; k++) {
        if (k == K_R || k == K_SELECT) continue;
        pad = 1u << k;
        for (int i = 0; i < 4; i++) tick();
        if (dut->keys != (1u << k)) { printf("  button %d: IO_KEYS %07x\n", k, dut->keys); bad++; }
        pad = 0;
        for (int i = 0; i < 4; i++) tick();
    }
    check(true, "d-pad, A, B, X, Y, L, start: each reaches IO_KEYS within 4 clocks");
    pad = straight; frame();
    check(polls.back() == straight, "all ten together");
    pad = 0; frames(2);

    // SELECT and R alone arrive late, and as long as they were held
    for (int k : {K_SELECT, K_R}) {
        polls.clear();
        pad = 1u << k; frames(10);
        pad = 0;       frames(8);
        int first = -1, n = 0;
        for (size_t i = 0; i < polls.size(); i++)
            if (polls[i] & (1u << k)) { if (first < 0) first = (int)i; n++; }
        char what[96];
        snprintf(what, sizeof what, "%s alone, held 10 frames: read in %d frames, from the %d%s",
                 k == K_R ? "R" : "SELECT", n, first + 1, first == 0 ? "st" : first == 1 ? "nd" : first == 2 ? "rd" : "th");
        check(n == 10 && first >= 3 && first <= 4, what);
    }

    // ------------------------------------------------------------- the chord
    // pressed with the two buttons up to three frames apart, either first:
    // neither may reach the machine at any clock
    printf("the chord\n");
    keys_or = 0;
    pad = 1u << K_SELECT; frames(3);
    pad |= 1u << K_R;     frames(2);
    pad = 1u << K_SELECT; frames(1);                   // R let go first
    pad = 0;              frames(2);
    check(dut->visible, "SELECT, then R three frames later: the keypad is up");
    check((keys_or & ((1u << K_R) | (1u << K_SELECT))) == 0,
          "and neither SELECT nor R reached IO_KEYS at any clock");

    // ------------------------------------------------------------ the panel
    p = Pic();
    keys_or = 0;
    frame(&p);
    long wrong = compare(p, true, false, ccol, crow, -1, -1);
    printf("  panel at (%d, %d), %dx%d; cursor on %s\n", X0, Y_LOW, PW, PH, PAD_NAME[rom[MAP_BASE + crow * 3 + ccol]]);
    check(wrong == 0, wrong ? "pixels differing from the generator's: SOME" : "every pixel of the frame as the generator drew it, cursor on 5");
    if (wrong) printf("    %ld differ\n", wrong);
    snapshot(p, out + "/keypad.png");

    // --------------------------------------------- every key, moved to and pressed
    printf("every key\n");
    int keys_ok = 0, pic_ok = 0;
    uint32_t low_seen = 0;
    for (int row = 0; row < 5; row++)
        for (int col = 0; col < 3; col++) {
            keys_or = 0;
            go_to(col, row);
            low_seen |= keys_or & 0xFFF;
            Pic q;
            frame(&q);
            if (compare(q, true, false, ccol, crow, -1, -1) == 0) pic_ok++;
            else printf("  cursor at (%d, %d): the picture differs\n", col, row);
            int want = rom[MAP_BASE + row * 3 + col];
            polls.clear(); keys_or = 0;
            pad = 1u << K_A; frame();
            pad = 0;         frames(7);
            int n = 0;
            for (uint32_t k : polls) if (k == (1u << (12 + want))) n++;
            low_seen |= keys_or & 0xFFF;
            bool ok = (keys_or == (1u << (12 + want))) && n >= 3 && polls.back() == 0;
            if (ok) keys_ok++;
            else printf("  %s at (%d, %d): IO_KEYS showed %07x, read pressed in %d frames, last %07x\n",
                        PAD_NAME[want], col, row, keys_or, n, polls.back());
        }
    check(pic_ok == 15, "the cursor drawn on each of the 15 keys as the generator lays them out");
    char what[96];
    snprintf(what, sizeof what, "A on each key: its own IO_KEYS bit, alone, read in >= 3 frames: %d of 15", keys_ok);
    check(keys_ok == 15, what);
    check(low_seen == 0, "while the keypad is up the machine sees no button (bits 0-11 stay 0)");

    // B presses too
    go_to(1, 2);
    keys_or = 0;
    pad = 1u << K_B; frame(); pad = 0; frames(6);
    check(keys_or == (1u << (12 + 5)), "B presses as A does: 5");

    // a key is down while the button is, and the panel shows it amber
    go_to(2, 4);                                       // #
    polls.clear();
    pad = 1u << K_A; frames(3);
    Pic q;
    frame(&q);
    long wh = 0;
    long wpix = compare(q, true, false, ccol, crow, ccol, crow, &wh);
    frames(6);
    pad = 0; frames(3);
    int n = 0;
    for (uint32_t k : polls) if (k == (1u << (12 + 11))) n++;
    check(n == 10, "# held 10 frames: read down in 10 frames, up at once after");
    check(wpix == 0 && wh == 0, "and while it is down its cell is marked, and nothing else");
    snapshot(q, out + "/keypad_held.png");

    // two quick taps of one key are two presses, with the key read up between
    go_to(1, 1);                                       // 2
    polls.clear();
    pad = 1u << K_A; frame();
    pad = 0;         frame();
    pad = 1u << K_A; frame();
    pad = 0;         frames(10);
    int runs = 0, gap_min = 99, gap = 0;
    bool was = false;
    for (uint32_t k : polls) {
        bool d = k == (1u << (12 + 2));
        if (d && !was) { runs++; if (runs > 1) gap_min = std::min(gap_min, gap); }
        if (!d) gap++; else gap = 0;
        was = d;
    }
    snprintf(what, sizeof what, "2 tapped twice a frame apart: %d presses, read up %d frames between", runs, gap_min);
    check(runs == 2 && gap_min >= 2, what);

    // the cursor wraps at the edges
    go_to(0, 0);
    tap(K_LEFT); tap(K_UP);
    p = Pic(); frame(&p);
    check(ccol == 2 && crow == 4 && compare(p, true, false, ccol, crow, -1, -1) == 0,
          "left from the left column and up from the top row wrap round");

    // holding a direction repeats: a move at once, then after 18 frames, then every 6
    go_to(0, 2);
    pad = 1u << K_RIGHT; frames(31);
    pad = 0; frame();
    ccol = (0 + 4) % 3;                                // frames 1, 19, 25 and 31
    p = Pic(); frame(&p);
    check(compare(p, true, false, ccol, crow, -1, -1) == 0, "right held 31 frames moves the cursor 4 keys");

    // Y moves the keypad to the top of the picture and back
    tap(K_Y);
    p = Pic(); frame(&p);
    check(compare(p, true, true, ccol, crow, -1, -1) == 0, "Y: the keypad at the top, every pixel as the generator drew it");
    snapshot(p, out + "/keypad_top.png");
    tap(K_Y);
    p = Pic(); frame(&p);
    check(compare(p, true, false, ccol, crow, -1, -1) == 0, "Y again: back at the bottom");

    // ---------------------------------------------------- dismissed
    printf("dismissed\n");
    keys_or = 0;
    pad = 1u << K_R;      frames(2);                   // R first this time
    pad |= 1u << K_SELECT; frames(2);
    pad = 1u << K_R;      frames(5);                   // and held on after SELECT
    pad = 0;              frames(6);
    check(!dut->visible, "R, then SELECT two frames later: the keypad is gone");
    check(keys_or == 0, "and IO_KEYS showed nothing at any clock, the chord included");
    p = Pic(); frame(&p);
    check(compare(p, false, false, 0, 0, -1, -1) == 0, "no pixel of the frame is the keypad's");
    pad = 1u << K_A; frame();
    check(polls.back() == (1u << K_A), "A is the game's A again");
    pad = 0; frames(2);

    // it opens again where it was left
    pad = (1u << K_SELECT) | (1u << K_R); frame();
    pad = 0; frames(2);
    p = Pic(); frame(&p);
    check(compare(p, true, false, ccol, crow, -1, -1) == 0, "shown again: the cursor where it was left");

    // the chord's tolerance at its tightest: SELECT pressed on the line before
    // the keypad takes the pad, so it is a frame older at each frame after
    printf("the chord's tolerance\n");
    const unsigned SR = (1u << K_SELECT) | (1u << K_R);
    pad = SR; frame(); pad = 0; frames(2);             // put it away
    keys_or = 0;
    lines(VS0 - 1);
    pad = 1u << K_SELECT; lines(3 * VTOTAL - 2);
    pad |= 1u << K_R;     frames(2);
    pad = 0;              frames(2);
    check(dut->visible && (keys_or & SR) == 0,
          "R 3 frames less 2 lines after SELECT: the chord, and neither sent");
    pad = SR; frame(); pad = 0; frames(2);
    keys_or = 0;
    lines(VS0 - 1);
    pad = 1u << K_SELECT; lines(3 * VTOTAL + 2);
    pad |= 1u << K_R;     frames(2);
    pad = 0;              frames(2);
    check(dut->visible && (keys_or & SR) == (1u << K_SELECT),
          "3 frames and 2 lines: SELECT was sent as #, as a press of its own");

    char twhat[120];
    snprintf(twhat, sizeof twhat, "the turned lookup: %ld picture dots, %ld unlike the upright", t_dots, t_wrong);
    check(t_dots > 0 && t_wrong == 0, twhat);

    delete dut;
    printf(bad ? "FAIL (%d)\n" : "PASS\n", bad);
    return bad ? 1 : 0;
}

// --- a minimal PNG writer, so the bench needs nothing installed (as tb_system.cpp's)
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
static void write_png(const std::string &path, const std::vector<uint8_t> &rgb, int w, int h) {
    std::vector<uint8_t> raw;
    for (int y = 0; y < h; y++) {
        raw.push_back(0);
        raw.insert(raw.end(), rgb.begin() + 3 * y * w, rgb.begin() + 3 * (y + 1) * w);
    }
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
    be32(ihdr, w); be32(ihdr, h);
    ihdr.push_back(8); ihdr.push_back(2); ihdr.push_back(0); ihdr.push_back(0); ihdr.push_back(0);
    chunk(o, "IHDR", ihdr); chunk(o, "IDAT", z); chunk(o, "IEND", {});
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) { perror(path.c_str()); return; }
    fwrite(o.data(), 1, o.size(), f);
    fclose(f);
}
