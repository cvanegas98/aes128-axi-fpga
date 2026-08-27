# Status

Keeping track of where I am so I can pick this back up between sessions.

The plan: AES-128 encrypt-only core (ECB, single 128-bit block), iterative so
one round per clock (~11 cycles per block), round keys precomputed up front.
SystemVerilog, Vivado, Basys 3. Writing the Python model first and checking
every RTL module against it as I go.

## Definition of done

- [ ] self-checking testbench passing the FIPS-197 known answer vectors plus
      ~1000 random vectors checked against the python model
- [ ] AXI4-Lite wrapper (control, status, 4x key, 4x data in, 4x data out,
      done/interrupt) verified with a BFM or the Vivado AXI VIP
- [ ] running on the Basys 3 with a UART bridge demo
- [ ] timing closed with real constraints, critical path and Fmax written up,
      maybe a before/after pipelining comparison
- [ ] README with block diagram, register map, verification approach, and
      utilization/timing numbers

If I run out of time, the hardware demo and timing experiments get cut before
any of the verification stuff does.

## Checklist

Phase 0 - python model (done 8/24)
- [x] repo setup, license, gitignore
- [x] aes_ref.py - AES-128 model, spits out round keys and per-round states,
      double checks itself against pycryptodome
- [x] gen_vectors.py - FIPS KAT + round keys + 1000 seeded random vectors
- [x] verified against the FIPS-197 Appendix B vector
      (2b7e...4f3c / 3243...0734 -> 3925841d02dc09fbdc118597196a0b32)

Phase 1 - core RTL
- [x] sbox.sv + tb (check all 256 entries against the model) (8/24)
- [x] key_expand.sv + tb (all 11 round keys vs fips197_roundkeys.txt) (8/24)
- [x] round function: subbytes.sv, shiftrows.sv, mixcolumns.sv + tbs checked
      against the model (addroundkey is just an xor, doing it inline in
      aes_core) (8/25)
- [x] aes_core.sv - FSM + top level (8/26)
- [x] core tb: FIPS KAT + random_1000.txt (8/26)

Phase 2 - AXI4-Lite wrapper
- [x] register map written down in docs/register_map.md (8/27)
- [x] AXI4-Lite slave wrapper in rtl/axi/aes_axi_lite.sv (8/27)
- [x] AXI testbench (hand written BFM) (8/27)
- [ ] maybe: run the Vivado AXI VIP against it too as a cross check

Phase 3 - hardware demo (first thing to cut)
- [ ] UART to AXI bridge (reuse UART from my old project)
- [ ] basys3.xdc + vivado build script
- [ ] demo on the board

Phase 4 - timing + writeup
- [ ] SDC constraints, close timing, write up critical path + Fmax
- [ ] maybe: pipelined version to compare Fmax
- [ ] finish README

## Log

- 8/24: Phase 0 done. Model + vectors verified against FIPS-197 Appendix A/B
  and pycryptodome. Next up is sbox.sv and its testbench.
- 8/24: sbox.sv done, tb passes all 256 entries in xsim (Vivado 2019.2 cli
  flow: xvlog -sv / xelab / xsim -R from the repo root). Next: key_expand.sv.
- 8/24: added vivado/create_project.tcl so the sims also run from the vivado
  gui (project lands in vivado/aes128, gitignored). verified tb_sbox passes
  there too. note: the gui sim prints a warning about vectors/sbox.txt - that's
  just the tb falling back to the copied sbox.txt, it's fine.
- 8/25: key_expand.sv done - computes one round key per cycle after start,
  done after 10 cycles. tb checks all 11 keys against appendix a, twice in a
  row to make sure start can rerun. next: the round function.
- 8/25: round function done. subbytes/shiftrows/mixcolumns as separate
  combinational modules, all three tbs pass in xsim (500 states each). added
  vectors/roundstep.txt to gen_vectors.py - one file with state + expected
  output of each step applied independently, so the three tbs share it. first
  few states are edge cases plus the appendix b round 1 input so I could
  eyeball the subbytes output against the spec table. addroundkey is just an
  xor so it'll live inline in aes_core. note: re-source
  vivado/create_project.tcl to pull the new files into the gui project.
  next: aes_core.sv (fsm + top level).
- 8/26: aes_core.sv done. 3 state fsm (idle/expand/round), one copy of
  subbytes/shiftrows/mixcolumns reused every cycle, addroundkey inline.
  went with separate key_load and start pulses instead of one start that
  does both - key expansion costs as many cycles as an encryption, so
  re-expanding per block would double the work for the load-key-once case
  the axi wrapper wants. tb passes the fips kat + all 1000 random vectors +
  a key reuse test (one key_load, three blocks back to back) = 1004 blocks.
  also checked the latency: 10 cycles from start being sampled to done,
  since the round 0 addroundkey happens on the same edge that accepts
  start. block rate is still 11 cycles because start isn't accepted until
  the cycle after done.
  a snag I hit writing the tb: done and key_ready both stay high until the
  next start, so waiting on the level passes instantly off the last run.
  had to wait on the posedge instead. tb_key_expand has the same bug but it
  gets away with it since both its runs use the same key - worth fixing when
  I touch it again.
  sanity checked the tb by breaking the last round mixcolumns skip in a
  scratch copy, it failed like it should.
  next: phase 2, write the register map down first then the axi4-lite slave.
- 8/27: phase 2 done. wrote docs/register_map.md first, then built
  rtl/axi/aes_axi_lite.sv against it. 14 registers in a 64 byte aperture,
  ctrl/status/4x key/4x din/4x dout. ctrl's key_load and start are write 1 to
  pulse so software doesn't have to set the bit and clear it again. wstrb is
  honored on the key and din registers. irq is just done & irq_en, no
  separate w1c status register - one interrupt source didn't seem worth it.
  tb has a hand written axi4-lite bfm instead of the vivado vip, keeps the
  ip dependency out of the project. covers register readback, byte enables,
  the ctrl ignore rules, read only + unmapped addresses, the irq, 100
  vectors through the bus and a key reuse run. passes in xsim.
  bfm gotcha: awready/wready are combinational off *valid, so the handshake
  has to be sampled with the pre edge values - reading them after a #1 sees
  the post edge state and misses the handshake completely.
  the good one: mutation tested the tb by breaking things in a scratch copy.
  ignoring wstrb got caught, but swapping the ctrl bit priority did NOT -
  my test wrote both bits while key_ready was still 0, so start was gated
  off anyway and either priority passed. rewrote it to load a key first,
  now it catches the swap. lesson is a test that can't fail isn't a test.
  also: create_project.tcl only globbed rtl/*.sv so it missed rtl/axi,
  added a second glob. re-source it to pick the wrapper up in the gui.
  next: phase 3, uart to axi bridge (reuse the uart from my old project).
