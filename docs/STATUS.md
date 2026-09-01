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
- [x] protocol assertions + channel skew/stall soak (8/31) - this is what
      the VIP cross check was for, doing it with assertions instead keeps
      the IP dependency out

Phase 3 - hardware demo (first thing to cut)
- [x] uart_rx.sv + uart_tx.sv + tbs (8/31) - had to write these, see the log
- [x] UART to AXI bridge (command protocol + AXI4-Lite master) (8/31)
- [x] top level tying uart + bridge + aes_axi_lite together (8/31)
- [x] basys3.xdc + vivado build script (8/31) - bitstream builds clean,
      timing met but only just, see the log
- [ ] demo on the board  <- next thing to do, board is here

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
- 8/31: testbench repair session, after a fresh eyes review mutation tested
  the rtl against my tbs and 4 of 5 breaks survived. all of them control
  path, all the same disease as the tb_key_expand bug from 8/26: sticky
  done/key_ready levels checked after the fact instead of watching the
  transition. fixes are all tb/vector side, rtl untouched:
  - watchdogs in the three clocked tbs (2ms then FAIL + $finish). a hang now
    prints FAIL instead of spinning forever. xsim gotcha: $fatal under -R
    stops at a prompt like a breakpoint, so the watchdog has to $finish.
  - tb_key_expand: @(posedge done) instead of wait(done), and run 2 uses the
    appendix c.1 key (new vectors/roundkeys2.txt from gen_vectors.py) so
    stale round keys can't pass by luck. another xsim gotcha: a string
    concat fed straight into $readmemh from a static task garbles the path
    ("File @@FP"), has to go through a string variable in an automatic task.
  - tb_aes_core: new test 0, start with no key loaded has to do nothing.
    the axi tb can't cover the core's own key_ready gate because the wrapper
    gates start identically in front of it.
  - tb_aes_axi_lite: the both-ctrl-bits test now reads STATUS right after
    the CTRL=3 write and requires busy=1/key_ready=0 - the transient is the
    only thing separating "key_load won" from "nothing fired at all". the
    read only write test reads DOUT and KEY0-3 back afterwards (bresp is
    hardwired OKAY so checking it proves nothing). two new tests: START and
    KEY_LOAD written while busy get dropped, exactly one block runs, dout
    and the loaded key survive.
  reran the review's mutation set: everything killed except removing the
  wrapper's !busy gate, which turns out to be a functionally equivalent
  mutant - the core fsm only takes pulses in idle, which is exactly !busy,
  so the gate is redundant defense in depth and no bus level test can tell
  the two layers apart. keeping the gate, writing it down here instead of
  pretending it's covered.
  parking the first synth numbers from the review so they don't get lost
  (2019.2, xc7a35t-1, batch synth_design, no real constraints yet):
  2257 lut / 1849 ff / 0 bram / 0 dsp, wns +3.717 at a 10 ns clock, so
  ~159 MHz post synth. critical path is in key_expand, round_keys mux ->
  sbox -> xor chain, 73% routing.
  next: the small rtl fixes out of the review (dout holding register so the
  bus can't read mid-round state, awprot/arprot ports), then the uart
  bridge.
- 8/31 (later): the rtl fixes. this time the tbs could actually catch a
  regression, which is why they went first.
  - DOUT is a holding register now, captured on the done edge, instead of
    being wired straight to aes_core's state register. that one change kills
    three problems: reading DOUT before the first block gave X, reading it
    mid encryption handed the bus a half encrypted state, and the reset
    readback test couldn't check DOUT at all because of the X. mutation
    check: putting the raw wire back fails with "DOUT at reset = xxx" and
    "DOUT0 moved mid encryption: abd2cdfe" - that value is real round state,
    which is exactly what shouldn't be visible.
  - awprot/arprot added. they're required by the spec and ignored here, but
    without them the ip packager and any block design integration complains.
    tb drives 3'b010 rather than zeros so a wrapper that accidentally
    decoded them would break.
  - handshake outputs gated with aresetn. the state regs clear synchronously,
    so a response pending when reset hit kept BVALID high until the next
    clock edge and the spec wants VALID low during reset.
  - ADDR_WIDTH was a lie - parameterized but addr[5:2] hardcoded. added an
    elaboration check that it's >= 6 and wrote down that the map aliases
    every 64 bytes above that, since only addr[5:2] is decoded.
  - reset mid operation tests, core and wrapper: reset during an encryption
    and during a key expansion, check everything comes back clear and the
    core still works after. also reset with a response pending.
  new mutants, all killed: raw DOUT wire, capture disabled, BVALID not
  gated, reset not clearing key_ready, reset not returning the fsm to idle.
  reran the session 1 mutants too, still all killed.
  the good one this session: my own mid encryption DOUT test failed the
  first time and it was the test that was wrong, not the rtl. read_dout()
  is four transactions, ~14 cycles, and a block only takes 11 - so the
  encryption finished partway through and I spliced the tail of the new
  ciphertext onto the head of the old one. that's the torn read hazard,
  hit by accident in my own testbench. the test reads one word now, and
  the register map documents the constraint properly.
  resynthesized: 2259 lut / 1978 ff (+129, the 128 bit dout register and
  its done delay), wns still +3.717 - the critical path is in key_expand
  and none of this touched it. no critical warnings, the only warnings are
  the prot bits and addr[1:0] being deliberately unused.
  next: phase 3, uart to axi bridge. the bfm stall/skew work (AW before W,
  delayed BREADY/RREADY) and the vivado vip cross check are still open and
  should happen before I call the axi wrapper done.
- 8/31 (session 3): closed out the axi verification. the thing that bugged
  me was that the bfm and the wrapper are both mine, written against the
  same mental model, so they agree with each other whether or not the model
  matches the spec. two fixes for that:
  - a block of protocol assertions that watch the wires instead of trusting
    either side: VALID holds until READY on B and R, the payload under a
    waiting VALID doesn't move, nothing responds during reset, and no
    response appears without a request behind it (outstanding counters).
    they also police my own master - AW/W/AR held stable until their READY.
    checked against IHI 0022 A3.2, not against what my bfm happens to do.
  - the bfm drives each channel from its own thread now, so tests can put
    the address up before the data or vice versa and can dawdle before
    accepting a response. delays default to 0 so every existing directed
    test drives the bus exactly like it did; rand_delays skews and stalls
    every transaction, status polls and dout reads included.
  new tests: directed skew matrix (data before address, address before
  data, slow BREADY, slow RREADY, all four assembled into a real KAT block
  that still encrypts right), and a 25 vector soak with everything
  randomized. 131 blocks over the bus total now.
  mutation checked the assertions themselves, since an assertion that never
  fires is just decoration: BVALID dropping early, RVALID dropping early,
  RDATA tracking the register while RVALID waits, and a spurious BVALID
  with nothing outstanding are all caught, each by the specific assertion
  meant for it. also broke my own bfm (moved AWADDR while AWVALID was
  waiting) and the master side assertions caught that, which is the point.
  reran the soak under -sv_seed 7 / 99 / 4242 so it isn't passing on one
  lucky pattern. note $urandom(seed) doesn't exist in 2019.2, only
  $urandom_range - xsim seeds the same way every run unless you pass
  -sv_seed, so the default run reproduces as is.
  not doing the vivado axi vip. the assertions give the independent opinion
  that was the whole reason to want it, and the vip drags the ip dependency
  into the project that I avoided on purpose. worth a paragraph in the
  readme rather than a todo - if I ever want the third opinion it's a gui
  job, not a blocker.
  phase 2 is done. next: phase 3, uart to axi bridge.
- 8/31 (session 4): started phase 3. first thing: the plan has said "reuse
  the uart from my old project" since 8/24 and that was wrong - the old uart
  is embedded C for a tm4c, not rtl. nothing to port, so it's written from
  scratch. correcting it here so the checklist stops lying.
  uart_rx.sv and uart_tx.sv, 8N1, 100 MHz / 115200 = 868 clocks per bit.
  - rx has a two flop synchronizer on the input. rx is asynchronous to the
    100 MHz clock and without it a transition near the clock edge can go
    metastable, which shows up as byte corruption that never repeats the
    same way twice. that's the failure that looks like a broken cipher and
    isn't, so it's worth the two flops.
  - rx catches the start edge, waits half a bit, and rechecks the line is
    still low before committing - a glitch is not a start bit.
  - framing error output when the stop bit isn't high, which is what a wrong
    baud divisor looks like from the board end.
  tbs: the stimulus for tb_uart_rx is bit banged straight from the 8N1
  definition and tb_uart_tx decodes with its own bit banged decoder. neither
  one uses the other module. if I'd driven the receiver with my own
  transmitter, a shared misunderstanding (lsb vs msb first is the obvious
  one) would cancel out and both would pass while both were wrong - same
  trap as the axi bfm agreeing with the axi slave because I wrote both.
  mutation tested, 7 mutants all killed: rx msb first, rx skipping the mid
  bit recheck, rx sampling at the bit edge, rx ignoring the stop bit, tx msb
  first, tx bit period off by one, tx letting send stomp a byte in flight.
  the one worth writing down: "rx samples at the edge instead of mid bit"
  survived everything until I added a baud tolerance test. with perfectly
  timed stimulus, mid bit and edge sampling are identical - the mid bit
  logic only earns its keep when the sender's baud is off. added a test that
  sends at +/-4% and it caught the mutant immediately. so the tolerance test
  isn't a nicety, it's the only thing testing the sampling point at all.
  also measured the real divisor in the tb: 8.68us per bit at
  CLKS_PER_BIT=868, which is 115200 baud.
  next: the bridge. plan is a command protocol over serial - 'K' + 16 bytes
  loads a key, 'E' + 16 bytes encrypts and returns 16 bytes, 'S' reads
  status. that's literally the "how software drives it" sequence out of
  docs/register_map.md, in hardware, and it demos the key reuse case the
  separate key_load/start exists for. the bridge is also a second, real rtl
  axi master to run against the slave, which is a better cross check than
  the bfm alone.
- 8/31 (session 5): phase 3 built end to end - bridge, board top, xdc, build
  and program scripts, host script. bitstream builds, both new tbs pass, so
  the only thing left of phase 3 is plugging the board in.
  uart_axi_bridge.sv is the "how software drives it" section of the register
  map as hardware. 'K' + 16 bytes loads a key, 'E' + 16 bytes encrypts and
  16 bytes come back, 'S' answers with the status byte. msb first everywhere,
  same order as a hex string in the vector files, so host bytes drop straight
  in with no swapping. two fsms: the command fsm speaks the protocol, a small
  bus engine under it does one axi transaction at a time. anything that is
  not K/E/S gets dropped so line noise cannot wedge it, and sticky
  overrun/resp_err/cmd_err flags go to leds because when the serial link is
  the thing that is broken, leds are the only output left.
  it is also the second, real axi master I wanted against the slave - written
  from the register map rather than from the bfm's mental model, with the
  same IHI 0022 assertions from tb_aes_axi_lite watching it, now pointed at
  a real rtl master instead of my bfm.
  two things mutation testing turned up, both worth writing down:
  - "bridge drops AWVALID before AWREADY comes back" survived every test I
    had. the assertion for it was right - but aes_axi_lite is combinationally
    ready, so there was never a cycle with AWVALID up and AWREADY down and
    the property never got a chance to fire. the fix is a stall injector
    between master and slave in the tb that hides each VALID from the slave
    for a few cycles (hiding VALID is legal on both sides; masking READY
    back at the master would let the two disagree about whether a handshake
    happened). last test reruns the ladder plus 10 vectors with all five
    channels randomly stalled, and now that mutant dies.
  - "poll !busy instead of DONE" also passed everything, and working out why
    led to a real bug: 'E' with no key loaded. the wrapper drops START unless
    KEY_READY is set, so the DONE poll spins forever - board wedged, leds
    dark, reset button the only way out. that is a real way to lose a demo.
    the bridge reads STATUS first now and a keyless 'E' is dropped with
    cmd_err latched, so the host just sees a timeout. new test covers it:
    no bytes come back, cmd_err lights, bridge still answers afterwards.
  aes_uart_top is wiring plus a two flop reset synchronizer on btnC
  (ASYNC_REG so the tools keep the flops together). both reset polarities
  come off the same synchronizer so they cannot disagree by a cycle. led
  map: status bits on led[2:0], overrun/frame_err/resp_err/cmd_err on
  led[6:3], heartbeat on led[15] so a dead clock is distinguishable from a
  dead cipher. frame_err and overrun latch - a one cycle blink at 100 MHz
  is invisible.
  tbs. tb_uart_axi_bridge drives the byte interface directly with a stub
  standing in for uart_tx - deliberately not uart_tx, same both-ends-mine
  trap as the bfm, and the stub's busy length is a knob (0, 1 and 40 cycles
  all tested). 53 blocks through the command protocol: ladder, fips kat,
  key-loaded-once streaming, junk resync, K/E/S bytes inside payloads taken
  as data, overrun, reset mid command and mid axi burst, soak, the keyless
  'E', everything again stalled. tb_aes_uart_top is pin to pin - clk, btnC,
  RsRx, RsTx, led and nothing else - with the serial bit banged from the 8N1
  definition in both directions. runs at CLKS_PER_BIT=8 and checks by
  hierarchical reference that the parameter reaches both uart modules, since
  a divisor that only reached one of them would be invisible in a tb where
  both sides are wrong together. its sequence is literally the bring-up
  ladder I plan to type at the board. 13 blocks over the serial link.
  tb bugs I wrote so I do not write them again: the bridge tb watchdog was
  40us at first and fired on a perfectly good run - a watchdog is a test and
  it can be wrong in both directions, both tbs sit at 2ms now. and the tx
  stub's log array was [0:255], the soak walked off the end and ciphertexts
  came back full of X two thirds of the way through - it is 2048 deep now
  with an explicit overflow FAIL instead of nine confusing ones. I also
  pulled back out a second dut instance at the real 868 divisor - it worked
  but doubled elaboration to re-prove what tb_uart_tx already measured.
  basys3.xdc pins only what the design uses - an unconstrained port that
  nothing drives should be an error, not a warning to scroll past. false
  paths on RsRx and btnC (they are asynchronous, the synchronizers are the
  real fix, constraining them would claim a relationship that does not
  exist) and on RsTx and the leds. CFGBVS/CONFIG_VOLTAGE are in there too,
  write_bitstream DRC-errors without them.
  build_bitstream.tcl is non project mode on purpose: the gui project is for
  poking at sims and the bitstream that goes on the board should not depend
  on whatever state it was left in. reads sources, builds, drops reports and
  the .bit under vivado/build (gitignored). two gotchas: read_xdc treats its
  argument as a list, so this repo's path splits on the space in "Personal
  Projects" and vivado goes hunting for Personal.xdc - wrap it in [list].
  and rtl/axi + rtl/uart each need their own glob, same trap
  create_project.tcl hit on 8/27. program.tcl loads the .bit over jtag,
  volatile on purpose while I iterate.
  the numbers, post route with real constraints this time instead of the
  batch synth estimate: 2410 lut / 2470 ff / 0 bram / 0 dsp. WNS +0.566,
  WHS +0.100 - met, but only just, which is what the checklist means.
  post synth WNS is +3.717 again, so the squeeze is all placement and
  routing: the worst path is still in key_expand (rnd mux -> sbox -> xor
  into round_keys), 7 logic levels but 79% of the delay is routing. phase 4
  has a real job now instead of a hypothetical one.
  host/board_kat.py talks the same three commands over pyserial. it runs the
  ladder A through E and then optionally lines of random_1000.txt. the
  ladder order is the point: A is all zero words so word order cannot be
  what failed, B moves only the plaintext, C only the key - the first rung
  that fails says which path is mirrored, and repeatable wrong bytes vs
  different-every-run garbage separates a bridge bug from a link problem.
  next: plug the board in, program it, run the ladder for real. no com port
  showed up when I checked, so the board demo waits for the cable.
