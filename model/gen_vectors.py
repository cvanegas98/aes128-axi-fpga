"""Generates the test vector files the SystemVerilog testbenches read.

Writes into vectors/:
  fips197_kat.txt        - the FIPS-197 Appendix B known answer vector
  fips197_roundkeys.txt  - 11 round keys for the Appendix A key (for the key_expand tb)
  random_1000.txt        - random vectors, seeded so the files are reproducible

Vector file format is one vector per line, three 32-digit hex values:
  <key> <plaintext> <ciphertext>
which the testbench reads with $fscanf(fd, "%h %h %h", key, pt, ct).

The roundkeys file is just 11 lines of 32-digit hex, rk[0] (= the key) first.

usage: python gen_vectors.py [-n N] [--seed S]
"""

import argparse
import random
from pathlib import Path

from aes_ref import encrypt_block, expand_key

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

    # FIPS-197 known answer vector
    kat = vector_line(bytes.fromhex(FIPS_KEY), bytes.fromhex(FIPS_PT))
    assert kat.split()[2] == FIPS_CT
    (VECTORS_DIR / "fips197_kat.txt").write_text(kat + "\n")
    print("wrote fips197_kat.txt")

    # round keys for the key_expand testbench
    rks = expand_key(bytes.fromhex(FIPS_KEY))
    (VECTORS_DIR / "fips197_roundkeys.txt").write_text("".join(rk.hex() + "\n" for rk in rks))
    print("wrote fips197_roundkeys.txt")

    # random vectors, plus a few edge cases first (all 0s, all FFs, counting)
    rng = random.Random(args.seed)
    edge = [bytes(16), bytes([0xFF] * 16), bytes(range(16))]
    lines = [vector_line(k, p) for k in edge for p in edge]
    while len(lines) < args.n:
        lines.append(vector_line(rng.randbytes(16), rng.randbytes(16)))
    (VECTORS_DIR / f"random_{args.n}.txt").write_text("\n".join(lines[:args.n]) + "\n")
    print(f"wrote random_{args.n}.txt (seed={args.seed})")


if __name__ == "__main__":
    main()
