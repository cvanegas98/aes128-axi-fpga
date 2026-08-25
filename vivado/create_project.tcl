# creates the vivado project so I can run the sims from the gui.
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

# rtl
add_files [glob [file join $repo rtl *.sv]]

# testbenches + vector files. vivado copies the txt files into the sim
# working dir so $readmemh finds them by bare filename
add_files -fileset sim_1 [glob [file join $repo tb *.sv]]
add_files -fileset sim_1 [glob [file join $repo vectors *.txt]]

set_property top tb_sbox [get_filesets sim_1]

puts "done. open [file join $repo vivado aes128 aes128.xpr] and hit Run Simulation."
