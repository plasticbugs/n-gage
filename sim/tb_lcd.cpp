// The LCD on its own (rtl/ngvm_lcd.sv): its frame store, filled through the
// copy port as ngage_mem fills it, and both rasters it scans from it -- the
// upright one the Pocket and the Analogizer get, and the turned one (TATE)
// the Analogizer gets instead when the menu asks for it.
//
//   obj_lcd/Vngvm_lcd [-out DIR] [-pic FILE]   (sim/run_lcd.sh builds and runs it)
//
// Two pictures go through the store, each a whole frame copied by `show`:
// one whose pixels hold their column (x << 4 | y & 15) and one their row
// (y << 4 | x & 15), so between them every pixel names its own place.  For
// each, over two frames of each raster after the copy, with the turned
// raster clockwise, anticlockwise and off, every dot is compared with what
// it must be:
//   upright  452 x 253 dots, one a cen_pix; the picture at dots 0-175 of
//            lines 24-231, hsync on dots 300-331, vsync on lines 248-250,
//            blanks and de with it; the same whatever the turned raster does
//   turned   382 x 262 dots, one every 16 clocks; dot h of line v shows the
//            picture's row h and column 175 - v (clockwise) or row 207 - h
//            and column v (anticlockwise), for h < 208 and v < 176; hsync on
//            dots 271-298, vsync on lines 212-214; t_gx, t_gy and t_vis name
//            the dot the next t_cen shows
// Then a test card (corners marked, an arrow pointing up) is drawn through
// both rasters into DIR (artifacts/lcd): upright.png, tate_cw.png and
// tate_ccw.png, as a CRT shows them before it is turned.  -pic takes a
// 176 x 208 RGB file (raw, 8 bits a channel) to draw instead.
#include "Vngvm_lcd.h"
#include "verilated.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static const int W = 176, H = 208, HTOTAL = 452, VTOTAL = 253, VIS_Y0 = 24, DOT = 14;
static const int HS0 = 300, HS1 = 332, VS0 = 248, VS1 = 251;
static const int T_HTOTAL = 382, T_VTOTAL = 262, T_DOT = 16;
static const int T_HS0 = 271, T_HS1 = 299, T_VS0 = 212, T_VS1 = 215;
static const uint32_t BASE = 0x100000;              // lcd_base, bytes

static Vngvm_lcd *dut;
static std::vector<uint16_t> pic(W * H);            // what the store should hold
static uint64_t clocks = 0;
static long dots_up = 0, dots_t = 0, bad_up = 0, bad_t = 0, bad_coord = 0;
static bool checking = false;
static int tate = 0;
static long up_n = 0, t_n = 0;                      // dots registered since reset

// the frames being drawn, for the PNGs
static std::vector<uint8_t> grab_up(W * H * 3), grab_t(H * W * 3);

static uint32_t expand(uint16_t p) {
    uint32_t r = (p >> 8) & 15, g = (p >> 4) & 15, b = p & 15;
    return (r << 20) | (r << 16) | (g << 12) | (g << 8) | (b << 4) | b;
}

static void report(long &bad, const char *what, long n, int h, int v, uint32_t got, uint32_t want) {
    if (bad++ < 6) printf("  %s dot %ld (%d, line %d): got %06x want %06x\n", what, n, h, v, got, want);
}

// the copy port, served as ngage_mem serves it: a burst of l_len halfwords
// from l_addr, one a clock, then l_done
static int c_left = 0, c_idx = 0, c_wait = 0;
static uint32_t c_addr = 0;

