# drops the bitstream onto the Basys 3 over the onboard usb-jtag.
#
# board plugged in and powered before running this, obviously. it is volatile
# - power cycle the board and the fpga is empty again, which is what I want
# while I am iterating.
#
#   C:\Xilinx\Vivado\2019.2\bin\vivado -mode batch -source vivado/program.tcl

set repo [file normalize [file join [file dirname [info script]] ..]]
set bit  [file join $repo vivado build aes_uart_top.bit]

# the batch build lands in vivado/build, a gui build lands in the project's
# runs dir. take whichever exists, batch first if both do.
set gui_bit [file join $repo vivado aes128 aes128.runs impl_1 aes_uart_top.bit]
if {![file exists $bit] && [file exists $gui_bit]} {
    set bit $gui_bit
}

if {![file exists $bit]} {
    puts "no bitstream - run vivado/build_bitstream.tcl or Generate Bitstream"
    puts "in the gui project first"
    exit 1
}

open_hw_manager
connect_hw_server
open_hw_target

# the basys 3 is a single device chain, so whatever turned up is the part
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
puts "found [get_property PART $dev]"

set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "programmed $bit"
close_hw_manager
