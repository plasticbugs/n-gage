# The core on the Pocket

How NGVM (`docs/hardware.md`, `sw/include/ngvm_hw.h`) maps onto the
Pocket's Cyclone V 5CEBA4F23C8 (speed grade 8), and the budgets it has to
meet. Figures marked *measured* come from a named run. Everything else is
a design target until a bench or the hardware measures it.

## 1. What the core is

```
          +------------------- clk_sys 96 MHz ----------------------------+
 bridge ->| loader --> SDRAM (ROM, RAM, KSEC)   CRAM (drive image)        |
          |               ^ line fills/write-backs   ^ word reads/writes |
          |   +-----------+-----------+              |                   |
          |   | I-cache   | D-cache   |<-- page table (block RAM)         |
          |   +-----+-----+-----+-----+                                   |
          |         |  ARMv4T   |---- devices: timer, IRQ, keys, debug    |
          |         +-----------+---- LCD frame store --> video out       |
          |                     +---- audio FIFO   --> 48 kHz I2S         |
          +---------------------------------------------------------------+
 pad -----> on-screen keypad --> IO_KEYS          LCD --> keypad --> panel --> video out
```

The on-screen keypad (`rtl/ngage_osk.sv`, in `core_top`) sits on both
sides of the machine: the pad reaches `IO_KEYS` through it, and its panel
goes over the LCD's picture before the bring-up panel does (section 2,
"Raster").

The CPU is our own: `rtl/cpu/` (section 5). Its caches use virtual tags
and keep each line's physical page, so the page table is read only on a
miss.

## 2. Clocks

| clock | frequency | drives |
|---|---|---|
| `clk_cpu` | 80 MHz, from a fractional PLL of its own (`target/pocket/cpu_pll.v`); earlier builds ran at 64 and 73.85 MHz, outputs of `core_pll` (section 5.4) | the CPU, caches, page table, devices (`rtl/ngvm_sys.sv`) |
| `clk_sys` | 96 MHz | the SDRAM and CRAM controllers, the LCD (`target/pocket/ngage_mem.sv`, `rtl/ngvm_lcd.sv`) |
| `clk_sdram` | 96 MHz, phase-shifted | the SDRAM pin clock (template, unchanged) |
| `clk_vid` | 6.857 MHz = 96 / 14 | the raster; `pix_sync` pins the dot divider to it (template, unchanged) |

The CPU closes timing alone at 87–91 MHz (section 5.4), not 96, so it has
its own clock. It first came from another output of `core_pll`, which
fixed it to 960 MHz divided by a whole number. Now it comes from a PLL of
its own, whose frequency `core_top` sets with `CPU_HZ`. Either way, the two
sides are timed as asynchronous. Everything between them crosses by a toggle handshake or two
flops; `rtl/ngage_core.sv` lists each crossing and why it is safe.

- **The bus.** `rtl/ngvm_xbus.sv` carries the miss port's one request at a
  time across. The fields are held still from the request to the answer.
  A toggle says when they may be taken, and another says the answer is
  ready.
- **Cost.** A miss pays about three clocks of each side for the crossing,
  on top of the memory's own time.
- **`CPU_HZ`.** `ngvm_io` counts real time by this parameter. It is set in
  `core_top` and must equal the PLL output.

**Raster.** The template's, kept so the Analogizer's 15 kHz path and its
bench need no converter:

- 452 × 253 dots at 6.857 MHz: 59.96 Hz, with lines at 15.17 kHz.
- Visible: 176 × 208, in dots 0–175 of lines 24–231.
- Hsync is on dots 300–331. Vsync is on lines 235–237.
- The LCD's frame pulse (NGVM's vblank) comes at line 232. It sets
  `IRQ_VBLANK`.

**After the LCD**, in `core_top`, all in `clk_sys` and each registered
on the dot enable:

1. **The on-screen keypad** (`rtl/ngage_osk.sv`), when SELECT + R has
   shown it: 72 × 80 pixels from a 1 KB block RAM that
   `tools/make_osk_panel.py` writes (`rtl/osk/`), at dots 52–123 of
   visible lines 124–203, or 4–83 when Y has moved it up. It counts its
   place from the LCD's `de` and `vsync`, looks up the next dot's pixel
   during the current one, and registers it on the dot enable that
   registers the LCD's colour for that dot, so the mux sees the two
   together and both are launched where the SDC's video multicycle
   expects. `sim/run_osk.sh` checks every pixel against the generator.
2. **The bring-up panel** (`rtl/dbg_overlay.sv`), on the bottom sixteen
   lines.
3. The hand-over to `clk_vid`, and the Analogizer, which both take the
   picture with the keypad and the panel on it.

**Input.** The pad (`key1`, so SNAC pads too) goes to the keypad, which
gives `IO_KEYS`, registered: the pad as it is in bits 0-11 while the
keypad is down, nothing of it while the keypad is up, and the keypad's
own keys in bits 12-26 (`docs/hardware.md`, "Keys"). SELECT and R are
held back four frames so that the chord can be told from either alone
before either reaches the machine. `ngage_core` takes `IO_KEYS` into the
CPU's clock through two flops a bit.

## 3. Where each memory lives

| region (NGVM) | size | Pocket resource | access |
|---|---|---|---|
| RAM, `0x20000000` and the paged windows | 32 MB | SDRAM `0x0000000` | cache-line bursts |
| ROM, `0x50000000` | ≤ 20 MB (`SYM.ROM` is 18.6) | SDRAM `0x2000000` | line bursts, read-only |
| KSEC, `0x80000000` | 4 MB | SDRAM `0x3400000` | line bursts |
| *(unused)* | 8 MB | SDRAM `0x3800000` | |
| drive, `0x60000000` | ≤ 32 MB | CRAM0 (16 MB) + CRAM1 (16 MB) | uncached 16-bit words |
| page table | 16,640 × 16 bits | block RAM | one read a miss |
| I-cache, D-cache | 64 KB and 64 KB *(section 4)* | block RAM | every cycle |
| audio FIFO | 1,024 × 32 bits | block RAM | 32–64 ms of sound at 16 kHz |
| LCD frame store | 36,608 × 12 bits, as 32K + 4K | block RAM | written by a copy from SDRAM, read by the raster |

The 64 MB SDRAM cannot hold all of RAM, ROM, KSEC and a drive image. The
drive is the one region only the kernel's drive LDD reads, through
`memcpy` into a buffer, so it goes to CRAM, where uncached word access
costs least.

The seven games first tested unpack to 1.9–14.9 MB. Up to the fourth build
the drive stopped at 24 MB, which 20 of the 51 retail games read from a
phone did not fit: most unpack to 23.8–30.1 MB. The drive now takes all
32 MB of CRAM, which every one of them but two fits (Glimmerati, 53.7 MB,
and Pathway to Glory, 56.8 MB). `tools/mkdrive.py` makes the content plus
2 MB, at least 16 and at most 32. Checked: lockstep with Unicorn over the
first 12 s of Worms World Party on a 31 MB image (575.5 M instructions),
which passes the 3,000 reads the reference makes between 24.7 and 25.8 MB
before the game starts; the 24 MB decode would have aborted the first.

The Pocket's 256 KB SRAM is unused. It is the first place to look if the
kernel's hot data needs a faster home than SDRAM.

**How each request reaches a chip** (`target/pocket/ngage_mem.sv`):

| bus request | SDRAM | CRAM |
|---|---|---|
| line read (32 B) | one 16-halfword burst, from the word asked for, round the line | 16 halfword reads; never asked for (the drive is uncached) |
| line read with a write-back (`BC_RDWR`) | the read's burst, answered, then the write's burst | never asked for |
| line write, masked | one 16-halfword burst, DQM masking each byte | a write per halfword with a byte in the mask |
| word read | a 2-halfword burst | 2 halfword reads |

- **SDRAM.** The controller is the template's, widened to all 64 MB of the
  chip: bank `[25:24]`, row `[23:11]`, column `[10:1]`. A burst issues a
  READ or a WRITE every clock, and each word is caught three clocks after
  its READ.
