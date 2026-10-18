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

Six stages:

| stage | work |
|---|---|
| F1 | next PC → I-cache block RAM address |
| F2 | I-cache data and tag; hit |
| D | Thumb → ARM expansion, decode, register read, hazards, B/BL target |
| E | forwarding → shifter → ALU, flags, condition, branch resolve, address |
| M | D-cache data and tag; hit; load align and extend |
| W | register write |

- **Thumb:** decoded by expansion to the equivalent ARM operation in D,
  so E, M and W know only ARM.
- **Branches:**
  - unconditional B/BL redirect from D, costing 2 cycles;
  - other branches resolve in E, costing 3 cycles if taken;
  - a branch target buffer read in F1 is the planned optimisation, sized
    from the profile in section 5.5.
- **Loads:** one cycle of load-use delay, forwarding from W.
- **Multiplies:** DSP blocks, a fixed 2–3 cycles; the long forms take an
  extra cycle for the high word.
- **LDM/STM:** a sequencer in D issues one register per cycle.
- **Register-specified shifts:** one extra cycle, as on ARM7.
- **Exceptions:**
  - entered in E for SWI and undefined, and in M for aborts;
  - by flushing the younger stages, then switching mode, banking LR and
    SPSR, and jumping to the vector.
  - IRQ is taken between instructions in D.
- **Coprocessors and FIQ:** no coprocessor; MCR, MRC, CDP, LDC and STC
  take the undefined-instruction trap. FIQ is not wired.
- **Unaligned LDR:** rotates as ARMv4 does. Unicorn does not, so the bench
  allows this one difference (section 6).

### 5.4 Timing risk

The two long paths at 96 MHz (10.4 ns) are:

- E's forward → shift → add → flags;
- the hit → stall fan-out from M.

If either fails:

- **E:** splits into E1 (shift) and E2 (ALU), at the cost of a second
  cycle of load-use and branch delay.
- **Stall:** a miss becomes a replay. M flushes, and the instruction
  re-issues after the fill, so no stall signal is computed from a tag
  compare in the same cycle.

The CPU is synthesised on its own with registered edges, as ZAP was,
before it joins the core. Its Fmax goes in the table in section 8.

**Measured: the six-stage pipeline makes 61 MHz, not 96.** Quartus 18.1,
5CEBA4F23C8, the CPU alone with registered ports, constrained to
10.417 ns:

- 4,258 ALMs (23%), 4,380 registers after the fitter's duplication,
  3 DSP blocks;
- worst setup slack −5.92 ns at slow 85 °C, so Fmax 61.2 MHz.

The clock reaches the registers at about 4.3 ns, leaving 15.4 ns paths
of data, and both stages carry one:

- **E** (9 levels plus the carry chain): forwarding mux, 2.1 ns →
  barrel shifter, 3.3 → offset/operand mux, 3.3 → 32-bit add, 2.5 →
  result mux → `f1_pc`, `m_ra` or the CPSR.
- **D** (13 levels): Thumb expansion, 4 → LDM/STM register-list decode
  (`rem_next`, last), 5 → `d_take` → the D word mux, 4.5.

Each is about one and a half stages of logic. Trimming does not close
that gap on the slowest speed grade, so the pipeline is restructured
(section 5.6). This version stays as the functional baseline: it passes
the lockstep runs in section 6.

### 5.5 Where the cycles go, measured

`sim/run_cpu.sh` (sections 6 and 8) tallies each cycle by what the
pipeline is doing. The figures below are for the first 15 virtual seconds
from power-on of each game, which covers boot, loading and the menus.
They use ideal memories: every access answers in one cycle.

| per instruction | Virtua Cop | Bomberman | Sonic N |
|---|---|---|---|
| CPI | 1.857 | 1.856 | 1.769 |
| extra LDM/STM/SWP/long-multiply uops | 0.221 | 0.224 | 0.189 |
| load-use waits | 0.105 | 0.111 | 0.122 |
| multiplier waits | 0.001 | 0.010 | — |
| cycles lost to branches | 0.502 | 0.483 | 0.383 |

The branch figure is the sum of three costs:

- D redirects × 2;
- E redirects × 3: conditional B, BX, ALU to PC, SWI;
- M redirects × 4: loads to PC.

The bench also replays each retired branch through models of the
predictors it could have (`sim/cpu/bpred.h`). Its "now" column
reproduces the profile to within 0.04, the SWIs and other redirects it
does not model. Cycles lost to branches per instruction:

| scheme | Virtua Cop | Bomberman | Sonic N |
|---|---|---|---|
| now | 0.502 | 0.483 | 0.383 |
| backward conditional branches taken in D | 0.436 | 0.441 | 0.335 |
| BTB 64 entries, hit costs 0 | 0.194 | 0.206 | 0.147 |
| BTB 256 entries, hit costs 0 | 0.129 | 0.137 | 0.099 |
| BTB 256 entries, hit costs 1 | 0.266 | 0.268 | 0.204 |

The BTB model:

- direct-mapped and indexed by PC;
- 2-bit counters;
- an 8-deep return stack for BX lr, POP {pc}, LDM with pc, and
  MOV pc, lr.

**Readings.**

- Static prediction is not worth the logic.
- A 256-entry BTB whose prediction reaches F1 in the same cycle saves
  about 0.35 CPI, taking the ideal-memory CPI to about 1.5.
- The saving depends on that same-cycle loop: BTB read → compare → next
  PC → BTB address. A BTB one cycle late keeps only about half of it.

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
- **Known differences:** Unicorn's unaligned LDR (section 5.3), and
  nothing else. Every other mismatch is a bug in one of them, settled from
  the ARM ARM.
- **Run order:**
  1. directed tests: each instruction class, ARM and Thumb, every
     condition, every mode;
  2. the kernel's boot;
  3. the whole firmware boot to a game's title, which is a few hundred
     million instructions.

Then `sim/run_system.sh`: the same CPU on the real memory glue, comparing
LCD frames with `ngvm.py --frames-to`.

**Run so far**, with ideal memories and no caches:

| run | instructions in lockstep | result |
|---|---|---|
| kernel and firmware, no game, to 4 virtual s | 401 M | identical |
| Bomberman card, to 30 virtual s | 619 M | identical |

The directed tests (step 1) are not written yet. Coverage so far is
whatever the firmware and one game execute. Neither of these is
exercised: data and prefetch aborts, and the undefined-instruction trap.

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
| CPU Fmax, alone | ≥ 96 MHz | 61.2 MHz (six stages; section 5.4) | | |
| CPI, ideal memories, first 15 s of a game | as low as the clock allows | 1.77–1.86 (section 5.5) | | |
| MIPS delivered, Virtua Cop | ≥ the phone's (about 50); 70 a stretch | | | |
| LCD line fetch | 176 words in one line (63.75 µs) | | | |
| audio FIFO | never empty while playing | | | |

## 9. What is not cycle-exact, and why that is acceptable

Nothing here tries to be cycle-exact with the N-Gage. The games pace
themselves by the timer and by frame counts, not by instruction timing,
and the phone's own speed varied with its memory. The requirement is
enough speed (section 5.2), and the order of events the kernel defines.
