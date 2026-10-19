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
          |         +-----------+---- LCD scan-out --> video out          |
          |                     +---- audio FIFO   --> 48 kHz I2S         |
          +---------------------------------------------------------------+
```

The CPU is our own: `rtl/cpu/` (section 5). Its caches use virtual tags
and keep each line's physical page, so the page table is read only on a
miss.

## 2. Clocks

| clock | frequency | drives |
|---|---|---|
| `clk_sys` | 96 MHz | the CPU, caches, SDRAM controller, CRAM, devices |
| `clk_sdram` | 96 MHz, phase-shifted | the SDRAM pin clock (template, unchanged) |
| `clk_vid` | 6.4 MHz = 96 / 15 | the LCD raster; `pix_sync` pins its divider |

The CPU runs at `clk_sys`, so a cache miss crosses no clock domain. If the
CPU cannot close timing at 96 MHz (section 5.4), it gets its own PLL output.
Its only connection to the memory side is then the miss port, a
request/acknowledge pair that takes a clock-domain crossing without changing
the CPU. The miss port is built that way from the start.

**Raster.**

- 408 × 262 dots at 6.4 MHz: 59.87 Hz, with lines at 15.69 kHz. That is
  NTSC's line rate, so the Analogizer drives a 15 kHz CRT with no
  converter.
- Visible: 176 × 208, centred.
- The kernel sees 59.87 Hz frames through `IO_LCD_FRAME` and `IRQ_VBLANK`.
  `ngvm.py` is to match (it uses 60.000 today).

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
| audio FIFO | 2,048 × 32 bits | block RAM | |
| LCD line buffers | 2 × 176 × 16 bits | block RAM | |

The 64 MB SDRAM cannot hold all of RAM, ROM, KSEC and a drive image. The
drive is the one region only the kernel's drive LDD reads, through
`memcpy` into a buffer, so it goes to CRAM, where uncached word access
costs least.

The drive images in `scratchpad/games` are 16–17.8 MB files, with the last
data byte between 1.7 MB (Snakes) and 14.9 MB (Bomberman). With 24 MB of
CRAM, `tools/mkdrive.py` keeps its default size.

The Pocket's 256 KB SRAM is unused. It is the first place to look if the
kernel's hot data needs a faster home than SDRAM.

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
| F1 | next PC → instruction memory address |
| F2 | instruction word back (or not: the fetch is replayed); into a 4-entry buffer |
| D1 | from the buffer's head: Thumb → ARM expansion; predecode (B/BL, Thumb BL prefix, LDM/STM, SWP, long multiply; the first LDM/STM register and the list's length) |
| D2 | decode; register read by the instruction's fields; IRQ injection; redirect for B, BL and a Thumb BL pair |
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
  - a shift by a register: 1.
  - A branch target buffer read in F1 is next (section 5.5).
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
| register indices, mode and LDM's last step from D1 | being fitted | | | |

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
- **The next change** removes the paths that seeds 1–3 named:
  - the five register-file indices are computed in D1, in the mode of
    that moment, and D2 decodes in a registered copy of that mode;
  - "another LDM/STM step follows" is a flop, set from the list's
    nibbles without an adder.

  Every change of mode (MSR to the control field, an exception, a
  return from one) redirects and so kills D2, so no uop that survives
  sees a stale mode.
- **A fit takes about 7 CPU-hours** under the container's amd64
  emulation, so a four-seed sweep is an evening.

**The core's project is set for area.** It uses
`OPTIMIZATION_MODE "AGGRESSIVE AREA"`, `OPTIMIZATION_TECHNIQUE AREA` and a
standard fit, with physical-synthesis register duplication off. These
fits used high-performance effort, and their retiming and duplication
are visible in the netlists. When the CPU joins the core, the project or
the CPU's partition needs the same settings, and the timing gets
measured again there. If it misses, the CPU moves to its own PLL output
(section 2).

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

| slot | file | where it goes |
|---|---|---|
| 0 | `ngvm_kernel.bin` (ours, ships in the package) | RAM page 0 |
| 1 | `SYM.ROM` (the user's firmware; never shipped) | SDRAM ROM region |
| 2 | the game's drive image (`tools/mkdrive.py`) | CRAM |

Each game is an instance JSON naming its drive image. The core holds the
CPU in reset until all slots are loaded.

## 8. Budgets

| stage | budget | ideal-memory bench | real-memory bench | hardware |
|---|---|---|---|---|
| CPU Fmax, alone | ≥ 96 MHz | 87.8–96.0 MHz over four seeds, eight stages, high-performance fit (section 5.4) | | |
| CPI, ideal memories, first 15 s of a game | as low as the clock allows | 2.12–2.21 without a BTB (section 5.5) | | |
| MIPS delivered, Virtua Cop | ≥ the phone's (about 50); 70 a stretch | | | |
| LCD line fetch | 176 words in one line (63.75 µs) | | | |
| audio FIFO | never empty while playing | | | |

## 9. What is not cycle-exact, and why that is acceptable

Nothing here tries to be cycle-exact with the N-Gage. The games pace
themselves by the timer and by frame counts, not by instruction timing,
and the phone's own speed varied with its memory. The requirement is
enough speed (section 5.2), and the order of events the kernel defines.