- **Reads one a clock** (fourth build on; until then the menu's "SDRAM
  fast reads", off). Over the first 20 s of Virtua Cop on
  `sim/run_system.sh`, a line request takes 33-34 memory clocks instead of
  45-47, a bus round trip 32 CPU clocks instead of 41-43, and the CPU
  retires 725,824,799 instructions instead of 673,111,453 (+7.8 %). With
  the memory path of section 4.4, over Sonic N's first 40 s: 1,347 M
  instructions against 1,255 M (+7.3 %), 578 frames shown against 493, a
  bus request 32.7 CPU clocks against 44.8, no memory protocol error
  (frames in `artifacts/system/sonic74fast`). Menu "SDRAM half-rate
  reads" goes back to a READ every two clocks.
- **Which clock catches a word.** The timing analysis checks the capture
  three clocks after the READ. The SDC pairs the chip clock edge that
  launches a word with the core clock edge 14.18 ns later, and in CL2 a
  READ's data is launched by the edge after the one that took it. Up to
  the third build the default caught each word at four clocks, after the
  chip had let go of it. That worked at one READ every two clocks, because
  nothing else drives the bus until the next word. With a READ every
  clock, the next word is already there: every word was off by one, and
  the games crashed at once (second build). At three clocks they play,
  faster (third build, both menu switches on; docs/bringup.md, log). Menu
  "SDRAM read late" goes back to four. The bench's `sim/sdram_model.sv`
  used to put the data a clock later than the chip does, so it passed
  what crashed on the Pocket. It now matches the Pocket: the memory gate
  passes at three clocks, at either pace, and fails at four with a READ
  every clock. Its bus does not keep a word after the chip lets go, so it
  also fails four clocks at the half pace, which the Pocket played.
- **Writes one a clock** (from the build after 0.3.1; until then one every
  two). NBA Jam's core found this pace sound on a Pocket (METHODOLOGY
  5.28). The halfword a WRITE carries is now chosen from the line in the
  same clock, not from a register a clock behind: with the register, the
  memory gate read back 52,676 wrong halfwords at this pace. It passes at
  every combination of read and write pace. Over Virtua Cop's first 1,501
  frames on `sim/run_system.sh` (d7's CPU, the ready-set kernel), a bus
  request takes 31.7 CPU clocks against about 35.7, the CPU retires
  1,225 M instructions against 1,189 M (+3.0 %), and 771 frames are shown
  against 692, with no memory protocol error. Bit 7 of `0xF2000000` goes
  back to two clocks; no menu entry sets it (docs/bringup.md).
- **CRAM.** `target/pocket/cram_ctrl.sv`:
  - asynchronous, with the address multiplexed on DQ;
  - 12 clocks a halfword read and 10 a write, back to back, each with
    margin against the -70 part's limits;
  - a write must fit inside the loader's fastest halfword, 14 clocks,
    or the download queue grows without end: `sim/run_system.sh --gap 7`
    sends a megabyte at that rate and checks every byte;
  - `sim/cram_model.sv` checks those limits cycle by cycle.
- **The LCD's copy.** `IO_LCD_SHOW` (the firmware's screen update,
  `docs/hardware.md`) has the D-cache write its dirty lines back and then
  the LCD copy the 36,608-halfword frame into its frame store, from which
  alone it scans. The copy shares the burst port in bursts of at most 32
  halfwords; the CPU and the LCD take turns when both wait, so a miss
  waits at most one such burst.
