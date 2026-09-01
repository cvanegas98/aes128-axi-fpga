# how fast does this actually go. reruns the whole synth+impl flow at one
# clock period and reports post-route WNS, so I can walk the period down
# until timing breaks and quote a real Fmax instead of the post-synth
# estimate (which was ~159 MHz and means nothing after routing).
#
# one period per invocation on purpose - each run is a fresh vivado process
# so nothing leaks between attempts, and a failed run can't poison the next.
#
# from the repo root:
#   vivado -mode batch -source vivado/fmax_sweep.tcl -tclargs 7.0
#
# no bitstream out of this - it's a timing experiment, not a build. the
# board runs at 100 MHz regardless, this is for the writeup.

if {[llength $argv] != 1} {
    puts "usage: vivado -mode batch -source vivado/fmax_sweep.tcl -tclargs <period_ns>"
    exit 1
}
set period [lindex $argv 0]

set repo  [file normalize [file join [file dirname [info script]] ..]]
set build [file join $repo vivado build]
set part  xc7a35tcpg236-1
set top   aes_uart_top

file mkdir $build
cd $build

# same reads as build_bitstream.tcl, same [list] trap on the xdc
read_verilog -sv [glob [file join $repo rtl *.sv] \
                       [file join $repo rtl axi *.sv] \
                       [file join $repo rtl uart *.sv]]
read_xdc [list [file join $repo constraints basys3.xdc]]

# override the 10 ns clock from the xdc. this can't be a bare create_clock
# here - in non-project mode no design is open until synth_design, so the
# get_ports inside it throws. an xdc file is evaluated at synth time when
# the ports exist, so the override goes in its own little xdc read after
# the main one. create_clock without -add replaces the clock on the port,
# false paths and pins stay as they were.
# the period goes in the filename because the xdc is evaluated at synth
# time, not read time - two sweeps running at once through a shared name
# both end up at whichever period was written last. found that out by
# getting the same WNS out of a "6 ns" and a "7 ns" run.
set ovr [file join $build fmax_override_${period}ns.xdc]
set f [open $ovr w]
puts $f "create_clock -period $period -name sys_clk \[get_ports clk\]"
close $f
read_xdc [list $ovr]

synth_design -top $top -part $part
opt_design
place_design
phys_opt_design
route_design

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]

# keep the worst paths from every attempt - when a period fails I want to
# see what the critical path became, not just that it failed
report_timing -max_paths 5 -file [file join $build fmax_${period}ns_paths.rpt]

puts "----"
puts "FMAX SWEEP  period ${period} ns  WNS $wns  WHS $whs"
if {$wns >= 0 && $whs >= 0} {
    puts "FMAX SWEEP  MET - [format %.1f [expr {1000.0 / $period}]] MHz works"
} else {
    puts "FMAX SWEEP  FAILED at [format %.1f [expr {1000.0 / $period}]] MHz"
}
puts "----"
