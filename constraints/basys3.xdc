# Basys 3 constraints for aes_uart_top.
#
# Pin numbers are from the Digilent Basys3 master xdc. Only the pins this
# design actually uses are in here - the switches and the other buttons are
# left out on purpose, an unconstrained port that nothing drives is a real
# error worth seeing rather than a warning to scroll past.
#
# part is xc7a35tcpg236-1.

## 100 MHz system clock
set_property -dict {PACKAGE_PIN W5 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports clk]

## reset - btnC. active high, the Basys 3 buttons pull low and drive high
## when pressed
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports btnC]

## USB-UART bridge. RsRx is the FT2232 sending to the FPGA, RsTx is the FPGA
## sending to the PC - the names are from the board's point of view, which is
## the opposite of what you would guess, and getting this backwards is a
## silent failure so it is worth saying out loud.
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports RsRx]
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports RsTx]

## LEDs
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN V3  IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN W3  IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN U3  IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN P3  IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN N3  IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN P1  IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN L1  IOSTANDARD LVCMOS33} [get_ports {led[15]}]

## Timing exceptions on the asynchronous pins.
##
## RsRx has no relationship to sys_clk at all - it is a serial line from a
## different oscillator, which is exactly why uart_rx puts two flops on it.
## Constraining it would be claiming a relationship that does not exist, so
## it gets a false path instead and the synchronizer does the real work.
## Same for btnC, which goes through its own two flops in the top level.
set_false_path -from [get_ports RsRx]
set_false_path -from [get_ports btnC]

## RsTx is registered inside uart_tx and its setup/hold at the FT2232 is
## governed by the 8.68us bit period, not by anything sys_clk does. Nothing
## useful to constrain.
set_false_path -to [get_ports RsTx]

## the LEDs are for a human to look at
set_false_path -to [get_ports {led[*]}]

## bitstream settings, straight from the master xdc. without CFGBVS/
## CONFIG_VOLTAGE write_bitstream throws a DRC error rather than a warning.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
