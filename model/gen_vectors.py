"""Generates the test vector files the SystemVerilog testbenches read.

Writes into vectors/:
  sbox.txt               - the 256 sbox values (for the sbox tb)
  fips197_kat.txt        - the FIPS-197 Appendix B known answer vector
  fips197_roundkeys.txt  - 11 round keys for the Appendix A key (for the key_expand tb)
  roundkeys2.txt         - 11 round keys for the Appendix C.1 key, so the
                           key_expand tb's second run uses a different key
  random_1000.txt        - random vectors, seeded so the files are reproducible
  roundstep.txt          - per-step vectors for the subbytes/shiftrows/mixcolumns tbs

Vector file format is one vector per line, three 32-digit hex values:
  <key> <plaintext> <ciphertext>
which the testbench reads with $fscanf(fd, "%h %h %h", key, pt, ct).

The roundkeys file is just 11 lines of 32-digit hex, rk[0] (= the key) first.

roundstep.txt is four 32-digit hex values per line:
  <state> <subbytes(state)> <shiftrows(state)> <mixcolumns(state)>
each transform applied to the same input state independently, so one file
covers all three module testbenches.

usage: python gen_vectors.py [-n N] [--seed S]
"""

import argparse
import random
from pathlib import Path

from aes_ref import SBOX, encrypt_block, expand_key, mix_columns, shift_rows, sub_bytes

FIPS_KEY = "2b7e151628aed2a6abf7158809cf4f3c"
FIPS_PT = "3243f6a8885a308d313198a2e0370734"
FIPS_CT = "3925841d02dc09fbdc118597196a0b32"

# vectors/ dir next to model/
VECTORS_DIR = Path(__file__).resolve().parent.parent / "vectors"


def vector_line(key, pt):
    ct = encrypt_block(key, pt)  # encrypt_block asserts against pycryptodome
    return f"{key.hex()} {pt.hex()} {ct.hex()}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=1000, help="number of random vectors")
    ap.add_argument("--seed", type=int, default=1, help="rng seed")
    args = ap.parse_args()

    VECTORS_DIR.mkdir(exist_ok=True)

    # sbox table, one hex byte per line, for $readmemh in the sbox tb
    (VECTORS_DIR / "sbox.txt").write_text("".join(f"{b:02x}\n" for b in SBOX))
    print("wrote sbox.txt")

    # FIPS-197 known answer vector
    kat = vector_line(bytes.fromhex(FIPS_KEY), bytes.fromhex(FIPS_PT))
    assert kat.split()[2] == FIPS_CT
    (VECTORS_DIR / "fips197_kat.txt").write_text(kat + "\n")
    print("wrote fips197_kat.txt")

    # round keys for the key_expand testbench
    rks = expand_key(bytes.fromhex(FIPS_KEY))
    (VECTORS_DIR / "fips197_roundkeys.txt").write_text("".join(rk.hex() + "\n" for rk in rks))
    print("wrote fips197_roundkeys.txt")

    # second round key set (the appendix c.1 key) for the key_expand tb's
    # restart test. both runs using the same key meant a restart that quietly
    # kept the old keys still passed, so run 2 needs different expected values.
    rks2 = expand_key(bytes.fromhex("000102030405060708090a0b0c0d0e0f"))
    (VECTORS_DIR / "roundkeys2.txt").write_text("".join(rk.hex() + "\n" for rk in rks2))
    print("wrote roundkeys2.txt")

    # random vectors, plus a few edge cases first (all 0s, all FFs, counting)
    rng = random.Random(args.seed)
    edge = [bytes(16), bytes([0xFF] * 16), bytes(range(16))]
    lines = [vector_line(k, p) for k in edge for p in edge]
    while len(lines) < args.n:
        lines.append(vector_line(rng.randbytes(16), rng.randbytes(16)))
    (VECTORS_DIR / f"random_{args.n}.txt").write_text("\n".join(lines[:args.n]) + "\n")
    print(f"wrote random_{args.n}.txt (seed={args.seed})")

    # per-step vectors for the round function modules. same edge cases, plus
    # the round 1 input state from appendix b so I can eyeball the tb output
    # against the spec table, then random states
    states = edge + [bytes.fromhex("193de3bea0f4e22b9ac68d2ae9f84808")]
    while len(states) < 500:
        states.append(rng.randbytes(16))
    step_lines = []
    for s in states:
        s = list(s)
        step_lines.append(f"{bytes(s).hex()} {bytes(sub_bytes(s)).hex()} "
                          f"{bytes(shift_rows(s)).hex()} {bytes(mix_columns(s)).hex()}")
    (VECTORS_DIR / "roundstep.txt").write_text("\n".join(step_lines) + "\n")
    print("wrote roundstep.txt")


if __name__ == "__main__":
    main()