static void tick() {
    // inputs for this edge
    dut->l_wr = 0; dut->l_done = 0;
    if (c_left > 0) {
        if (c_wait > 0) c_wait--;
        else {
            uint32_t a = c_addr + c_idx - (BASE >> 1);
            dut->l_wr = 1; dut->l_idx = c_idx; dut->l_data = a < (uint32_t)(W * H) ? pic[a] : 0;
            if (++c_idx == c_left) c_left = -1;     // l_done on the next clock
        }
    } else if (c_left < 0) {
        dut->l_done = 1; c_left = 0;
    } else if (dut->l_req) {
        c_addr = dut->l_addr; c_left = dut->l_len; c_idx = 0; c_wait = 3;
    }
    dut->tate = tate;
    dut->cen_pix = (clocks % DOT) == DOT - 1;
    bool cen = dut->cen_pix, tcen = dut->t_cen;
    // the turned raster's place for the dot the next t_cen shows
    int tn = (int)(t_n % (T_HTOTAL * T_VTOTAL)), th = tn % T_HTOTAL, tv = tn / T_HTOTAL;
    if (checking && tcen && tate) {
        bool vis = th < H && tv < W;
        int gx = tate == 2 ? tv : W - 1 - tv, gy = tate == 2 ? H - 1 - th : th;
        if (dut->t_vis != vis || (vis && (dut->t_gx != gx || dut->t_gy != gy))) {
            if (bad_coord++ < 6) printf("  t_gx/t_gy dot (%d, line %d): %d,%d vis %d, want %d,%d vis %d\n",
                                        th, tv, dut->t_gx, dut->t_gy, dut->t_vis, gx, gy, vis);
        }
    }
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    clocks++;
    if (cen) {                                      // the upright raster's dot up_n
        int n = (int)(up_n % (HTOTAL * VTOTAL)), h = n % HTOTAL, v = n / HTOTAL;
        bool vis = h < W && v >= VIS_Y0 && v < VIS_Y0 + H;
        uint32_t want = vis ? expand(pic[(v - VIS_Y0) * W + h]) : 0;
        if (vis) {
            uint32_t c = dut->rgb;
            int i = ((v - VIS_Y0) * W + h) * 3;
            grab_up[i] = c >> 16; grab_up[i + 1] = c >> 8; grab_up[i + 2] = c;
        }
        if (checking) {
            dots_up++;
            if (dut->rgb != want) report(bad_up, "upright", up_n, h, v, dut->rgb, want);
            int s = (dut->de << 5) | (dut->hblank << 4) | (dut->vblank << 3) | (dut->hsync << 2) | (dut->vsync << 1);
            int ws = (vis << 5) | ((h >= W) << 4) | ((v < VIS_Y0 || v >= VIS_Y0 + H) << 3)
                   | ((h >= HS0 && h < HS1) << 2) | ((v >= VS0 && v < VS1) << 1);
            if (s != ws) report(bad_up, "upright syncs", up_n, h, v, s, ws);
        }
        up_n++;
    }
    if (tcen) {                                     // the turned raster's dot t_n
        bool vis = th < H && tv < W;
        if (tate && vis) {
            uint32_t c = dut->t_rgb;
            int i = (tv * H + th) * 3;
            grab_t[i] = c >> 16; grab_t[i + 1] = c >> 8; grab_t[i + 2] = c;
        }
        if (checking && tate) {
            dots_t++;
            int gx = tate == 2 ? tv : W - 1 - tv, gy = tate == 2 ? H - 1 - th : th;
            uint32_t want = vis ? expand(pic[gy * W + gx]) : 0;
            if (dut->t_rgb != want) report(bad_t, "turned", t_n, th, tv, dut->t_rgb, want);
            int s = (dut->t_de << 5) | (dut->t_hblank << 4) | (dut->t_vblank << 3) | (dut->t_hsync << 2) | (dut->t_vsync << 1);
            int ws = (vis << 5) | ((th >= H) << 4) | ((tv >= W) << 3)
                   | ((th >= T_HS0 && th < T_HS1) << 2) | ((tv >= T_VS0 && tv < T_VS1) << 1);
            if (s != ws) report(bad_t, "turned syncs", t_n, th, tv, s, ws);
        }
        t_n++;
    }
}

static void run(uint64_t n) { for (uint64_t i = 0; i < n; i++) tick(); }
static const uint64_t FRAME_UP = (uint64_t)HTOTAL * VTOTAL * DOT, FRAME_T = (uint64_t)T_HTOTAL * T_VTOTAL * T_DOT;

// `show`, and wait for the copy to end
static void show() {
    dut->show = 1; tick(); dut->show = 0;
    int idle = 0;                                   // l_req falls for a clock between bursts
    for (int i = 0; i < 400000 && idle < 8; i++) { tick(); idle = (dut->l_req || c_left) ? 0 : idle + 1; }
    run(1000);
}