- **Copy budget, measured.** A copy takes at most 136,723 clocks, 1.42 ms
  (`sim/run_system.sh`, Virtua Cop's boot at 73.85 MHz), including the
  waits behind the CPU's bursts.
- **Why a copy.** The first flash scanned the framebuffer itself, 60 times
  a second, a line ahead. The picture showed drawing half done, and through
  the write-back D-cache, which wrote back at each vblank and evicted in
  between, a moving picture reached SDRAM a few rows at a time. That is
  the explanation for the combing the first flash showed in Sonic's title
  animations; the second flash tests it.

**Cached or not:**

- Cached: chunk space, the data window, KSEC, ROM and the kernel's 1 MB.
- Uncached: the physical alias at `0x20000000` (contract change, section
  4.2), the drive and the devices.

## 4. Caches

### 4.1 Size, measured

**Method.**

- `ngvm.py --memtrace 40:0.1:FILE` records every fetched block and every
  data access for 0.1 virtual s (10 M instructions), starting at 40 s,
  with keys at 30–36 s. Translated code is flushed when the hooks go in;
  without the flush, code translated earlier ran unseen and the first
  traces showed 2,000 instructions a block.
- `build/cachesim` (`tools/ngvm/cachesim.c`) replays the traces. Its
  model: virtual tags, LRU, write-back and write-allocate for data.
- Figures are misses per 1,000 instructions (I / D / D write-backs).

| trace | data accesses / instr | I 16K DM | I 16K 2-way | I 32K 2-way | D 16K 2-way, 32 B | D 32K 2-way, 32 B | D 16K 2-way, 64 B |
|---|---|---|---|---|---|---|---|
| Virtua Cop, New Game menu | 0.30 | 21.7 | 1.5 | 0.7 | 11.4 / 6.1 | 11.1 / 6.1 | 6.5 / 3.3 |
| Sonic N, character select | 0.44 | 2.1 | 1.4 | 0.8 | 11.4 / 7.0 | 10.8 / 6.8 | 7.7 / 4.8 |
| Super Monkey Ball, Select Mode | 0.10 | 1.0 | 0.6 | 0.5 | 5.9 / 2.7 | 5.7 / 2.6 | 3.5 / 1.5 |
| Bomberman, in a stage | 0.10 | 3.5 | 1.9 | 0.4 | 2.8 / 1.2 | 2.6 / 1.1 | 1.8 / 0.7 |

**Readings.**

- **The I-cache must be 2-way.** Direct-mapped, Virtua Cop's code and the
  libraries it calls evict each other: 22 misses per 1,000 instructions.
- **D misses are streaming.** They barely move from 16 KB to 32 KB, but
  halve with 64-byte lines. Half of them write back a dirty line: buffers
  being filled and copied.

**Decision.**

- I: 16 KB, 2-way, 32-byte lines. Gameplay later made it 32 KB, then
  64 KB (section 4.5).
- D: 16 KB, 2-way, 32-byte lines, write-back; 32 KB, then 64 KB, since
  gameplay was measured (section 4.5). The plan was a one-line
  write-back buffer, so an eviction would not wait in front of the fill.
  The first builds wrote the victim back and then fetched the line. The
  third sends the victim with the fill, to be written after it (section
  4.4).
- Early restart is built (section 4.4). 64-byte lines are the next step if
  the measured CPI needs it.

**Cost.** A miss is about 20–24 cycles at 96 MHz:

- a 32-byte line is a 16-word burst of the 16-bit SDRAM;
- add row activation, CAS latency and the arbiter.

Virtua Cop's 11.4 D misses per 1,000 instructions then add about 0.27
CPI, and its I misses about 0.04.

### 4.2 Correctness with virtual tags

NGVM has one address space, so a virtual tag is unique, with three
exceptions the kernel creates. Each needs a contract change in
`ngvm_hw.h`:

1. **The physical alias.** `pg_alloc` zeroes new pages through
   `0x20000000`, and `proc.c` patches a process's data through it. With a
   write-back cache, those writes would sit dirty under the alias while
   the page is read at its chunk address.

   **Rule:** accesses through `NGVM_PHYS_BASE` bypass both caches.

2. **The data window.** `proc_switch_in` remaps `0x00400000`–`0x007FFFFF`
   to another process without a flush. It does so on every IPC that
   copies to or from another process (`chan.c`).

   **Rule:** a new register `IO_WIN_ID` (6 bits) holds the mapped
   process's window number; the kernel writes it in `proc_switch_in`.
   Cache tags for addresses in the window include it, so each process's
   lines stay valid across switches and never hit for another process.

3. **The low name.** `0x00800000`–`0x01FFFFFF` reaches table entries
   512–2047, which also map `0x40800000`–`0x41FFFFFF` (hardware.md
   section 3: games that keep pointers in 24 or 25 bits).

   **Rule:** the kernel reserves those entries' pages by their low name
   only, so no page is ever cached under both. The reference and the
   lockstep bench map the low name alone, and a use of the high name
   faults there.

Other rules:

- Each line keeps its physical page with its tag, so a write-back never
  reads the table. A line whose page has since been unmapped is written to
  the page it came from. That page is free, and the next `pg_alloc` zeroes
  it uncached after the flush that `vm_decommit` already does.
- `IO_CACHE_FLUSH` writes back and invalidates both caches. The loader
  issues it after writing code.

`ngvm.py` has no caches, so none of this shows there. The lockstep bench
(section 6) runs the RTL with its caches against Unicorn, and a stale line
shows as a divergence.

### 4.3 What a memory request costs, measured

`sim/run_sys.sh --lat L` charges every line read and line write L CPU
clocks, and a word read L/2 + 1. The runs below are Sonic N's first 40 s
at 73.85 MHz, no Unicorn, with the same RTL and kernel `c4369fba...`.
"Work" is the instructions retired outside the idle loop.

| L, clocks a request | work in 40 s | against L = 43 | idle-loop instructions | line reads | line writes |
|---|---|---|---|---|---|
| 2 | 1,176 M | +56% | 375 M | 30.6 M | 11.3 M |
| 12 | 1,035 M | +37% | 317 M | 27.3 M | 9.5 M |
| 22 | 920 M | +22% | 317 M | 24.1 M | 7.7 M |
| 32 | 829 M | +10% | 317 M | 21.7 M | 6.4 M |
| 43 | 756 M | | 317 M | 19.4 M | 5.5 M |

**L = 43 is the Pocket.** `sim/run_system.sh` on the real memory glue
measures 43 CPU clocks a bus request. Over the same 40 s it retires
1,083 M instructions in all, against 1,073 M here at L = 43.

**The time per instruction is linear in L.** Each instruction of work
takes 33.6 + 0.449 L ns of the 40 s. That line, fitted to L = 22 and 43,
predicts L = 12 and L = 2 within 1.5%. At L = 43, 37% of the time scales
with the latency. Even memory that answered at once would give at most
+56%: the rest is the CPU itself, its clock and its CPI.

**Readings for each change:**
- A change is worth what it takes off the CPU's effective L.
- Hiding every write-back (22% of requests) would make L about 34: +8%.
- Fast reads, if they could be made sound (they were: section 3), cut
  the memory side from 47 to 34 clocks, so L about 32: +10%.
- Early restart lets the CPU go on at the first word, about 20 clocks.
  The rest of the line still arrives behind it, so the effective L is
  more like 25–30: +12–17%.
- Together they might reach L about 15–20: +25–35%.

### 4.4 Critical word first, early restart, the write-back behind the fill

The third build changes how a miss is served, not what it costs the
memory.

- **The line comes from the word missed on.** The miss handler sends the
  word's address with the line read. With BL=1, a burst is a run of single
  READs, so `sdram_ctrl` simply starts at that column and wraps within the
  16 halfwords (`b_wrap`). `b_idx` then names each halfword's place in the
  line.
- **Words cross as they come.** `ngage_mem` counts each word a clock after
  it lands in `m_rdata`, in Gray code, and `ngvm_xbus` brings the count
  across on two flops. A word the count has passed stands until the next
  request is taken, so the CPU side may read it. That is the same argument
  that makes the held answer safe (`ngvm_xbus.sv`).
- **The caches write each word as it arrives**, instead of copying the line
  out after the answer, which took eight clocks.
  - The I-cache answers a fetch from the incoming line once its word was
    written before the edge that read the RAM, so the CPU runs down the
    line as it comes.
  - The D-cache compares a waiting load again every cycle while the line
    comes in. A hit on another line, or the incoming line's word once it
    is in, answers it.
  - Stores, devices, uncached accesses and a second miss wait for the line.
- **A dirty victim goes with its fill** (`BC_RDWR`). The memory reads the
  new line, answers, then writes the victim. The next request, and the
  LCD's copy, wait for that write (`m_free`). If the fill faults, the
  victim goes out alone first.

**Measured, the lockstep bench** (`sim/run_sys.sh --lat 43 --no-uc`, Sonic
N's first 40 s, the same kernel as section 4.3):

- Words arrive as the Pocket's do: the first at 2/5 of the latency, the
  last at 9/10.
- A write-back keeps the memory busy for 3/4 of the latency after the
  answer.
- Result: 926 M instructions of work, against 756 M before (+22.5%). That
  is what the old design did at L = 22. The idle loop is unchanged.
- 94% of line writes now go out behind a fill.

**Measured, the whole machine** (`sim/run_system.sh`, the real memory glue
and controller, Sonic N's first 40 s): 1,255 M instructions against
1,083 M (+16%, idle loop included), and 493 frames shown against 337
(+46%). No memory protocol errors.

**Checked:** lockstep with Unicorn over Sonic N's first 20 s, Virtua Cop's
first 15 s, Bomberman's and Super Monkey Ball's first 15 s; the memory gate
(`sim/run_mem.sh`) with each word checked as it is counted and 2,000 fills
with write-backs, at every read pace.

### 4.5 Gameplay, measured

The traces of section 4.1 were taken in menus. Gameplay traces show
something different.

**Method.**

- `ngvm.py --memtrace 85:0.3:FILE` records 0.3 virtual s of Virtua Cop and
  of Tony Hawk's Pro Skater, both in play, with a key pressed every 2 s.
- `cs3`/`cs4`, scratch models built on `cachesim`, replay each trace with
  a crude timing model:
  - the core's CPI with ideal memory is 1.6;
  - a line takes 33 CPU clocks, and its first word arrives at 13;
  - a write-back keeps the memory 16 clocks more;
  - translation adds 5 clocks.
- Figures are modelled cycles per 1,000 instructions.

| change, Virtua Cop / Tony Hawk | I misses per 1,000 | modelled cycles |
|---|---|---|
| I-cache 16 → 32 KB | 8.88 → 4.19 / 5.88 → 3.63 | −5.8% / −2.5% |
| a store miss completes once its fill is on the bus | | a further −3.7% / −5.3% |
| D-cache 16 → 32 KB | | −2.7% / −3.6% |
| D-cache 4-way | | about −0.8% more |
| next-line prefetch on every D miss, or tagged | | +3.7% to +6.5%, or within 0.6% |
| write-validate: a store miss fetches nothing, a load merges | | −0.5% |

**Readings.**

- **The I-cache matters more in play.** At 16 KB, Virtua Cop missed 8.88
  times per 1,000 instructions in play, against 1.5 in its menu.
- **Prefetch loses.** The bus takes one request at a time, and about 45%
  of prefetched lines are never used. Each unused line holds the bus
  against a real miss.
- **Write-validate is not worth its complexity.** Stores that miss are
  already off the critical path.

**Built:**

- I-cache 32 KB (`rtl/ngvm_icache.sv`).
- A store miss completes once its fill is on the bus (`m_xok`).
- A dirty victim is read out during the translation, beside the fill.
- The valid bits are in the tag RAMs (`rtl/ngvm_dcache.sv`).

The commits that made each change give its lockstep runs.

**Second round, on the RTL.** The cache model leaves out the pipeline, so
the next sizes were measured on the RTL itself.

- `ngvm.py --save-at 85:FILE` saves a reference checkpoint 85 s into each
  game, in play. `tb_sys --restore FILE` starts the system bench there.
- Each build runs at 80 MHz with a line costing 36 CPU clocks, and the
  bench profiles 86–89 s.
- A checkpoint holds the kernel's own data, so a run must use the kernel
  that made it.
- Single-change variants on d5 were profiled over 86–91 s:
  - BTB 512: +1.2% on Virtua Cop, +0.6% on Tony Hawk.
  - I-cache 64 KB: +5.2% and +2.4%.

| build | Virtua Cop: instructions, CPI | Tony Hawk | line reads, 85–89 s |
|---|---|---|---|
| d5: I 32 KB, D 16 KB, BTB 256 | 126.1 M, 1.889 | 115.9 M, 2.070 | 2.33 M / 3.13 M |
| d7: I 64 KB, D 32 KB, BTB 512 | 137.4 M (+9.0%), 1.730 | 125.1 M (+7.9%), 1.918 | 1.74 M / 2.68 M |
| d10: d7 and the MMU's trims (`4a96437`) | 138.0 M, 1.722 | 125.9 M, 1.906 | |
| d10, a write-back keeping the memory 14 clocks, not 27 | 139.9 M (+1.4%), 1.698 | 128.3 M (+1.9%), 1.870 | |
| d11: d10 and D 64 KB | 140.4 M (+1.7%), 1.691 | 130.5 M (+3.7%), 1.839 | |
| d13: d10, the BTB read as asked, an 8-bit tag (section 5.6) | 137.1 M | 125.1 M | |
| d14: d13 with a 16-bit tag | 137.3 M | 125.8 M | |
| d15: d14 and the multiplier's first stage at the edge into A (section 5.3) | 139.0 M | 127.3 M | |
| d16: d15, D 64 KB with its dirty bits in block RAM, and the BTB's stale entry ignored (section 5.6) | 141.5 M (+3.1% on d14), 1.679 | 132.1 M (+5.0%), 1.816 | |

- **Where it came from.** On Virtua Cop, F2's waits on the I-cache fell
  from 0.079 to 0.027 cycles per instruction, and the cycles with the whole
  front end empty fell from 0.161 to 0.080. Tony Hawk is memory-bound: M
  still waits 0.412 cycles per instruction, 0.226 of them for a load's own
  line.
- **Checked.** d7 ran in lockstep with Unicorn from both checkpoints,
  without a difference: Virtua Cop to 87 s (93.0 M instructions) and Tony
  Hawk to 86.5 s (61.6 M). It also ran from power-on through 20 s of
  Virtua Cop (1,008 M).
- **The write-back's 14 clocks** model a burst's WRITEs one a clock
  (section 3) with the bench's `--wb 14`; the default, 27, is three
  quarters of a line read.
- **D 64 KB pays most on Tony Hawk**, where M's waits for a load's own line
  fall from 0.224 to 0.178 cycles per instruction. Its fit failed in the
  whole core (section 5.4, E).
- **d13 against d10** is the price of reading the BTB before A's redirect
  commits (section 5.6): about 0.6% on both games. That is no more than
  timing alone moves the games' own states in this window, so only its
  sign is read. 16 tag bits win back Tony Hawk's share, not Virtua Cop's.
- **d16's memory waits are d11's** to the third decimal, M's for a load's
  own line 0.178 on Tony Hawk and 0.118 on Virtua Cop: the dirty bits'
  move to block RAM (section 5.4, G) changed nothing the bench can see.


## 5. The CPU

### 5.1 Why our own

ZAP (github.com/krevanth/ZAP, ARMv5TE, GPL-3) was the only open candidate.
Quartus 18.1, the version the Pocket's toolchain uses, cannot build it:

- As SystemVerilog, its type parameters, `inside` and `foreach` are
  rejected.
- Converted with `sv2v`, with 16 KB caches, `quartus_map` exhausted
  7.6 GB.
- Converted with 8 KB caches, it was still elaborating the TLB after 12
  hours.

It also carries a full ARM MMU and ARMv5 behaviour, neither of which NGVM
wants. No open ARM7TDMI exists in Verilog.

### 5.2 Requirement, measured

At 100 virtual MIPS (`ngvm.py`, 60 s, keys at 30–36 s), mean busy MIPS
was:

| game | mean busy MIPS |
|---|---|
| Puzzle Bobble | 12.6 |
| Bomberman | 16.9 |
| Snakes | 20.1 |
| Puyo Pop | 32.8 |
| Super Monkey Ball | 33.4 |
| Sonic N | 60.1 |
| Virtua Cop | 68.4 |

The 3D games render as fast as the CPU allows. Virtua Cop's 60 s gave
6,769, 4,407 and 2,730 screen updates at 100, 70 and 50 MIPS. At 50 and 70
MIPS both games reach the same screens, so a slower CPU costs frame rate,
not correctness.

**Target.** At least the phone's own speed, and more where it is cheap.

The phone's CPU is an ARM9TDMI-class core at 104 MHz, with no branch
prediction:

- taken branches cost 3 cycles;
- a load-use costs 1 cycle;
- LDM/STM move one register a cycle.

That is the same CPI as this pipeline without a branch target buffer,
about 1.86 on game code with ideal memories (section 5.5). Add cache
misses, and the phone delivered roughly 45–50 MIPS, not 100.
`ngvm.py`'s 100 MIPS is a reference speed, faster than the phone.

An earlier draft set the target at 70 MIPS (CPI ≈ 1.35 at 96 MHz, caches
included). That was a reading of the table above, not of the phone. It
is kept as a stretch goal: each MIPS above the phone's is frame rate in
the 3D games.

### 5.3 Pipeline

Eight stages. Each starts from registers.

| stage | work |
|---|---|
| F1 | next PC → instruction memory address; the BTB, read in the same cycle, picks the next PC (section 5.6) |
| F2 | instruction word back (or not: the fetch is replayed); into a 4-entry ring buffer |
| D1 | from the buffer's read pointer: Thumb → ARM expansion; predecode (B/BL, Thumb BL prefix, LDM/STM, SWP, long multiply; the first LDM/STM register and the list's length) |
| D2 | decode; register read by the instruction's fields; IRQ injection; redirect for B, BL and a Thumb BL pair the BTB did not predict |
| S | forwarding from M's and W's registered results, selected by match tags; barrel shifter |
| A | late forwarding of unshifted operands; ALU, multiply, flags, CPSR/SPSR, addresses; conditional B, BX, exceptions, MSR redirect |
| M | data memory; load align and extend; redirect for ALU writes to PC and a Thumb BL suffix D2 did not catch |
| W | register write; redirect for loads to PC; retirement |

- **Thumb:** expanded in D1 to the equivalent ARM operation, so the rest
  knows only ARM. The BL pair is two instructions. D2 remembers the
  LR the prefix computes and redirects on the suffix.
- **Fetch:** F1 fetches only while the buffer can take everything in
  flight, so the front end reads only registered state.
- **Register read:** five ports, one each for Rn, Rm, Rs, Rd and the
  LDM/STM register. They are indexed straight from D2's instruction
  register, so the read runs in parallel with the decode. The decoder
  only picks which port each operand takes.
- **Operands S cannot see:** the result of the uop in A.
  - An operand only A needs (unshifted register, base, store data, an
    accumulator) is marked and picked up in A from M or W.
  - If the uop that was in A turns out not to execute, A falls back to
    the load that was in M, if there was one, or else to what S had.
  - An operand S itself needs (one to shift, a shift amount, a
    multiplier input) waits in S until it is registered.
  - A load's value is registered only at W.
- **Match tags:** each operand reaches S with six flags saying whether
  the uop in A, M or W writes its register, through either write port.
  They are worked out a cycle ahead, as the uop enters S or while it
  waits there, from where the uops will be next cycle. So forwarding
  and the stall start from flops, not from 5-bit compares. The Verilator
  build checks them against the compares on every cycle.
- **Multiply:** two stages of DSP blocks. The first takes S's operands
  at the edge that moves the multiply into A; they are final there,
  because a multiplier input waits in S until it is registered. The
  second runs in A's first cycle, and A adds the accumulator and
  finishes in its second, so a multiply holds A one cycle. Until d15
  both stages ran in A, which held two. On the bench (section 4.5,
  86-89 s) the multiplier's waits fell from 0.053 to 0.026 cycles per
  instruction on Tony Hawk and from 0.040 to 0.020 on Virtua Cop, and
  each game ran 1.2% more instructions.
- **Shift by a register:** one extra cycle in S. The amount settles
  into S's own copy of Rs, so the shifter's amount does not come
  through the forwarding mux. Measured cost: under 0.001 CPI.
- **Shifter:** one right rotator for every type. LSL n is a rotate by
  32 − n with the low bits cleared; LSR and ASR fill the top. The mask,
  fill and carry select come from the registered type and amount.
- **Costs, in cycles:**
  - redirect from D2: 3; from A: 5; from M: 6; from W: 7;
  - load-use: 1 for an unshifted use, 2 for a shifted one;
  - a shift by a register: 1;
  - a branch the BTB predicted correctly: 0 (section 5.6).
- **Kills** clear valid bits only; data registers load whenever the next
  stage has room.
- **Multiplies:** DSP blocks, 2 cycles in A; the long forms take an
  extra cycle for the high word.
- **LDM/STM:** D2 issues one register per cycle.
- **Exceptions:**
  - entered in A for SWI, undefined and IRQ, and in M for data aborts;
  - by flushing the younger stages, then switching mode, banking LR and
    SPSR, and jumping to the vector.
  - IRQ is injected in D2 between instructions, never between the
    halves of a Thumb BL.
- **Coprocessors and FIQ:** no coprocessor; MCR, MRC, CDP, LDC and STC
  take the undefined-instruction trap. FIQ is not wired.
- **Unaligned LDR:** rotates as ARMv4 does. Unaligned STR stores the
  aligned word. Unicorn does neither, so the random tests avoid
  unaligned word accesses (section 6).

### 5.4 Timing, measured

The CPU is synthesised on its own, as ZAP was, before it joins the core:

- Quartus 18.1, 5CEBA4F23C8;
- every port registered, constrained to 10.417 ns (96 MHz);
- `OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"`.

The figures are the slow 85 °C corner, the worst of the four.

**Six stages: 61.2 MHz.** 4,258 ALMs, worst setup slack −5.92 ns. The clock
reaches the registers at about 4.3 ns, leaving 15.4 ns paths of data, and
both long stages carried one:

- **E** (9 levels plus the carry chain): forwarding mux, 2.1 ns →
  barrel shifter, 3.3 → offset/operand mux, 3.3 → 32-bit add, 2.5 →
  result mux.
- **D** (13 levels): Thumb expansion, 4 → LDM/STM register-list decode,
  5 → `d_take` → the D word mux, 4.5.

Each was about one and a half stages of logic, so the pipeline became
the eight stages of section 5.3. The six-stage version passed the same
lockstep runs (section 6).

**Eight stages, step by step.** Each row is one fit, with Quartus's
default seed, of the RTL with that change. It names the paths that led
to the next change:

| change | Fmax | worst slack | ALMs | the worst paths after it |
|---|---|---|---|---|
| eight stages | 90.38 MHz | −0.647 ns | 4,534 | decode → register-read mux; kill → data enables |
| registers read by field; kills only on valid bits | 85.79 MHz | −1.239 ns | 4,920 | S: forward → shift amount → shifter; D2: the decoder re-deriving the LDM register |
| D2 takes D1's LDM register; a shift by register waits a cycle | 89.67 MHz | −0.735 ns | 5,147 | S: 5-bit operand compares → stall → hold mux |
| match tags (section 5.3) | 91.12 MHz | −0.558 ns | 5,346 | S: forward → shifter → op2; D2: the LDM offset's three adders |
| list length counted in D1, offsets in 8 bits | 90.01 MHz | −0.693 ns | 5,140 | S: forward → shifter, 5 levels of it |
| one rotator for every shift | 96.0 MHz | 0.000 ns | 5,094 | met with this seed; see below |
| register indices, mode and LDM's last step from D1 | 94.61 MHz | −0.153 ns | 4,822 | the stall: M's hold → `a_free` → every stage's enables |

**One seed is not a measurement.** The rotator's RTL with three other
seeds:

| seed | Fmax | worst slack | worst paths |
|---|---|---|---|
| 1 (default) | 96.0 MHz | 0.000 ns | D2: the LDM register → its bank → read port → S |
| 2 | 90.27 MHz | −0.661 ns | D2: field → register index → read mux → S; D2: LDM `rem − 1` → last step → D2's enables |
| 3 | 87.78 MHz | −0.975 ns | A: CPSR's mode → next CPSR → D2's register indices |
| 4 | 89.33 MHz | −0.778 ns | |

- **Spread:** about 8 MHz from seed to seed, so a difference between
  two single fits in the table above means little. Only the large
  moves can be read as real: six to eight stages, the match tags, and
  the rotator.
- **Over-constraining does not help:** the same RTL fitted against
  105 MHz reached only 91.8 MHz.
- **The next change**, the last row of the table above, removes the
  paths that seeds 1–3 named:
  - the five register-file indices are computed in D1, in the mode of
    that moment, and D2 decodes in a registered copy of that mode;
  - "another LDM/STM step follows" is a flop, set from the list's
    nibbles without an adder.

  Every change of mode (MSR to the control field, an exception, a
  return from one) redirects and so kills D2, so no uop that survives
  sees a stale mode.
- **These fits ran with Quartus's parallel processors**, and each took
  about 7 CPU-hours (54 minutes) under the container's amd64 emulation.
  With `NUM_PARALLEL_PROCESSORS 1` the same flow takes 5 to 9 minutes.
  The parallel workers also once hung in analysis and synthesis for
  10.6 hours at 3% CPU. The fits below use one processor.

**That change, over the same four seeds:**

| seed | Fmax | worst slack | ALMs |
|---|---|---|---|
| 1 | 94.61 MHz | −0.153 ns | 4,822 |
| 2 | 98.36 MHz | +0.250 ns | 4,749 |
| 3 | 98.48 MHz | +0.263 ns | 4,855 |
| 4 | 95.61 MHz | −0.042 ns | 4,868 |

- **Median:** 97.0 MHz against 89.8 before. Two seeds meet 96 MHz and
  the other two miss by under 0.16 ns.
- **Hold:** every seed meets it at all four corners, the worst by
  0.138 ns.
- **Size:** about 4,100 registers and 3 DSP blocks.
- **Seed 1's worst path is the stall:** M's hold → `a_free` → the
  enables of every stage, down to D1's buffer shift. Here `dc_ok` is a
  flop. Behind a real data cache it would come from a tag compare in
  the same cycle, so the caches (section 4) should make a miss a
  replay, not a stall: M flushes, and the instruction re-issues after
  the fill. Then no enable waits on a compare.

**The processor count is a seed too.** The same RTL fitted with one
processor gives a different result from the fit with several, so the
two sets of numbers cannot be mixed. Every row of this table uses one
processor:

| seed | the RTL above | with the BTB (section 5.6) |
|---|---|---|
| 1 | 100.64 MHz, +0.481 ns | 87.21 MHz, −1.049 ns |
| 2 | 87.53 MHz, −1.008 ns | 90.60 MHz, −0.621 ns |
| 3 | 100.11 MHz, +0.428 ns | 89.61 MHz, −0.742 ns |
| 4 | 100.53 MHz, +0.470 ns | 87.86 MHz, −0.965 ns |
| median | **100.3 MHz** | **88.7 MHz** |
| ALMs, registers | about 4,830, 4,090 | about 5,060, 4,430, and 3 M10K blocks |

- **The BTB costs about 11 MHz** of median, and no seed reaches 96 MHz
  with it.
- **It is still faster.** Instructions per second are Fmax over CPI:
  88.7 MHz at CPI 1.59–1.66 is 53–56 MIPS, against 100.3 MHz at
  2.12–2.21, which is 45–47 MIPS (section 5.5, ideal memories).
- **Hold** is met on every fit, the worst by 0.123 ns.
- **The first BTB build** gave 86.82, 92.25, 86.49 and 90.37 MHz (median
  88.6). Each seed named a different path the BTB had added:
  - the return stack's repair, from the decoder and from A's result
    mux;
  - the BTB's write data, from A's late forwarding;
  - D2's handshake into the instruction buffer, which now shifted the
    prediction too.

  Each was removed (section 5.6), and the median did not move. After
  that, the failing paths are spread across the pipeline:

  | endpoint | slack |
  |---|---|
  | decode into S | −0.62 ns |
  | A's operand | −0.64 ns |
  | D2 | −0.09 ns |
  | the BTB's read address | −0.01 ns |

  So the remaining loss is placement pressure, not one path.
- **The caches** (section 4) restructure F and M next. Timing is closed
  on the integrated core, where the CPU can have its own clock
  (section 2).

**In the whole core, measured.** The project now uses
`OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"` and the CPU has its own PLL
output (section 2). The first full fit at 80 MHz:

- 13,568 of 18,480 ALMs (73 %), 15,705 registers.
- **`clk_cpu` missed by 2.226 ns** at the hot slow corner (2.124 cold),
  −407 ns in total: about 68 MHz. Every other clock met.
- **All 200 worst paths had one shape:** the D-cache's compare to the
  return stack, at −2.23 to −1.95 ns. The valid bits were indexed by the
  request address in the compare cycle, a 256-to-1 mux of 4.8 ns. The
  hit then went into M's stall and abort, and from those into
  `a_redirect` and `m_redirect`. Those chose which return address
  repairs the stack, and Quartus put that choice in front of the
  `pc + 4` adder: another 2.7 ns. The CPU alone had been timed with
  `dc_ok` as an input port, so no path from the compare existed there.
- **The fix, first step.** The valid bits were read whole at the edge
  before the compare, as the tags are (`rtl/ngvm_dcache.sv`). Each case's
  return address was computed into a flop as its instruction enters D2
  or A (`rtl/arm_cpu.sv`). Over 12 s of Virtua Cop in lockstep the CPU
  retired the same 541,985,611 instructions in the same 960 M cycles,
  with the same bus traffic, as before the change.

  The fit: −0.305 ns hot, −0.394 cold (78.1 MHz). The 256-to-1 mux now
  sat behind the CPU's address adder: an operand from late forwarding,
  `base + offset`, then the mux into `v0q`. Its twin `v1q` made
  +0.077 ns. The only other failures were 45 ps and 1 ps.
- **Second step.** The edge before the compare reads the 16 sets that
  address bits [12:9] pick. The compare picks its own set from those with
  `r_va[8:5]`, beside the tag compare. The same 541,985,611 instructions
  in lockstep. The fit: −0.619 ns hot, −0.374 cold. The worst path now
  runs from the 16-to-1 mux behind those flops through the hit, A's
  stall (`a_free`, 557 loads) and the return stack's write enable, and
  two more groups miss by 0.2–0.3 ns: the BTB's read address (from the
  CPSR's T bit through `f1_pc_n` and `a_redirect`) and the I-cache's
  valid bits (from the D-cache's walk through `inv_i`). Three unrelated
  groups at once is placement pressure at this clock, not one path.
- **73.85 MHz (960 / 13) instead.** The PLL's other outputs fix the VCO
  at 960 MHz, so the clocks within reach are 80, 73.85 and 68.57 MHz.
  The fit at 73.85: setup met on every corner, +0.344 ns the least
  (Fmax 77.96 MHz cold, 79.44 hot). Hold missed by 0.019 ns at the fast
  0 °C corner, on the BTB's write data into its block RAM's input
  register, which `OPTIMIZE_HOLD_TIMING "ALL PATHS"` did not pad enough.
  The BTB only predicts, and every prediction is checked, so a wrong
  bit there costs a misprediction, not a wrong result. Even so, that build
  was not flashed. The next fit, the same CPU with the LCD's frame store
  and the fast-reads switch added (section 3), met every clock on every corner:
  +0.653 ns setup on `clk_cpu` the least, +0.079 ns hold on it the least.
  Nothing was done for the hold path; the new placement moved it. A later
  fit may miss it again, and the BTB's write data is the first place to
  look. The second flash is that fit. The real clock is 73.89 MHz,
  the VCO being fractional off 74.25 MHz; `CPU_HZ` is 73,846,154, 0.06 %
  slow for the timer and the audio FIFO's pace.
- **The first flash runs the CPU at 64 MHz** (960 / 15) on the RTL before
  either step. That fit met every clock on every corner: `clk_cpu` with
  +0.993 ns hot (Fmax 68.4 MHz), and +0.109 ns the least anywhere.

**80 MHz, on a PLL of its own.** The CPU side is asynchronous to the
memory side (section 2), so its clock need not divide `core_pll`'s VCO.
`target/pocket/cpu_pll.v` is a fractional PLL for the CPU alone, and
`core_top` sets its frequency together with `CPU_HZ`. Each fit below used
one processor and the default seed. `projects/report_worst.tcl` named the
failing paths, which were then grouped by their end registers.

| fit | what changed | `clk_cpu` setup slack, 85 °C / 0 °C | what failed |
|---|---|---|---|
| d2 | the I-cache at 32 KB, stores that complete on the bus, the victim beside the fill (section 4.5), returns by load predicted (5.6); 80 = 960 / 12 on `core_pll` | −0.434 / −0.427 ns | CPSR → M's operand; M's redirect → the instruction buffer's handshake; the return stack's repair; D1's LDM figures |
| d3 | the d2 families taken off (commit `cacf15d`); `cpu_pll` | −1.143 / −1.031 ns | all into W's load result `w_ra`: a device read through the IO decode, and the cache RAMs through the hit |
| d4 | device reads and region aborts answered from a register in `S_DONE`, a cycle later; an abort's link through port B | −0.388 / −0.615 ns | RAM → `w_ra`; `w_ra` → CPSR's Z (−0.22); RAM → the instruction buffer, which Quartus had made a block RAM (−0.15); RAM → F1's PC through an abort (−0.11) |
| d5 | each way's word aligned and sign-extended before the way is chosen; Z without the carry chain; the buffer as plain vectors | −0.050 / +0.088 ns | two paths: the instruction buffer → the LDM register count → `d2_nregs` |
| d6 | the count from the bytes (below); the I-cache at 64 KB, the D-cache at 32 KB, the BTB at 1,024 entries (section 4.5), each cache's LRU bits still flops: 93% of the ALMs | −0.543 / −0.457 ns | F1's next PC → the BTB's read address, across 1,024 entries' blocks; A's operands → CPSR's Z; the flush walk's set `ws` → the D-cache's dirty bits |
| d7 | the BTB at 512; each cache's LRU bits in a block RAM, read beside the tags; the flush walk's clear of every dirty bit taken out: 77% of the ALMs | +0.273 / +0.425 ns | nothing: every clock met on every corner, holds included |
| d11 | d7 with the D-cache at 64 KB, its dirty bits still flops: 83% | −0.364 / −0.222 ns | the walk's set `ws` → `dty[ws]`, a 1,024-to-1 mux → the tag RAM's write data; the BTB's read address (−0.315) |
| B | d7, the MMU's trims and the on-screen keypad: 74% | −0.263 / −0.171 ns | the D-cache's tag RAM → its hit → `dc_ok` → M's hold → A's commit → A's redirect → `f1_pc_n` → the BTB's read address; a data abort the same way (section 5.6) |
| C | B with the BTB read from the redirects as asked, `f1_bi`, and an 8-bit tag: 73% | +0.176 / +0.348 ns | nothing; the least, the walk's `ws` and dirty bits → the tag RAM's write data |
| D | C with a burst's WRITEs one a clock (section 3) and a 16-bit tag: 72% | +0.425 / +0.260 ns | nothing, holds +0.123 the least; the least setup, the D-cache's `r_va` and tag RAM → A's `a_op2`, and the instruction buffer → `d2_ub` |
| F | D with the multiplier's first stage at the edge into A (section 5.3): 74% | +0.463 / +0.607 ns | nothing, holds +0.124 the least; no path into the multiplier among the worst; the least, the walk's dirty bits → the tag RAM's write data, and S's match tag `s_ta.m_wa` → M's target and the BTB's write queue |
| G | F with the D-cache at 64 KB, its dirty bits in two block RAMs, and the BTB's `bmis` (section 5.6): 63%, 276 RAM blocks | +0.222 / +0.061 ns | nothing, holds +0.125 the least; the least setup, the tag RAM's write enable → the data RAM's, and the D-cache's `r_va` and D2 → S's uop |
| E | D with the D-cache at 64 KB, dirty bits flops: 84%, 274 of 308 RAM blocks | −0.497 / −0.648 ns; `core_pll` −0.391 | everywhere: D2 → S's uop, the SDRAM's `dram_dq` → `dq_in`, the D-cache → its data RAM's write enable, A → CPSR, the dirty bits → `dsome` |

- **Z without the carry.** `x + y + ci` is zero exactly when
  `x ^ y == {(x | y)[30:0], ci}`, because each sum bit is zero only if the
  carry into it is `x ^ y` at that bit, and the carry out is then
  `x | y`. The identity was checked on 2,000,128 random and edge cases, and
  it takes the 32-bit carry chain out of the flags.
- **d5's families, against d4.** `w_ra` went from −0.615 to +0.256 ns
  cold, CPSR to +0.49, the buffer to +0.83 and F1's PC to +1.21. Quartus
  still made part of the buffer a block RAM, despite the attribute, but
  its paths now pass.
- **Cost.** d4's and d5's D-cache changes add a cycle to device reads and
  to region aborts only. On the CPU bench, with ideal memory over Virtua
  Cop's first 3 virtual s, d5 retires the same instructions in the same
  97,420,197 cycles as d3.
- **The count.** d5's last two paths are the LDM/STM register count beside
  each buffer entry: Thumb's halfword mux, its list mux, then a 16-bit
  popcount, 12.3 ns. It is now the popcount of the word's bytes, straight
  from the flops, with one small add after.
- **d6 to d7.** As flops, the LRU bits were 1,536 registers, each with a
  write decoder, and a 1,024- or 512-way mux on the fetch and load
  addresses. A wrong LRU bit only picks a worse victim, so a block RAM
  read beside the tags serves; a write at the edge of the read is not
  seen. The RAMs freed 2,890 ALMs (17,133 → 14,243). The flush walk's bulk
  clear was redundant, since the walk writes back every dirty line and each
  write-back clears its own bit. Nothing was changed on CPSR's paths; they
  passed in the emptier fit.
- **E, crowded.** Its failures share no logic: the SDRAM's capture is on
  the memory clock, far from the D-cache. That is a full device placing
  badly, as d6 was, not one path. The 2,048 dirty bits as flops, each with
  a write decoder and a 1,024-to-1 mux behind it, go to a block RAM next,
  as the LRU bits did for d7.
- **G, the dirty bits in RAM.** One 1,024 × 1 RAM per way, read beside
  the tags, or during a walk a set ahead, so a clean set still takes one
  cycle. Each is written once a cycle at most: a store hit, a fill's last
  word or a write-back's end, or the sweep. A store into the line coming
  in waits out the edge the fill ends at. A wrong bit loses a line, so
  the write that lands at the edge of a read is kept in flops and put
  over what the read returns. G uses 2,036 fewer ALMs than F, though its
  D-cache is twice the size. That is what the 1,024 dirty flops of 32 KB
  cost, with their write decoders and 512-to-1 muxes.

### 5.5 Where the cycles go, measured

`sim/run_cpu.sh` (sections 6 and 8) tallies each cycle by what the
pipeline is doing:

- the first 15 virtual seconds from power-on of each game (Bomberman: 30),
  which covers boot, loading and the menus;
- ideal memories: every access answers in one cycle.

**Eight stages**, the RTL of section 5.3, per instruction:

| per instruction | Virtua Cop | Bomberman (30 s) | Sonic N |
|---|---|---|---|
| CPI | 2.205 | 2.213 | 2.121 |
| MIPS at 96 MHz | 43.5 | 43.4 | 45.3 |
| extra LDM/STM/SWP/long-multiply uops | 0.232 | 0.245 | 0.196 |
| S waits on an operand | 0.128 | 0.163 | 0.226 |
| multiplier waits | 0.001 | 0.009 | 0.054 |
| redirects from D2 (× 3 cycles) | 0.045 | 0.050 | 0.035 |
| redirects from A (× 5): conditional B, BX, SWI, MSR | 0.133 | 0.122 | 0.101 |
| redirects from M (× 6) and W (× 7) | 0.012 | 0.010 | 0.009 |

The rows overlap a little, because a redirect can land during a wait, so
they add up to slightly more than the CPI.

**Six stages**, for comparison: CPI 1.857, 1.856 and 1.769, with 0.502,
0.483 and 0.383 of it lost to branches, but only 61 MHz, so 32.8 MIPS on
Virtua Cop. The eight stages pay 0.35 CPI more, mostly in longer
redirects, for 57% more clock.

**Branch prediction.** The bench also replays each retired branch through
models of the predictors it could have (`sim/cpu/bpred.h`). The model:

- direct-mapped and indexed by PC;
- 2-bit counters;
- an 8-deep return stack for BX lr, POP {pc}, LDM with pc, and
  MOV pc, lr.

Cycles lost to branches per instruction, eight stages:

| scheme | Virtua Cop | Bomberman (30 s) | Sonic N |
|---|---|---|---|
| none (the model; the profile adds SWI and MSR) | 0.829 | 0.788 | 0.633 |
| BTB 64 entries, hit costs 0 | 0.309 | 0.311 | 0.233 |
| BTB 256 entries, hit costs 0 | 0.201 | 0.195 | 0.154 |
| BTB 256 entries, hit costs 1 | 0.339 | 0.327 | 0.259 |
| BTB 1024 entries, hit costs 0 | 0.136 | 0.137 | 0.107 |

**Readings.**

- **Without a BTB**, 96 MHz gives 43–45 MIPS with ideal memories, just
  under the phone's 45–50 (section 5.2), before any cache miss. The BTB
  is needed, not optional.
- **A 256-entry BTB answering in F1's own cycle** takes the CPI to
  about 1.58–1.64, which is 59–61 MIPS at 96 MHz.
- **The same BTB one cycle late** gives 1.72–1.75, which is 55–56 MIPS.
- **1,024 entries** save a further 0.05–0.07 CPI. That is M10K blocks
  rather than logic, so it is cheap if the same-cycle loop still closes.

The 256-entry BTB, answering in F1's cycle, is built: section 5.6.

### 5.6 Branch prediction

Section 5.5 showed the BTB is needed. This is the one built
(`rtl/arm_cpu.sv`: "branch prediction" and "BTB update").

**Fetch.**

- **The BTB:** 512 entries, direct-mapped, indexed by `pc[9:1]` (`BI` in
  `arm_cpu.sv` sets the size; it was 256 until gameplay was measured,
  section 4.5).
  - Each entry holds a partial tag `pc[25:10]` (`BT`, 16 bits), the
    target with the Thumb bit as bit 0, and a kind: plain, call or return.
    A false hit is a prediction A finds wrong and refetches after (the
    table below).
  - The 2-bit counters sit in a RAM of their own, so a branch that is not
    taken can count down without rewriting the target.
  - Both RAMs are read at the edge that loads `f1_pc`, with an index of
    their own, `f1_bi`: `f1_pc`'s next value, but from the redirects as
    they are asked for, not as they commit. The entry for an address is
    therefore there in the same cycle F1 holds it, so a correct
    prediction costs nothing.
  - Quartus places the entries in M10K block RAM: 3 blocks for 512 × 50
    bits, as for 256 × 56, and one for the counters.
- **Why the index and the tag are not the obvious ones.** With the
  keypad's build (B, section 5.4), every failing path ended at the BTB's
  read address. They started at the D-cache's hit (`dc_ok`), went
  through M's hold and A's commit into A's redirect, and so into
  `f1_pc_n`. A data abort took the same route. Those are the latest
  signals in the CPU. Read with the redirect as A asks for it, the BTB
  does not wait for them. A redirect that then waits, or never comes, has
  F1 fetch what is younger than it meanwhile. Those fetches are killed,
  or carry a prediction that is checked like any other.
  - The full tag's 22-bit compare was on the same path, so the tag was
    cut to 8 bits (C).
  - 8 bits alias code 256 KB apart. On the bench (section 4.5), A's
    refetches of predicted non-branches rose from 21,777 to 374,446 on
    Tony Hawk, and from 8,138 to 165,209 on Virtua Cop. That cost 0.7% of
    Tony Hawk's play.
  - 16 bits compare in the same two LUT levels as 8, and the entry still
    fits three blocks.
  - With 16 bits, the refetches are 42,392 and 114,294. No two addresses
    the games ran share an index and 16 tag bits, so what remains is the
    entry read for a redirect A asked for and did not commit: another
    address's entry, whose tag may still match.
  - That entry now predicts nothing. A flop, `bmis`, is set at the edge
    that reads the BTB when A asked for a redirect it did not commit, or
    M took a data abort: the two cases where the index and F1's next PC
    part. It holds `f1_hit` low for the cycle that entry is read. The
    refetches fell to 22,650 and 8,198, where they were before the BTB
    had an index of its own (d16, section 4.5). `bmis` is a flop in front
    of the hit, so the read address's path gains nothing.
- **A hit** (tag match and counter ≥ 2) sends F1 to the stored target. For
  a return, it goes to the top of the return stack instead.
- **The return stack:** 8 entries in flops.
  - F1 pushes when it predicts a call and pops when it predicts a return.
  - When F2 misses the cache and F1 is sent back, the stack depth goes back
    with it.
- **The instruction buffer is a ring.** An entry stays where F2 put it, and
  D1 reads the entry at a pointer.
  - Taking an instruction, which is the end of D2's handshake, moves only
    the pointer.
  - The prediction for each entry sits in a second ring beside it, because
    only D2 reads it.
  - Both rings are kept in flops. Quartus made the first versions block
    RAMs, whose late read data and next-pointer address put the stall
    chain back on the path. The buffer carries `ramstyle "logic"`. The
    prediction ring is stored as plain vectors, because Quartus splits an
    array of structs before it reads the attribute.

**Checking.** Every prediction travels with its instruction: `p_taken`,
`p_next`, and the stack depth before it, `p_sp`.

| what reached A | result |
|---|---|
| a direct branch (B, BL), predicted, with the target S compared a cycle early (`a_tgt_ok`) | nothing |
| a direct branch, not predicted | D2 redirects it, as before (3 cycles) |
| BX, predicted, wrong target | redirect from M, so the 32-bit compare ends at a flop (6 cycles) |
| BX, not predicted | redirect from A (5 cycles) |
| anything predicted taken that did not branch: a failed condition, an alias, an entry left from other code | redirect from A to the next instruction (5 cycles) |

**Repairing the return stack.** Any redirect restores the stack depth
carried by the redirecting instruction. If that instruction itself called
or returned, the redirect also applies its push or pop. The link pushed
is the instruction's address plus 4, or plus 3 in Thumb, taken from flops
rather than A's result mux.

The stack's contents are not restored, so a wrong path that pushed can
overwrite an entry below the top. The only cost is a wrong return
prediction later, which the checking above catches.

**Updating.** A decides each update as a branch or BX commits:

- a taken branch allocates its entry with counter 2, or retargets it;
- a branch whose entry was already there moves the counter one step
  towards what happened.

The write lands a cycle later, from flops, so A's forwarding and adders
end at a register. A fetch in between sees the old entry, which is
checked like any other.

**Returns by load** (`LDM`/`POP` with pc) are predicted from the return
stack, as BX lr is.

- A taken one writes its BTB entry with the kind "return", so the next
  fetch of it goes to the stack's top.
- M compares the loaded word with the predicted address. Only a wrong
  one redirects, from W.
- A holds while such a load is in M, so nothing behind it commits on a
  prediction that W may still undo.

Measured on the CPU bench, with ideal memory, over Virtua Cop's first 3
virtual s: CPI went from 1.588 to 1.532, and W's redirects from 0.014 to
0.004 per instruction.

**Not predicted.**

- **`LDR pc`, and a load to PC whose entry is not a return.** These
  redirect from W (7 cycles). They still pop the return stack, so returns
  made by BX lr stay matched.
- **ALU writes to PC** (`MOV pc, lr`, `ADD pc, …`). These redirect from M
  (6 cycles).
- **A Thumb BL whose two halves reach D2 apart.** It redirects from M.
  D2 normally sees the pair whole and turns it into one BL.

The bench's model `btb256/0B` (`sim/cpu/bpred.h`) is this design. It does
not predict loads or ALU writes to PC, and its return stack still counts
them.

**Measured** with `sim/run_cpu.sh`, in lockstep with Unicorn and with
ideal memories, over the runs of section 5.5. All three are identical to
Unicorn.

| | Virtua Cop | Bomberman (30 s) | Sonic N |
|---|---|---|---|
| CPI | **1.594** (2.205 without) | **1.645** (2.213) | **1.660** (2.121) |
| MIPS at 88.7 MHz (section 5.4) | 55.6 | 53.9 | 53.4 |
| branch cycles per instruction, RTL | 0.234 | 0.229 | 0.182 |
| ... of which D2 | 0.047 | 0.044 | 0.036 |
| ... of which A: conditional B, BX | 0.097 | 0.093 | 0.075 |
| ... of which M | 0.026 | 0.032 | 0.020 |
| ... of which W | 0.064 | 0.060 | 0.050 |
| model `btb256/0B` | 0.228 | 0.221 | 0.175 |
| model, every PC write predicted (`btb256/0`) | 0.201 | 0.198 | 0.156 |
| SWI and MSR (in neither model) | 0.026 | 0.025 | 0.021 |

- **The RTL is within 0.008 of its model.** The difference is about what
  the model leaves out: split BL pairs, and wrong-path damage to the
  return stack.
- **Predicting loads and ALU writes to PC** would save a further
  0.02–0.03 CPI.
- **Instruction counts.** The runs execute fewer instructions in the
  same 15 virtual seconds than without the BTB: 541 M against 590 M for
  Virtua Cop. The faster CPU reaches the same events sooner and then
  idles until the timer, so the CPIs cover slightly different work.
- **Random programs.** 300 random programs passed (seeds 10001–10300),
  and 100 more after each structural change (11001–14100). Random
  programs do not repeat their branches, so they test that a prediction
  is never trusted unchecked, not the prediction itself.

**Not shown.**

- **96 MHz.** The BTB build fits at a median of 88.7 MHz (section 5.4).
- **Timing inside the core's own project**, which is set for area.
- **The BTB under an MMU.** The BTB is indexed and tagged by virtual
  address and is never flushed. After a process switch, entries from the
  old process can steer fetch for the new one. That costs time, never
  correctness, because every prediction is checked; how much time is not
  measured.
- **Wrong-path corruption of the return stack.** It is allowed by the
  design and is not counted separately.

## 6. Verification

The CPU is verified against Unicorn, the engine of `ngvm.py`, instruction
by instruction:

- **Bench:** `sim/cpu/`, Verilator, with `libunicorn` from the Python
  wheel linked into the same C++ binary.
- **Memory:** the bench gives the RTL NGVM's memory map from its own
  images, and Unicorn gets a separate copy.
- **Each retirement compares:** the PC, every register written, CPSR, and
  each store's address and data.
- **Device reads:** the RTL's are recorded and replayed to Unicorn's MMIO
  hooks, so the timer reads the same in both. Device timing is the RTL's.
- **Exceptions:** when the RTL takes an IRQ or abort before an
  instruction, the bench makes Unicorn enter the same exception at the
  same boundary, as `ngvm.py` already does for IRQ.
- **Known differences:** Unicorn's unaligned word accesses (section 5.3),
  and nothing else. Every other mismatch is a bug in one of them, settled
  from the ARM ARM.
- **Run order:**
  1. random programs (below), which take seconds and reach hazards the
     firmware may not for minutes;
  2. the kernel's boot;
  3. the whole firmware boot to a game's title, which is a few hundred
     million instructions.

Then `sim/run_system.sh`: the same CPU on the real memory glue, comparing
LCD frames with `ngvm.py --frames-to`.

**Random programs.** `sim/cpu/randprog.py SEED N OUT.bin` writes a random
program, and `sim/run_cpu.sh --bin OUT.bin` runs it alone in lockstep, no
firmware. Every instruction it writes has a defined result in ARMv4.

- **ARM side:**
  - data processing with every operand-2 form, condition and shift,
    RRX included;
  - multiplies and long multiplies, every load/store width, LDM/STM in
    all four modes with and without write-back, SWP, MRS/MSR on the
    flags.
- **Redirects:** conditional branches, ALU writes to PC and loads to PC.
- **Thumb blocks:** every format except SWI and SP adjustment.
- **Subroutine calls**, ARM and Thumb, returning by BX lr, MOV pc, lr or
  a pop of PC.
- **Dependencies are dense:** most instructions read and write r0–r7.
- **Avoided**, because QEMU differs from ARMv4 or rejects them:
  - unaligned word accesses;
  - encodings with nonzero "should be zero" fields (QEMU treats them as
    undefined; the firmware never uses them).

**Run so far**, with ideal memories and no caches:

| run | instructions in lockstep | result |
|---|---|---|
| six stages: kernel and firmware, no game, to 4 virtual s | 401 M | identical |
| six stages: Bomberman card, to 30 virtual s | 619 M | identical |
| eight stages: Bomberman card, to 30 virtual s | 619 M | identical |
| eight stages: Virtua Cop card, to 15 virtual s | 590 M | identical |
| eight stages: Sonic N card, to 15 virtual s | 581 M | identical |
| eight stages: 1,000 random programs, about 64% Thumb | 26.8 M | identical |
| eight stages: 300 more after each timing change (section 5.4), 1,500 in all | | identical |

**With the caches, page table and devices** (`sim/run_sys.sh`: all of
`ngvm_sys` behind a bus of ideal latency, Unicorn alongside):

| run | instructions in lockstep | result |
|---|---|---|
| Bomberman card, to 24.4 virtual s | 875 M | identical (stopped there) |
| Sonic N card, to 26.3 virtual s | 889 M | identical (stopped there) |
| Virtua Cop card, to 16.3 virtual s | 631 M | identical (stopped there) |
| Virtua Cop card, to 12 virtual s, D-cache data in byte-enabled block RAM | 542 M | identical |

The first three ran before the D-cache's data RAMs were rewritten in the
form Quartus infers as block RAM; the last is on the RTL as committed.

The three game runs and the last 300 random programs (seeds 9001–9300)
are on the RTL as committed. The random programs write only the flags
with MSR, so mode changes, which D1's register indices depend on, are
covered by the firmware in the game runs. The match tags' own check (section 5.3)
held throughout.

**Starting in a game's play.** A gameplay window at 80–92 s is an hour or
more of booting on this bench before it measures anything. Instead,
`tools/ngvm/ngvm.py --save-at 85:FILE` saves the machine where the
reference reaches that virtual second, which takes about a minute. The
file holds:

- the registers of every mode, and the SPSRs;
- the devices and the page table;
- RAM, the fixed processes' section and the drive.

`--restore FILE` then starts the bench there:

- it loads memory and Unicorn from the file;
- once the CPU's reset ends, it sets the RTL's registers, fetch address,
  devices and table, before the CPU's first clock;
- the caches, the BTB and the audio FIFO start empty.

Times given to `--seconds`, `--keys` and `--profile` stay times since
power-on.

Virtua Cop at 85 s (in play, the docks), restored into the d5 RTL, ran
from 85 to 86 s in lockstep with Unicorn: 42.4 M instructions, identical. The frames
show the shootout going on. The game state is the reference's, whose
timing differs from the RTL's, so a restored window is for comparing RTL
variants with each other, not with a run from power-on.

**The rotate-and-mask shifter** was also compared with the one it
replaced. The comparison covered every type, every amount, both amount
forms and both carry-ins, over 64 values: 147,456 cases, none different.

**Found on the way:**

- **Late-forward fallback (eight stages).** An operand marked for A to
  pick up from the uop that had been in A took S's stale copy when that
  uop did not execute, even if a load to the same register was in M.
  Bomberman found it at 5.3 virtual s (`LDRNE r1; MOVEQ r1, r5;
  MOVNE r5, r1`).
- **SWP's result (both versions).** The decoder left the address's
  immediate flag set on SWP's last uop, `MOV Rd, r31`, which then moved
  #0. The firmware and Bomberman never read a SWP's result. The first
  random program did.

Still unexercised:

- data and prefetch aborts, and the undefined trap;
- MSR to the control field from random programs (the firmware does it);
- FIQ (not wired).

**Two QEMU behaviours the bench absorbs:**

- QEMU executes a Thumb BL prefix and suffix as one instruction, but
  only when both are on the same 1 KB page. The bench steps Unicorn on
  the prefix and sees which happened. The RTL never takes an IRQ between
  the two halves, so the boundaries agree.
- Unicorn's reset CPSR has the Z flag set (0x400001d3). The bench starts
  both at 0xd3.

## 7. Loading

| slot | file | bridge (= bus) address | where it goes |
|---|---|---|---|
| 0 | the game's instance JSON | | names slot 3's file |
| 1 | `ngvm.bin` (ours: `build/kernel/kernel.bin`, ships in the package) | `0x0000000` | SDRAM, RAM page 0 on |
| 2 | `sym.rom` (the user's firmware; never shipped) | `0x2000000` | SDRAM |
| 3 | the game's drive image (`tools/mkdrive.py`) | `0x4000000` | CRAM |

- **Routing.** `ngage_mem` routes each byte by its address. Bytes pair into
  little-endian halfwords. Each memory has a 64-deep FIFO, because the
  loader cannot wait.
- **Sizes.** `IO_ROM_SIZE` and `IO_DRIVE_SIZE` are one past the last byte
  loaded into each region.
- **Reset.** The CPU is held in reset until every slot is loaded.
- **Running again.** A menu reset runs the kernel again over memory as the
  last run left it. Its `.data` therefore comes from a copy in the image,
  restored at every boot (`sw/kernel/kernel.ld`).

## 8. Budgets

| stage | budget | ideal-memory bench | real-memory bench | hardware |
|---|---|---|---|---|
| CPU Fmax, alone | ≥ 96 MHz | without a BTB: median 97.0 MHz over four seeds (parallel fit), 100.3 (one processor); with the BTB: 87.2–90.6, median 88.7 (one processor); high-performance fit (section 5.4) | | |
| CPI, ideal memories, first 15 s of a game | as low as the clock allows | 1.59–1.66 with the BTB, 2.12–2.21 without (sections 5.5, 5.6) | | |
| MIPS delivered, Virtua Cop | ≥ the phone's (about 50); 70 a stretch | 55.6 at 88.7 MHz, ideal memories, before any cache miss | 20.6–21.6 at 80 MHz while the firmware boots (`sim/run_system.sh`, 7.5–8.5 s); the title at 35 s, against the reference's 30 | |
| LCD copy | done before the next update, at most 240 a second (Virtua Cop's intro at 100 MIPS): 4 ms | | at most 1.42 ms over Virtua Cop's boot, waiting on the CPU's bursts included | |
| audio latency | as little as keeps the FIFO from running dry | | 505–1,022 samples queued over 22 s of Virtua Cop's music (`sim/run_system.sh`, CPU at 80 MHz): 32–64 ms at 16 kHz (it was 128–256) | |
| audio FIFO | never empty while playing | | 505 samples at the lowest over those 22 s; Sonic's music 510 | |

## 9. What is not cycle-exact, and why that is acceptable

Nothing here tries to be cycle-exact with the N-Gage. The games pace
themselves by the timer and by frame counts, not by instruction timing,
and the phone's own speed varied with its memory. The requirement is
enough speed (section 5.2), and the order of events the kernel defines.
