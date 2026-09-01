# non project build of the board demo. synth, place, route, bitstream, plus
# the reports I actually want to read afterwards.
#
# non project mode on purpose: the gui project in vivado/aes128 is for running
# sims interactively, and I did not want the bitstream that goes on the board
# to depend on whatever state that project happened to be left in. This script
# reads the files, builds, and writes everything under vivado/build.
#
# from the repo root:
#   C:\Xilinx\Vivado\2019.2\bin\vivado -mode batch -source vivado/build_bitstream.tcl
#
# then vivado/program.tcl to put it on the board.

set repo  [file normalize [file join [file dirname [info script]] ..]]
set build [file join $repo vivado build]
set part  xc7a35tcpg236-1
set top   aes_uart_top

file mkdir $build
cd $build

# rtl. same trap as create_project.tcl - the axi wrapper and the uart live in
# their own subdirs so each needs its own glob, a plain rtl/*.sv misses them
# and you find out at elaboration when the top has no submodules.
read_verilog -sv [glob [file join $repo rtl *.sv] \
                       [file join $repo rtl axi *.sv] \
                       [file join $repo rtl uart *.sv]]

# the [list ...] matters. read_xdc treats its argument as a list of files, so
# a bare path gets split on spaces - and this repo lives under
# "CSULB\Personal Projects", which turns into a hunt for Personal.xdc.
read_xdc [list [file join $repo constraints basys3.xdc]]

synth_design -top $top -part $part
write_checkpoint -force [file join $build post_synth.dcp]
report_utilization -file [file join $build post_synth_util.rpt]
report_timing_summary -file [file join $build post_synth_timing.rpt]

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $build post_route.dcp]
report_utilization      -file [file join $build post_route_util.rpt]
report_timing_summary   -file [file join $build post_route_timing.rpt]
# the 10 worst paths with the logic on them, which is what I want when the
# summary says the slack moved and I need to know why
report_timing -sort_by group -max_paths 10 -path_type full_clock_expanded \
              -file [file join $build post_route_paths.rpt]
report_drc              -file [file join $build post_route_drc.rpt]
report_clock_utilization -file [file join $build post_route_clocks.rpt]

write_bitstream -force [file join $build $top.bit]

# print the numbers so I do not have to open a report to find out if it built
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "----"
puts "bitstream: [file join $build $top.bit]"
puts "WNS $wns ns   WHS $whs ns"
if {$wns < 0 || $whs < 0} {
    puts "TIMING NOT MET - do not trust the board until this is fixed"
} else {
    puts "timing met"
}
puts "----"
