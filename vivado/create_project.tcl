# creates the vivado project - sims, synthesis, bitstream, all from the gui.
# only needs to run once - after that just open vivado/aes128/aes128.xpr.
#
# from the vivado tcl console (or Tools > Run Tcl Script):
#   source path/to/vivado/create_project.tcl
# or from a terminal:
#   vivado -mode batch -source vivado/create_project.tcl
#
# part is the basys 3 artix-7 (xc7a35tcpg236-1)

set repo [file normalize [file join [file dirname [info script]] ..]]

create_project aes128 [file join $repo vivado aes128] -part xc7a35tcpg236-1 -force

# rtl. the axi wrapper and the uart live in their own subdirs, so each needs
# its own glob - a plain rtl/*.sv silently misses them
add_files [glob [file join $repo rtl *.sv] \
                [file join $repo rtl axi *.sv] \
                [file join $repo rtl uart *.sv]]

# testbenches + vector files. vivado copies the txt files into the sim
# working dir so $readmemh finds them by bare filename
add_files -fileset sim_1 [glob [file join $repo tb *.sv]]
add_files -fileset sim_1 [glob [file join $repo vectors *.txt]]

# constraints + synthesis top, so Generate Bitstream works straight from the
# gui. vivado/build_bitstream.tcl is the same flow non-project for building
# from a terminal - both should give the same result, see below.
# the [list ...] matters, same trap as read_xdc in build_bitstream.tcl:
# add_files treats a bare string as a list of files, so the space in this
# repo's path splits it in two. the rtl adds above get away with it because
# glob already returns a proper list.
add_files -fileset constrs_1 [list [file join $repo constraints basys3.xdc]]
set_property top aes_uart_top [current_fileset]

# make the gui's Run Implementation do the same steps as build_bitstream.tcl.
# the default strategy leaves post-place phys_opt_design unchecked, and with
# setup slack around half a ns that step is not optional - a gui build
# without it might or might not close timing depending on placement luck.
# with this enabled, Run Synthesis -> Run Implementation -> Generate
# Bitstream is the same opt/place/phys_opt/route the batch script runs, just
# with the outputs under vivado/aes128/aes128.runs/impl_1 instead of
# vivado/build.
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]

# default sim is the whole board design, pin to pin - open the project, hit
# Run Simulation, watch it print PASS. to run any other testbench, right
# click it under Simulation Sources and Set as Top (they are all in sim_1
# already and all self checking).
set_property top tb_aes_uart_top [get_filesets sim_1]

# run until the tb calls $finish instead of the default 1000ns - tb_aes_core
# needs ~260us to get through all 1000 vectors
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

puts "done. open [file join $repo vivado aes128 aes128.xpr] and hit Run Simulation."
