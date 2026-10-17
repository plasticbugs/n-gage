# Worst setup paths on the machine clock. Run against a completed compile:
#   docker run --rm --platform linux/amd64 -v "$PWD":/build -w /build \
#       raetro/quartus:pocket quartus_sta -t projects/report_worst.tcl
# Writes output_files/worst_paths.txt next to the other reports.
cd projects
if {[catch {project_open mycore_pocket -revision mycore_pocket} err]} {
    puts "PROJECT OPEN FAILED: $err"; exit 1
}
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set n [report_timing -setup -npaths 200 -detail full_path \
        -file output_files/worst_paths.txt]
# the SDRAM interface on its own: its paths never make the top 40 but the
# summary's dram_clk corner can still be negative
set nd [report_timing -setup -npaths 10 -detail full_path -to_clock dram_clk \
        -file output_files/worst_dram.txt]
puts "dram_clk paths returned: $nd"
puts "report_timing returned: $n"
report_clocks -file output_files/clocks.txt
report_sdc    -file output_files/sdc_applied.txt
set nh [report_timing -hold -npaths 10 -detail full_path \
        -file output_files/worst_hold.txt]
puts "hold returned: $nh"
# the cold slow corner has its own critical paths (a 0.4 ns hot-corner path
# has missed by 0.1 there); report it too
foreach_in_collection op [get_available_operating_conditions] {
    # "*0C*" alone also matches the fast 0C model, which ran second and
    # overwrote the file with paths that were never the problem.
    if {[string match "Slow*0C*" [get_operating_conditions_info $op -display_name]]} {
        set_operating_conditions $op
        update_timing_netlist
        set nc [report_timing -setup -npaths 40 -detail full_path \
                -file output_files/worst_paths_cold.txt]
        puts "cold-corner paths returned: $nc"
    }
}
delete_timing_netlist

# Hold on the fast models, which is where it is worst and where the SDRAM
# capture bites: that path's setup gets 2T - shift and its hold T - shift, so
# moving the phase to fix one opens the other, and a run reporting only slow
# hold looks clean right up until the build fails.
create_timing_netlist -model fast
read_sdc
foreach_in_collection op [get_available_operating_conditions] {
    if {[string match "Fast*0C*" [get_operating_conditions_info $op -display_name]]} {
        set_operating_conditions $op
        update_timing_netlist
        set nfh [report_timing -hold -npaths 20 -detail full_path \
                 -file output_files/worst_hold_fast.txt]
        puts "fast-corner hold returned: $nfh"
    }
}
delete_timing_netlist
project_close
