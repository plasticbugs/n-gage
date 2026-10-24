// The Pocket's host on the APF bridge, for the benches that hold sim/tb_apf.sv
// (sim/tb_slots.cpp, sim/tb_system.cpp).  Call edge() after each rising edge
// of clk_74a: it drives bridge_wr, bridge_rd, bridge_addr and bridge_wr_data
// for the next.
//
// It says all slots are loaded (0x008F) when boot() is called, answers the
// core's "ready to run" (0x0140), polls the target command register and
// answers the target commands as the Pocket does:
//
//   0x0180, a data slot read: "bu", the bytes, a word at a time, to the
//     bridge address asked for, then "ok" with the error code.  The request
//     is checked first: slot 3 (the drive), a span of the image and of the
//     window at 0x04000000, all of it in whole words.  One that is not is a
//     failure of the core, answered with error 2.
//   0x0184, a data slot write: "bu", the slot read back word by word as the
//     Pocket's bridge reads (the address; its answer four clocks later is
//     the read before's; then bridge_rd: sim/tb_system.cpp, --save-out),
//     then "ok".
//
// A word of a transfer every word_gap clocks; the Pocket's own rate is about
// one a microsecond.  With `random` set, everything the Pocket's firmware is
// free to do differently is drawn afresh at each command: whether "bu" comes
// before the read's bytes, whether a request write (0x0082) for the slot
// comes first and an all-complete (0x008F) after, how long after the last
// word "ok" comes (often at once), the gap between words and between polls,
// and now and then an error with no bytes.
#pragma once
#include <cstdint>
#include <cstdio>
#include <deque>
#include <functional>
#include <memory>
#include <utility>
#include <vector>

struct ApfHost {
    // the pins
    uint8_t *wr = nullptr, *rd = nullptr;
    uint32_t *addr = nullptr, *wdata = nullptr;
    const uint32_t *rdata = nullptr;

    // the drive image: its size and its bytes
    uint64_t image_size = 0;
    std::function<uint8_t(uint64_t)> image;
    // a 0x0184's readout: begin, each word as read, end
    std::function<void()> save_begin, save_end;
    std::function<void(uint32_t, uint32_t)> save_word;

    int word_gap = 75, poll_gap = 2000;
    bool random = false;
    int p_err = 4;                      // percent of reads answered with error 2, when random
    uint32_t rng = 0x1234567u;

    // what it saw and did
    uint64_t reads = 0, writes = 0, words_in = 0, words_out = 0, failures = 0, ready = 0;
    uint64_t injected = 0, reqwrites = 0, completes = 0, no_bu = 0, ok_at_once = 0;
    int last_err = 0;                   // the code the last read was answered with
    bool loaded = false;                // its 0x008F has been answered

    void boot() { boot_req = true; }
    void menu(bool on) { menu_req = true; menu_on = on; }
    bool in_cmd = false;                // between a target command seen and its "ok"


    void edge()
    {
        *wr = 0; *rd = 0;               // a pulse is one clock
        if (wait > 0 && --wait > 0) return;
        for (;;) {
            if (q.empty()) plan();
            if (q.empty()) return;
            Op o = std::move(q.front());
            q.pop_front();
            switch (o.k) {
            case ADDR: *addr = o.a; break;
            case PW:   *addr = o.a; *wdata = o.d; *wr = 1; wait = 1; return;
            case PR:   *rd = 1; wait = 1; return;
            case WAIT: if (o.n > 0) { wait = o.n; return; } break;
            case SAMPLE: { uint32_t v = *rdata; nest([&] { o.f(v); }); break; }
            case CALL: nest([&] { o.f(0); }); break;
            case STREAM: {                       // a read's words: o.a the bridge, o.d the image
                uint32_t w = 0;
                for (int b = 0; b < 4; b++) w = w << 8 | image(o.d + b);
                *addr = o.a; *wdata = w; *wr = 1; wait = 1;
                words_in++;
                if (o.n > 1) {
                    q.push_front({STREAM, o.a + 4, o.d + 4, o.n - 1, nullptr});
                    q.push_front({WAIT, 0, 0, gap() - 1, nullptr});
                }
                return;
            }
            case UNLOAD: {                       // a write's word o.d of o.n, its address
                uint32_t k = o.d;                // up 4 clocks: the answer is word k-1's
                if (k) { if (save_word) save_word(k - 1, *rdata); words_out++; }
                if (k == (uint32_t)o.n) break;
                *rd = 1; wait = 1;
                q.push_front({UNLOAD, o.a + 4, k + 1, o.n, nullptr});
                q.push_front({WAIT, 0, 0, 4, nullptr});
                q.push_front({ADDR, o.a + 4, 0, 0, nullptr});
                q.push_front({WAIT, 0, 0, gap(), nullptr});
                return;
            }
            }
        }
    }

private:
    enum Kind { ADDR, PW, PR, WAIT, SAMPLE, CALL, STREAM, UNLOAD };
    struct Op { Kind k; uint32_t a, d; int n; std::function<void(uint32_t)> f; };
    std::deque<Op> q;
    int wait = 0;
    bool boot_req = false, menu_req = false, menu_on = false;
    std::vector<Op> *stage = nullptr;

    static const uint32_t HOST0 = 0xF8000000, TARG0 = 0xF8001000;

