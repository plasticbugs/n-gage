# ==============================================================================
# My Core on the Pocket: timing constraints beyond the BSP's
# sys_constr.sdc. The 96 MHz system clock, its 6.857 MHz video pair and the
# shifted SDRAM clock all come from core_pll and are timed as one related
# group; the two 74.25 MHz inputs and the audio PLL are asynchronous to it.
# The PLL's fifth output is the Analogizer's 48 MHz (clk_sys / 2, in phase),
# in the same group: the pixel hand-over into it (pocket_analogizer.sv) is a
# held register under a toggle, timed as the related-clock path it is.  If a
# core sets USE_ANALOGIZER = 0 that output drives nothing and this name
# matches nothing -- take it out of the group then (the CI constraint check
# says so).
# ==============================================================================
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

# SDRAM: the chip is clocked by the phase-shifted PLL output (core_pll's
# outclk_3).  The shift divides the budget between two checks that pull
# opposite ways: the data the chip returns is captured by an I/O-cell register
# on the core clock, and the address and command the core drives are captured
# by the chip.  On the captured data, setup gets 2T - shift and hold gets
# T - shift, so a nanosecond off the shift is a nanosecond onto setup and a
# nanosecond off hold.
#
# THE SHIFT IS PER-DESIGN.  5.859 ns is where Master of Weapon's fit balanced
# (setup slack = 6.241 - shift at slow 85C, hold slack = shift - 5.519 at fast
# 0C); the board is the same for every core but the fit is not.  If the worst
# path in a build is dram_dq[*] -> sdram_ctrl|dq_in[*], measure both slacks at
# two shift values, solve for where they meet, and round to a multiple of
# 130.2 ps, the step the 960 MHz VCO can make.  projects/report_worst.tcl
# writes the reports to read: worst_paths*.txt for setup, worst_hold_fast.txt
# for hold.  METHODOLOGY.md section 5.20.
#
# The template's skeleton is now at 6.640 ns: adding the Analogizer's PLL
# output moved its fit to setup +1.543 ns (slow 85C) and hold -0.058 ns
# (fast 0C) at 5.859, so the two meet 0.80 ns later -- 51 steps of 130.2 ps.
# Re-measure when the machine replaces the skeleton.
create_generated_clock -name dram_clk -source \
    [get_pins {ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_ports {dram_clk}]
set_input_delay -max -clock dram_clk 7.0 [get_ports {dram_dq[*]}]
set_input_delay -min -clock dram_clk 2.5 [get_ports {dram_dq[*]}]
set SDRAM_OUT [get_ports {dram_a[*] dram_ba[*] dram_cke dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -max -clock dram_clk  1.5 $SDRAM_OUT
set_output_delay -min -clock dram_clk -0.8 $SDRAM_OUT
set_multicycle_path -setup 2 -from [get_clocks {dram_clk}] -to [get_registers {*|sdram_ctrl:*|dq_in[*]}]
set_multicycle_path -setup 3 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]
set_multicycle_path -hold  2 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]

# The pixel hand-over to the 6.857 MHz video clock. The dot enable's phase is
# pinned to clk_vid (core_top.sv's pix_sync into clk_enables.sv), so the
# colour and sync registers are launched a fixed number of system clocks
# before the clk_vid edge that samples them, and the setup check starts from
# that launch edge. The toggle the other way (vt -> vt_s) is a plain
# flop-to-flop path, checked as it stands.
set VID_OUT [get_registers {ic|vr_q[*] ic|vg_q[*] ic|vb_q[*] ic|vhs_q ic|vvs_q ic|vde_q}]
set_multicycle_path -setup 3 -start -from [get_clocks {ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to $VID_OUT
set_multicycle_path -hold  2 -start -from [get_clocks {ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to $VID_OUT

# SRAM: registered pins held for whole system cycles, a read sampled several
# cycles after the address (target/pocket/sram_port.sv), so the pins are not
# timed against a clock.
set_false_path -to   [get_ports {sram_*}]
set_false_path -from [get_ports {sram_dq[*]}]

# The PSRAMs are unused on this board; the BSP still brings their pins out.
set_false_path -to   [get_ports {cram0_* cram1_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait}]

# ------------------------------------------------------------------------------
# Multicycle exceptions for clock-enabled blocks go here.  None are claimed
# yet, because the skeleton has nothing that needs one.  Before adding any,
# read METHODOLOGY.md sections 5.11 and 5.20:
#
#   * write down why EVERYTHING the filter matches qualifies, and register
#     every input at the edge of the relaxed region;
#   * a register Quartus merges into a block RAM's output no longer exists by
#     name, the filter matches nothing, and the line is ignored with a warning
#     -- CI fails the build on that (Check every constraint was applied);
#   * a block RAM read closes on one clock.  Leave it alone.
#
# The shape the sibling cores use, proven on hardware, for a CPU that steps on
# clock enables four or more system clocks apart:
#
#   set M68K [get_keepers {*|fx68k:*|*}]
#   set_multicycle_path -setup 4 -from $M68K -to $M68K
#   set_multicycle_path -hold  3 -from $M68K -to $M68K
# ------------------------------------------------------------------------------
