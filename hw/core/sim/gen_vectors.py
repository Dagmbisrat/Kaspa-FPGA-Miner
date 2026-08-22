#!/usr/bin/env python3
"""Generate streaming test vectors for the kHeavyHash core testbench.

The core streams nonces internally (nonce_ctr increments from the base `nonce`).
Each PHASE fixes (pre_pow_hash, timestamp, base_nonce) and lists expected hashes
for base_nonce + i, i in [0, NVEC).

.mem layout (64-bit hex words), repeated for each phase:
  Words 0-3          : pre_pow_hash   (4 lanes, little-endian 64-bit)
  Word  4            : timestamp
  Word  5            : base nonce
  Words 6..6+4N-1    : NVEC expected hashes (4 lanes each, little-endian)

Phases (must match core_tb.sv params NVEC / NUM_PHASES):
  0: block A, fresh matrix generation
  1: block A again (cache-hit: matrix reused, different nonce base)
  2: block B, new matrix generation (block switch)

Requires: pip install pycryptodome
"""

import os
import struct
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "..", "..", "..", "software", "referance"))
from kheavyhash_ref import KHeavyhash  # noqa: E402

NVEC    = 32
TS      = 1_700_000_000
BLOCK_A = bytes.fromhex("deadbeefcafebabe0123456789abcdef0123456789abcdeffeedfacedeadbeef")
BLOCK_B = bytes.fromhex("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")

PHASES = [
    (BLOCK_A, TS, 100),
    (BLOCK_A, TS, 5000),
    (BLOCK_B, TS, 90000),
]


def lanes(b: bytes, n: int) -> list:
    return list(struct.unpack(f"<{n}Q", b.ljust(n * 8, b"\x00")))


def main():
    kh = KHeavyhash()
    lines = []
    for (pph, ts, base) in PHASES:
        for l in lanes(pph, 4):
            lines.append(f"{l:016x}")
        lines.append(f"{ts:016x}")
        lines.append(f"{base:016x}")
        for i in range(NVEC):
            h = kh.hash(pph, ts, base + i)
            for l in lanes(h, 4):
                lines.append(f"{l:016x}")
        print(f"phase pph={pph.hex()[:16]}... base={base} .. {base+NVEC-1}")
    out = os.path.join(SCRIPT_DIR, "expected_vectors.mem")
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"NVEC={NVEC} phases={len(PHASES)} -> {len(lines)} words -> {out}")


if __name__ == "__main__":
    main()