static int bad = 0;
static void check(bool ok, const char *what) {
    printf("  %-70s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok) bad++;
}

// two frames of each raster after a copy, at one setting of the turned raster
static void check_frames(int t, const char *name) {
    tate = t;
    run(T_DOT * 4);
    dots_up = dots_t = bad_up = bad_t = bad_coord = 0;
    checking = true;
    run(2 * std::max(FRAME_UP, FRAME_T));
    checking = false;
    char what[160];
    snprintf(what, sizeof what, "%s: upright raster, %ld dots, %ld wrong", name, dots_up, bad_up);
    check(bad_up == 0 && dots_up >= 2 * HTOTAL * VTOTAL, what);
    if (t) {
        snprintf(what, sizeof what, "%s: turned raster, %ld dots, %ld wrong, %ld places wrong", name, dots_t, bad_t, bad_coord);
        check(bad_t == 0 && bad_coord == 0 && dots_t >= 2 * T_HTOTAL * T_VTOTAL, what);
    }
}

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
    printf("  wrote %s\n", path.c_str());
}

// the test card: grey ground, a coloured block in each corner (red top left,
// green top right, blue bottom left, yellow bottom right) and a white arrow
// pointing up the middle
static void test_card() {
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            uint16_t c = 0x444;
            bool l = x < 40, r = x >= W - 40, t = y < 40, b = y >= H - 40;
            if (t && l) c = 0xF00;
            if (t && r) c = 0x0F0;
            if (b && l) c = 0x00F;
            if (b && r) c = 0xFF0;
            int dx = abs(x - W / 2);
            if (y >= 50 && y < 100 && dx <= (y - 50) / 2) c = 0xFFF;      // the head
            if (y >= 100 && y < 170 && dx <= 8) c = 0xFFF;                // the shaft
            pic[y * W + x] = c;
        }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string out = "artifacts/lcd", pic_file;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-out") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "-pic") && i + 1 < argc) pic_file = argv[++i];
    }
    dut = new Vngvm_lcd;
    dut->lcd_base = BASE; dut->lcd_on = 1; dut->show = 0; dut->tate = 0;
    dut->rst = 1;
    run(64);
    dut->rst = 0;
    up_n = t_n = 0;                                 // both rasters start at their dot 0
    run(FRAME_UP + 1000);                           // `on` is taken at the frame pulse

    for (int p = 0; p < 2; p++) {
        printf(p == 0 ? "a picture of columns\n" : "a picture of rows\n");
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                pic[y * W + x] = p == 0 ? (uint16_t)((x << 4) | (y & 15)) : (uint16_t)(((y & 0xFF) << 4) | (x & 15));
        show();
        check_frames(1, "clockwise");
        check_frames(2, "anticlockwise");
        check_frames(0, "off");
    }

    printf("the test card\n");
    if (!pic_file.empty()) {
        FILE *f = fopen(pic_file.c_str(), "rb");
        std::vector<uint8_t> rgb(W * H * 3);
        if (!f || fread(rgb.data(), 1, rgb.size(), f) != rgb.size()) { fprintf(stderr, "cannot read %s\n", pic_file.c_str()); return 2; }
        fclose(f);
        for (int i = 0; i < W * H; i++)
            pic[i] = (uint16_t)(((rgb[3 * i] >> 4) << 8) | ((rgb[3 * i + 1] >> 4) << 4) | (rgb[3 * i + 2] >> 4));
    } else test_card();
    show();
    std::string cmd = "mkdir -p '" + out + "'";
    if (system(cmd.c_str()) != 0) return 2;
    tate = 1; run(2 * std::max(FRAME_UP, FRAME_T));
    write_png(out + "/upright.png", grab_up, W, H);
    write_png(out + "/tate_cw.png", grab_t, H, W);
    tate = 2; run(2 * FRAME_T);
    write_png(out + "/tate_ccw.png", grab_t, H, W);

    printf(bad ? "FAILED: %d\n" : "PASS\n", bad);
    delete dut;
    return bad ? 1 : 0;
}
