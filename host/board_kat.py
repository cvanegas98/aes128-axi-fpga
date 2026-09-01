#!/usr/bin/env python3
"""Drives the board over serial and checks what comes back.

I wrote this to run the bring-up ladder without typing hex into a terminal.
It speaks the same three commands the bridge does:

    K + 16 bytes    load a key (no reply)
    E + 16 bytes    encrypt, 16 bytes come back
    S               one status byte comes back

Bytes go out most significant first, same as everywhere else in this project.

    python host/board_kat.py COM4              the ladder, A through E
    python host/board_kat.py COM4 --vectors 50 then 50 lines of random_1000

The ladder is in this order on purpose. In step A every input word is
identical, so word order cannot matter - if A fails it is the build, the
link, or DOUT ordering, not word order. B only changes the plaintext and C
only changes the key, so whichever one breaks tells me which path is
mirrored. Repeatable wrong ciphertext means the bridge got the word order
wrong; garbage that differs every run means the serial link.
"""

import argparse
import os
import sys

try:
    import serial
except ImportError:
    sys.exit("need pyserial: pip install pyserial")

BAUD = 115200

# vectors/random_1000.txt, the same values the sim uses
LADDER = [
    ("A  key 0, pt 0",
     "00000000000000000000000000000000",
     "00000000000000000000000000000000",
     "66e94bd4ef8a2c3b884cfa59ca342b2e"),
    ("B  key 0, pt 000102..0f",
     "00000000000000000000000000000000",
     "000102030405060708090a0b0c0d0e0f",
     "7aca0fd9bcd6ec7c9f97466616e6a282"),
    ("C  key 000102..0f, pt 0",
     "000102030405060708090a0b0c0d0e0f",
     "00000000000000000000000000000000",
     "c6a13b37878f5b826f4f8162a1c8d879"),
    ("D  both 000102..0f",
     "000102030405060708090a0b0c0d0e0f",
     "000102030405060708090a0b0c0d0e0f",
     "0a940bb5416ef045f1c39458c653ea5a"),
    ("E  FIPS-197 KAT",
     "2b7e151628aed2a6abf7158809cf4f3c",
     "3243f6a8885a308d313198a2e0370734",
     "3925841d02dc09fbdc118597196a0b32"),
]


def read_exact(port, n):
    """Read n bytes or give up. A short read is a real failure, not a retry -
    it means the board did not answer, so say so instead of hanging."""
    buf = bytearray()
    while len(buf) < n:
        chunk = port.read(n - len(buf))
        if not chunk:
            raise TimeoutError(
                "timed out waiting for %d bytes, got %d (%s)"
                % (n, len(buf), buf.hex()))
        buf += chunk
    return bytes(buf)


def status(port):
    port.write(b"S")
    return read_exact(port, 1)[0]


def load_key(port, key_hex):
    # K gets no reply. the key expansion is 11 clocks, which is nothing next
    # to one byte time, so by the time the next command byte lands it is
    # long done - but ask for status anyway so a wedged board shows up here
    # rather than three commands later.
    port.write(b"K" + bytes.fromhex(key_hex))
    st = status(port)
    if not st & 0x01:
        raise RuntimeError("KEY_READY never came up after K, STATUS = 0x%02x" % st)


def encrypt(port, pt_hex):
    port.write(b"E" + bytes.fromhex(pt_hex))
    return read_exact(port, 16).hex()


def decode_status(st):
    bits = []
    if st & 0x01:
        bits.append("key_ready")
    if st & 0x02:
        bits.append("busy")
    if st & 0x04:
        bits.append("done")
    return ", ".join(bits) if bits else "idle, nothing loaded"


def run_ladder(port):
    fails = 0
    for name, key, pt, want in LADDER:
        load_key(port, key)
        got = encrypt(port, pt)
        ok = got == want
        print("%-28s %s" % (name, "ok" if ok else "FAIL"))
        if not ok:
            print("    got  %s" % got)
            print("    want %s" % want)
            fails += 1
            # stop at the first rung. the whole point of the ladder is that
            # the first failure is the informative one - carrying on just
            # prints the same wrong thing four more times.
            break
    return fails


def run_vectors(port, path, limit):
    fails = 0
    n = 0
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) != 3:
                continue
            key, pt, want = parts
            load_key(port, key)
            got = encrypt(port, pt)
            n += 1
            if got != want:
                fails += 1
                print("FAIL line %d" % n)
                print("    key  %s" % key)
                print("    pt   %s" % pt)
                print("    got  %s" % got)
                print("    want %s" % want)
                if fails >= 5:
                    print("stopping after 5 failures")
                    break
            if n >= limit:
                break
    print("%d vectors, %d failures" % (n, fails))
    return fails


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", help="serial port, e.g. COM4 or /dev/ttyUSB1")
    ap.add_argument("--vectors", type=int, default=0,
                    help="also run this many lines of random_1000.txt")
    ap.add_argument("--file", default=None, help="vector file to use")
    args = ap.parse_args()

    vec = args.file
    if vec is None:
        here = os.path.dirname(os.path.abspath(__file__))
        vec = os.path.join(here, "..", "vectors", "random_1000.txt")

    # 2 seconds is forever for this board - a block is 11 clocks and 16 bytes
    # of reply is 1.4 ms. if nothing has come back in 2 s it is not coming.
    with serial.Serial(args.port, BAUD, timeout=2) as port:
        port.reset_input_buffer()
        st = status(port)
        print("STATUS 0x%02x  (%s)" % (st, decode_status(st)))

        fails = run_ladder(port)
        if fails == 0 and args.vectors:
            fails += run_vectors(port, vec, args.vectors)

    if fails:
        print("FAILED")
        return 1
    print("all good")
    return 0


if __name__ == "__main__":
    sys.exit(main())
