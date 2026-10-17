# The core on the Pocket

How the board in `docs/hardware.md` maps onto the Pocket, and the budgets that
mapping has to meet. Decide these on paper; METHODOLOGY section 5.2.

## 1. Clocks

System clock, and each enable derived from it (`rtl/clk_enables.sv`): the
ratio, the real frequency it gives, and the error against the board's. The dot
clock's relation to `clk_vid`. Refresh rate as built, to three decimals.

## 2. Where each memory lives

| memory | size | Pocket resource | why | access pattern and latency |
|---|---|---|---|---|

Block RAM if it fits — it removes whole categories of bug. SDRAM for the ROM
image; SRAM for one random-access RAM too big for block RAM. One-dimensional,
power-of-two RAMs only (section 5.18).

## 3. The ROM image

Layout of `mycore.rom` byte by byte, the SDRAM word address of each region,
and the same constants in `target/pocket/mycore_mem.sv` and `sim/tb_mem.cpp`.

## 4. SDRAM clients and the arbiter

Who reads what, how often, with what deadline, in what priority. Who can stall
and who cannot (the download cannot). Which ports are shared, and how each
shared port's acknowledge names its owner (section 5.17).

## 5. Budgets — measured, not assumed

| stage | budget (clocks) | ideal-memory bench | real-memory bench | hardware (panel) |
|---|---|---|---|---|
| line render | | | | |
| sprite pass | | | | |

Fill in all four columns. A stage with a deadline must say when it misses it,
with a counter that survives the miss (section 5.19).

## 6. Timing exceptions

Every multicycle in `projects/mycore_pocket.sdc`, why everything its filter
matches qualifies, and which registers sit at the edge of the relaxed region.

## 7. What is not cycle-exact, and why that is acceptable
