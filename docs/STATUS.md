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
- [ ] key_expand.sv + tb (all 11 round keys vs fips197_roundkeys.txt)
- [ ] round function (subbytes/shiftrows/mixcolumns/addroundkey)
- [ ] aes_core.sv - FSM + top level
- [ ] core tb: FIPS KAT + random_1000.txt

Phase 2 - AXI4-Lite wrapper
- [ ] register map written down in docs/
- [ ] AXI4-Lite slave wrapper in rtl/axi/
- [ ] AXI testbench (BFM or Vivado AXI VIP)

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
