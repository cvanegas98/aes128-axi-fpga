# timing

How fast the design actually goes, measured instead of estimated: tighten
the clock constraint and rerun the whole flow until routing gives up.
vivado/fmax_sweep.tcl does one period per invocation (fresh vivado process,
nothing shared between attempts) through the same synth / opt / place /
phys_opt / route steps as the real build. All numbers are post route,
xc7a35tcpg236-1 (the Basys 3 part, slowest speed grade), Vivado 2019.2.

## results

| period  | clock     | WNS     | result |
|--------:|----------:|--------:|--------|
| 10.0 ns | 100.0 MHz | +0.566  | met - this is the board build |
|  8.5 ns | 117.6 MHz | +0.069  | met |
|  7.6 ns | 131.6 MHz | +0.015  | met |
|  7.0 ns | 142.9 MHz | -0.457  | failed |
|  6.0 ns | 166.7 MHz | -1.561  | failed |

So 131.6 MHz is demonstrated and the wall is between 7.46 ns (what the
7.0 ns failure implies the path needs) and 7.6 ns. Call it ~132 MHz.
The board runs at 100 MHz because that is the Basys 3 oscillator, with
comfortable margin.

Utilization does not move across the sweep: ~2410 LUT / 2470 FF, no BRAM,
no DSP.

## the critical path

The same path at every period, which is a result in itself - nothing else
ever gets close, so this one path is the design's ceiling:

    key_expand: rnd (round counter) -> round_keys mux -> sbox -> xor
                -> round_keys_reg

7 logic levels, and 75-80% of the delay is routing, not logic. The shape
makes sense: key_expand holds all 11 round keys in registers, and the
expansion step muxes the previous round key out by the round counter, runs
four bytes of it through the sbox (rotword/subword), and xors down the
words. The round counter fans out across the whole 128 bit mux select,
which is where the routing delay piles up - the worst path spends ~2 ns
just getting from the counter to the mux and from the mux to the sbox
luts.

If I wanted it faster: put a register between the mux and the sbox, so the
counter-to-mux and sbox-to-xor legs are separate cycles. That is the maybe
item on the checklist (a pipelined comparison). It would cost one cycle
per round of key expansion - key_load goes from 10 cycles to ~20 - and
nothing during encryption, since the encryption path reads round keys that
are already sitting in registers. Worth doing only as an experiment, the
board only has a 100 MHz oscillator anyway.

## notes on the measurement, learned the hard way

- Slack from a run that met timing understates what the design can do.
  Vivado stops optimizing once the constraint is met, so +0.069 at 8.5 ns
  reads like the edge and is not - 7.6 ns went on to pass. The failing
  runs are the honest data points: extrapolating from the 6 ns failure
  (6.0 + 1.561 = 7.56 ns) predicted the floor almost exactly.
- Run to run variance is real. The same design at 10 ns closed with
  +0.566 from the batch script and +0.194 from the project flow - same
  rtl, same constraints, same steps, different placement seed. Quote
  ranges, not single numbers.
- Two bugs in fmax_sweep.tcl before it told the truth, both in the log
  (9/1): create_clock can't call get_ports before synth_design in
  non-project mode (no design open yet - the override lives in a
  generated xdc instead, which is evaluated at synth time), and the
  override xdc needs the period in its filename or two parallel sweeps
  read whichever file was written last. The tell for the second one was
  a "6 ns" run and a "7 ns" run returning bit-identical WNS.
