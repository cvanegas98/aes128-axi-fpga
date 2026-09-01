# aes128-axi-fpga

AES-128 encrypt-only core in SystemVerilog with an AXI4-Lite wrapper and a
UART command bridge, running on a Basys 3. Everything is verified against a
python model that is itself checked against FIPS-197 and pycryptodome, and
the testbenches were mutation tested - the how and why is in docs/STATUS.md,
the register map is in docs/register_map.md.

Vivado 2019.2, part xc7a35tcpg236-1 (the Basys 3 Artix-7).

The full writeup (block diagram, verification approach, timing numbers) is
still coming - STATUS.md is the honest running log in the meantime.

## trying it yourself, all in the gui

1. Tools > Run Tcl Script on vivado/create_project.tcl. only needed once,
   the project lands in vivado/aes128 (gitignored).
2. Run Simulation. the default sim top is tb_aes_uart_top - the whole board
   design simulated pin to pin, serial in to serial out. it prints PASS per
   test and one PASS at the end. to run any other testbench, right click it
   under Simulation Sources and Set as Top - they are all in the project and
   all self checking.
3. Run Synthesis -> Run Implementation -> Generate Bitstream.
4. Open Hardware Manager -> Open Target -> Auto Connect -> Program Device.
5. talk to the board:

       pip install pyserial
       python host/board_kat.py COM5        (whatever port the board got)

   that runs a 5 step bring-up ladder ending in the FIPS-197 known answer
   test. add --vectors 1000 to also push every line of random_1000.txt
   through the board with the python model as the judge.

note: create_project.tcl enables post-place phys_opt_design on impl_1 so the
gui runs the same implementation steps as the batch script below. the
default gui strategy skips that step, and the setup slack on this design is
too thin to give it away.

## same thing without the gui

sims, from the repo root (each tb header has its exact compile line):

    xvlog -sv rtl/*.sv rtl/axi/*.sv rtl/uart/*.sv tb/tb_aes_uart_top.sv
    xelab tb_aes_uart_top -s top_sim
    xsim top_sim -R

bitstream and program, non-project mode (reports land in vivado/build):

    vivado -mode batch -source vivado/build_bitstream.tcl
    vivado -mode batch -source vivado/program.tcl

## layout

    model/        python golden model + vector generator
    vectors/      generated test vectors (committed, so nothing to regenerate)
    rtl/          the core, rtl/axi/ the wrapper, rtl/uart/ uart + bridge
    tb/           one self checking testbench per module
    constraints/  basys3 pins + timing
    vivado/       project/build/program scripts
    host/         serial demo script
    docs/         register map + running log

no ip cores anywhere, on purpose - nothing to regenerate or version-match,
the whole design is the .sv files in this repo.
