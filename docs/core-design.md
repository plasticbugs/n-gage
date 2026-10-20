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
```

The CPU is our own: `rtl/cpu/` (section 5). Its caches use virtual tags
and keep each line's physical page, so the page table is read only on a
miss.

## 2. Clocks

| clock | frequency | drives |
|---|---|---|
| `clk_cpu` | 73.85 MHz = 960 / 13; the first flash ran at 64 = 960 / 15, and 80 = 960 / 12 does not close (section 5.4) | the CPU, caches, page table, devices (`rtl/ngvm_sys.sv`) |
| `clk_sys` | 96 MHz | the SDRAM and CRAM controllers, the LCD (`target/pocket/ngage_mem.sv`, `rtl/ngvm_lcd.sv`) |
| `clk_sdram` | 96 MHz, phase-shifted | the SDRAM pin clock (template, unchanged) |
| `clk_vid` | 6.857 MHz = 96 / 14 | the raster; `pix_sync` pins the dot divider to it (template, unchanged) |

The CPU closes timing alone at 87–91 MHz (section 5.4), not 96, so it has
its own PLL output. The two sides share the PLL's VCO but are timed as
asynchronous. Everything between them crosses by a toggle handshake or two
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

## 3. Where each memory lives

| region (NGVM) | size | Pocket resource | access |
|---|---|---|---|
| RAM, `0x20000000` and the paged windows | 32 MB | SDRAM `0x0000000` | cache-line bursts |
| ROM, `0x50000000` | ≤ 20 MB (`SYM.ROM` is 18.6) | SDRAM `0x2000000` | line bursts, read-only |
| KSEC, `0x80000000` | 4 MB | SDRAM `0x3400000` | line bursts |
| *(unused)* | 8 MB | SDRAM `0x3800000` | |
| drive, `0x60000000` | ≤ 24 MB | CRAM0 (16 MB) + CRAM1 (8 MB) | uncached 16-bit words |
| page table | 16,640 × 16 bits | block RAM | one read a miss |
| I-cache, D-cache | 16 KB each *(section 4)* | block RAM | every cycle |
| audio FIFO | 1,024 × 32 bits | block RAM | 32–64 ms of sound at 16 kHz |
| LCD frame store | 36,608 × 12 bits, as 32K + 4K | block RAM | written by a copy from SDRAM, read by the raster |

The 64 MB SDRAM cannot hold all of RAM, ROM, KSEC and a drive image. The
drive is the one region only the kernel's drive LDD reads, through
`memcpy` into a buffer, so it goes to CRAM, where uncached word access
costs least.

The drive images in `scratchpad/games` are 16–17.8 MB files, with the last
data byte between 1.7 MB (Snakes) and 14.9 MB (Bomberman). With 24 MB of
CRAM, `tools/mkdrive.py` keeps its default size.

The Pocket's 256 KB SRAM is unused. It is the first place to look if the
kernel's hot data needs a faster home than SDRAM.

**How each request reaches a chip** (`target/pocket/ngage_mem.sv`):

| bus request | SDRAM | CRAM |
|---|---|---|
| line read (32 B) | one 16-halfword burst | 16 halfword reads; never asked for (the drive is uncached) |
| line write, masked | one 16-halfword burst, DQM masking each byte | a write per halfword with a byte in the mask |
| word read | a 2-halfword burst | 2 halfword reads |

- **SDRAM.** The controller is the template's, widened to all 64 MB of the
  chip: bank `[25:24]`, row `[23:11]`, column `[10:1]`. A burst issues a
  READ or WRITE every two clocks.
- **SDRAM fast reads** (the menu, off by default) issues a burst's READs
  one a clock. Over the first 20 s of Virtua Cop on `sim/run_system.sh`, a
  line request takes 33-34 memory clocks instead of 45-47, a bus round trip
  32 CPU clocks instead of 41-43, and the CPU retires 725,824,799
  instructions instead of 673,111,453 (+7.8 %). The bench's SDRAM model
  says nothing about whether the Pocket's chip is read soundly at that
  pace, and on another core it was not (METHODOLOGY 5.28), so it is a
  switch until hardware has chosen.
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

- I: 16 KB, 2-way, 32-byte lines.
- D: 16 KB, 2-way, 32-byte lines, write-back, with a one-line write-back
  buffer, so an eviction does not wait in front of the fill.
- 64-byte lines with early restart are the next step if the measured CPI
  needs it.

**Cost.** A miss is about 20–24 cycles at 96 MHz:

- a 32-byte line is a 16-word burst of the 16-bit SDRAM;
- add row activation, CAS latency and the arbiter.

Virtua Cop's 11.4 D misses per 1,000 instructions then add about 0.27
CPI, and its I misses about 0.04.

### 4.2 Correctness with virtual tags

NGVM has one address space, so a virtual tag is unique, with two
exceptions the kernel creates. Both need a contract change in
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

- **The BTB:** 256 entries, direct-mapped, indexed by `pc[8:1]`.
  - Each entry holds the full tag `pc[31:9]`, the target with the Thumb bit
    as bit 0, and a kind: plain, call or return.
  - The 2-bit counters sit in a RAM of their own, so a branch that is not
    taken can count down without rewriting the target.
  - Both RAMs are read at the edge that loads `f1_pc`, with `f1_pc`'s next
    value. The entry for an address is therefore there in the same cycle F1
    holds it, so a correct prediction costs nothing.
  - Quartus places the entries in M10K block RAM (3 blocks, 15,104 bits).
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

**Not predicted.**

- **Loads to PC** (`LDR pc`, `LDM`/`POP` with pc). These redirect from W
  (7 cycles). They still pop the return stack, so returns made by BX lr
  stay matched.
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