    // what a callback queues runs before whatever was queued after it
    template <class F> void nest(F &&f)
    {
        std::vector<Op> s, *was = stage;
        stage = &s;
        f();
        stage = was;
        q.insert(q.begin(), std::make_move_iterator(s.begin()), std::make_move_iterator(s.end()));
    }
    void push(Op o) { if (stage) stage->push_back(std::move(o)); else q.push_back(std::move(o)); }
    void W(uint32_t a, uint32_t d) { push({PW, a, d, 0, nullptr}); push({WAIT, 0, 0, 3, nullptr}); }
    void R(uint32_t a, std::function<void(uint32_t)> f)
    {
        push({ADDR, a, 0, 0, nullptr}); push({PR, 0, 0, 0, nullptr});
        push({WAIT, 0, 0, 4, nullptr}); push({SAMPLE, 0, 0, 0, std::move(f)});
    }
    void Wait(int n) { push({WAIT, 0, 0, n, nullptr}); }
    void Call(std::function<void()> f) { push({CALL, 0, 0, 0, [f](uint32_t) { f(); }}); }

    uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
    int gap() { return random ? 40 + rnd() % 111 : word_gap; }

    // a host command, and its "ok" polled for
    void host_cmd(uint16_t cmd, uint32_t p0, uint32_t p1, std::function<void()> then)
    {
        W(HOST0 + 0x20, p0); W(HOST0 + 0x24, p1); W(HOST0, 0x434D0000u | cmd);
        poll_host(std::move(then));
    }
    void poll_host(std::function<void()> then)
    {
        R(HOST0, [this, then](uint32_t v) {
            if (v >> 16 == 0x4F4B) { if (then) then(); }
            else { Wait(16); poll_host(then); }
        });
    }

    void plan()
    {
        if (boot_req) {
            boot_req = false;
            host_cmd(0x008F, 0, 0, [this] { loaded = true; });
            return;
        }
        if (menu_req) { menu_req = false; host_cmd(0x00B0, menu_on, 0, nullptr); return; }
        R(TARG0, [this](uint32_t v) { target(v); });
    }

    void target(uint32_t v)
    {
        if (v >> 16 != 0x636D) { Wait(random ? 100 + rnd() % 4900 : poll_gap); return; }
        uint16_t cmd = v & 0xFFFF;
        if (cmd != 0x0180 && cmd != 0x0184) {
            if (cmd == 0x0140) ready++;
            W(TARG0, 0x6F6B0000u);
            return;
        }
        in_cmd = true;
        auto p = std::make_shared<std::vector<uint32_t>>(4);
        for (int i = 0; i < 4; i++) R(TARG0 + 0x20 + 4 * i, [p, i](uint32_t x) { (*p)[i] = x; });
        Call([this, cmd, p] {
            auto &v = *p;
            if (cmd == 0x0180) read(v[0] & 0xFFFF, v[1], v[2], v[3]);
            else write(v[0] & 0xFFFF, v[1], v[2], v[3]);
        });
    }

    void read(unsigned id, uint32_t off, uint32_t baddr, uint32_t len)
    {
        reads++;
        int err = 0;
        if (id != 3 || !len || ((off | baddr | len) & 3) || (uint64_t)off + len > image_size
            || baddr < 0x04000000u || (uint64_t)baddr + len > 0x06000000u) {
            printf("FAIL  host: a read of slot %u, %x bytes from %x to bridge %08x: not a span of the drive and its window\n",
                   id, len, off, baddr);
            failures++;
            err = 2;
        } else if (random && (int)(rnd() % 100) < p_err) { err = 2; injected++; }
        last_err = err;
        bool bu = !random || rnd() % 10 != 0;
        int rq = random ? rnd() % 3 : 0;         // 0x0082: none, before, before and 0x008F after
        if (bu) W(TARG0, 0x62750180u); else no_bu++;
        if (rq) { reqwrites++; host_cmd(0x0082, id, len, nullptr); }
        if (!err) push({STREAM, baddr, off, (int)(len / 4), nullptr});
        if (rq == 2) { completes++; host_cmd(0x008F, 0, 0, nullptr); }
        int d = random && rnd() % 2 ? (int)(rnd() % 300) : 0;
        if (!d) ok_at_once++;
        Wait(d);
        W(TARG0, 0x6F6B0000u | err);
        Call([this] { in_cmd = false; });
    }

    void write(unsigned id, uint32_t off, uint32_t baddr, uint32_t len)
    {
        writes++;
        if (id != 4 || off || baddr != 0x20000000u || !len || (len & 3)) {
            printf("FAIL  host: a write of slot %u, %x bytes at %x from bridge %08x\n", id, len, off, baddr);
            failures++;
            W(TARG0, 0x6F6B0002u);
            Call([this] { in_cmd = false; });
            return;
        }
        W(TARG0, 0x62750184u);
        if (random && rnd() % 2) host_cmd(0x0080, id, 0, nullptr);
        Call([this] { if (save_begin) save_begin(); });
        push({ADDR, baddr, 0, 0, nullptr});
        Wait(4);
        push({UNLOAD, baddr, 0, (int)(len / 4), nullptr});
        Call([this] { if (save_end) save_end(); });
        W(TARG0, 0x6F6B0000u);
        Call([this] { in_cmd = false; });
    }
};
