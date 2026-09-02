# aes128-axi-fpga

AES-128 encrypt-only core in SystemVerilog with an AXI4-Lite wrapper and a
UART command bridge, running on a Basys 3. Iterative, one round per clock:
11 cycles per block at 100 MHz on the board, measured Fmax ~132 MHz.
Everything is verified against a python model that is itself checked against
FIPS-197 and pycryptodome, and the testbenches were mutation tested.

Vivado 2019.2, part xc7a35tcpg236-1 (the Basys 3 Artix-7). No IP cores
anywhere, on purpose - nothing to regenerate or version-match, the whole
design is the .sv files in this repo.

Scope was cut to stay finishable: encrypt only (no decrypt), ECB, single
block, key expanded up front into registers. docs/STATUS.md is the running
log of how it got built, including the wrong turns.

## what it is

    RsRx -> uart_rx ---> uart_axi_bridge ----------> aes_axi_lite -> aes_core
    RsTx <- uart_tx <--/  (K/E/S protocol,  AXI4-Lite  (14 regs,      (fsm +
                           axi master)                  irq)           key_expand
                                                                       + sbox +
                                                                       round fn)

aes_core is the cipher: a 3 state FSM (idle/expand/round) around one copy of
subbytes/shiftrows/mixcolumns reused every cycle, with addroundkey inlined
as the xor it is. key_expand computes one round key per cycle and holds all
11 in registers, so the key is expanded once and blocks stream at 11 cycles
each - that is the reason key_load and start are separate controls instead
of one.

aes_axi_lite wraps it in 14 registers in a 64 byte aperture. The bridge
speaks three commands over serial ('K' + 16 bytes loads a key, 'E' + 16
bytes encrypts and answers with 16, 'S' reads status) and drives the wrapper
as a real AXI master - it is the register map's "how software drives it"
sequence built in hardware. The board top adds a reset synchronizer, a
heartbeat led, and sticky error leds, because when the serial link is what
broke, leds are the only output left.

## register map

| offset    | name   | access | what it does                       |
|-----------|--------|--------|------------------------------------|
| 0x00      | CTRL   | rw     | KEY_LOAD / START (write 1 to pulse), IRQ_EN |
| 0x04      | STATUS | ro     | KEY_READY, BUSY, DONE              |
| 0x08-0x14 | KEY0-3 | rw     | key, msb word first                |
| 0x18-0x24 | DIN0-3 | rw     | plaintext, msb word first          |
| 0x28-0x34 | DOUT0-3| ro     | ciphertext - a holding register captured on
                                the done edge, never the core's live state |

Details, edge cases, and the word order convention are in
docs/register_map.md - it was written before the RTL and the RTL was built
to it. The short version of the contract: load a key once, then per block
write DIN, pulse START, poll DONE, read DOUT. START is dropped if no key is
loaded; both ctrl bits together means KEY_LOAD wins.

## how it's verified

The part of this project I actually care about. The full history is in
docs/STATUS.md; the rules that came out of it:

The python model is the judge for everything. aes_ref.py checks itself
against pycryptodome and the FIPS-197 appendix vectors, then generates the
vector files everything downstream reads - nothing in a testbench compares
against a value I typed in twice.

Every module has its own self checking testbench, verified bottom up before
anything was stacked on top: sbox against all 256 entries, key_expand
against all 11 Appendix A round keys (with two different keys, after
learning that reruns under the same key can pass on stale state), the round
function steps against per-step model output, then the core against the
FIPS KAT plus 1000 random vectors plus key reuse and reset recovery - 1006
blocks.

No testbench drives a DUT with its sibling. The uart_rx tb bit-bangs its
stimulus straight from the 8N1 definition and the uart_tx tb decodes with
its own bit-banged decoder - if rx were tested against tx, a shared
misunderstanding (lsb vs msb first) would cancel out and both would pass
wrong. Same reasoning at the bus: the AXI wrapper is tested by a hand
written BFM, but the protocol assertions watching the wires are written
from IHI 0022 A3.2, not from what my BFM happens to do, and the UART bridge
is a second, independently written AXI master run against the same slave
under the same assertions.

Everything is mutation tested. Break the RTL on purpose in a scratch copy
and the tb has to fail; a test that cannot fail is not a test. This is not
hypothetical rigor - a fresh eyes review partway through found 4 of 5
planted RTL bugs survived the then-current testbenches, all the same
disease (sticky status levels polled after the fact instead of watching
edges). The tbs were rebuilt until every mutant died, the assertions were
mutation tested too (an assertion that never fires is decoration), and the
one surviving mutant was proven functionally equivalent and documented
instead of hand-waved. Later rounds caught real RTL bugs before the board
ever saw them: DOUT exposing mid-round state, VALIDs held through reset,
and a bridge that would wedge the board on an 'E' with no key loaded.

The bus gets stressed, not just exercised. The wrapper answers combinationally,
so a stall injector hides VALID from the slave for random cycles - without
it, a master that dropped VALID early is untestable because READY is always
already there. Channel skew, delayed responses, and a randomized soak run
under multiple seeds.

The board demo is a diagnostic, not a victory lap. host/board_kat.py runs a
bring-up ladder ordered so the first failing rung names the broken path:
all-zero key and plaintext first (word order cannot matter), then plaintext
only, then key only, then both, then the FIPS KAT, then all 1000 random
vectors. On real hardware: 0 failures, from both the batch-built and the
gui-built bitstream.

## numbers

Post route on the xc7a35t-1: 2410 LUT (12% of the part), 2470 FF, zero
BRAM, zero DSP. 11 cycles per block, 10 cycles start-to-done latency, key
expansion ~11 cycles once per key.

Timing closes at the board's 100 MHz with margin. Measured Fmax is 131.6
MHz - found by tightening the constraint until routing gave up, not by
quoting the post-synth estimate (159 MHz, and wrong). The critical path is
the same key_expand path at every period: round counter -> round key mux ->
sbox -> xor, 75-80% routing delay. docs/timing.md has the sweep table, the
path anatomy, and what the numbers taught me about trusting failing runs
over passing ones.

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

   that runs the bring-up ladder; add --vectors 1000 to push every line of
   random_1000.txt through the board with the python model as the judge.

note: create_project.tcl enables post-place phys_opt_design on impl_1 so the
gui runs the same implementation steps as the batch script below. the
default gui strategy skips that step, and the setup slack at 100 MHz is a
few tenths of a ns depending on the run - not enough to give a whole
optimization step away.

## same thing without the gui

sims, from the repo root (each tb header has its exact compile line):

    xvlog -sv rtl/*.sv rtl/axi/*.sv rtl/uart/*.sv tb/tb_aes_uart_top.sv
    xelab tb_aes_uart_top -s top_sim
    xsim top_sim -R

bitstream and program, non-project mode (reports land in vivado/build):

    vivado -mode batch -source vivado/build_bitstream.tcl
    vivado -mode batch -source vivado/program.tcl

and the fmax sweep, one period per run:

    vivado -mode batch -source vivado/fmax_sweep.tcl -tclargs 7.6

## layout

    model/        python golden model + vector generator
    vectors/      generated test vectors (committed, so nothing to regenerate)
    rtl/          the core, rtl/axi/ the wrapper, rtl/uart/ uart + bridge
    tb/           one self checking testbench per module
    constraints/  basys3 pins + timing
    vivado/       project/build/program/fmax scripts
    host/         serial demo script
    docs/         register map + timing writeup + running log
