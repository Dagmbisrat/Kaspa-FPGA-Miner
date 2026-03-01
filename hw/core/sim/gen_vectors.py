#!/usr/bin/env python3
"""Generate test vectors for the kHeavyHash core testbench.

Each test in the .mem file is 10 x 64-bit hex words:
  Words 0-3 : pre_pow_hash   (4 lanes, little-endian 64-bit)
  Word  4   : timestamp      (64-bit unsigned)
  Word  5   : nonce          (64-bit unsigned)
  Words 6-9 : expected hash_out (4 lanes, little-endian 64-bit)

Requires: pip install pycryptodome
"""

import os
import struct
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REF_DIR = os.path.join(SCRIPT_DIR, "..", "..", "..", "software", "referance")
sys.path.insert(0, REF_DIR)

from kheavyhash_ref import KHeavyhash

PREPOW_LANES = 4
HASH_LANES   = 4


def bytes_to_lanes(b: bytes, num_lanes: int) -> list:
    """Convert bytes to N x 64-bit little-endian lanes, zero-padded."""
    padded = b.ljust(num_lanes * 8, b"\x00")
    return list(struct.unpack(f"<{num_lanes}Q", padded))


def build_test_cases() -> list:
    """
    Build ~100 test cases across several categories:
      - Spec vector
      - Same pre_pow_hash, many sequential nonces  (cache-hit path)
      - Same pre_pow_hash, varying timestamps
      - Several distinct blocks, each with a run of nonces
      - Random pre_pow_hash blocks
    Note: all-zero pre_pow_hash is a degenerate xoshiro256++ seed and is excluded.
    """
    cases = []

    # -------------------------------------------------------------------------
    # 1. Spec test vector (1 test)
    # -------------------------------------------------------------------------
    cases.append((
        bytes.fromhex("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
        1_234_567_890,
        100,
    ))

    # -------------------------------------------------------------------------
    # 2. Same pre_pow_hash, 20 sequential nonces  (exercises cache-hit path)
    # -------------------------------------------------------------------------
    block_a = bytes.fromhex("deadbeefcafebabe0123456789abcdef0123456789abcdeffeedfacedeadbeef")
    ts_a    = 1_700_000_000
    for nonce in range(20):
        cases.append((block_a, ts_a, nonce))

    # -------------------------------------------------------------------------
    # 3. Same pre_pow_hash, varying timestamps  (nonce fixed, ts changes)
    # -------------------------------------------------------------------------
    block_b = bytes.fromhex("aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899")
    for i in range(10):
        cases.append((block_b, 1_600_000_000 + i * 1_000, 42))

    # -------------------------------------------------------------------------
    # 4. Several distinct blocks, each with a run of nonces
    # -------------------------------------------------------------------------
    distinct_blocks = [
        bytes.fromhex("0102030405060708010203040506070801020304050607080102030405060708"),
        bytes.fromhex("1122334455667788990011223344556677889900112233445566778899001122"),
        bytes.fromhex("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"),
        bytes.fromhex("cafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00d"),
    ]
    for block in distinct_blocks:
        ts = 1_750_000_000
        for nonce in [0, 1, 7, 99, 1000, 0xDEAD, 0xFFFFFFFF]:
            cases.append((block, ts, nonce))

    # -------------------------------------------------------------------------
    # 5. Random pre_pow_hash blocks (use os.urandom, exclude all-zero)
    # -------------------------------------------------------------------------
    import random
    rng = random.Random(0xCA5EA)  # deterministic seed for reproducibility
    for _ in range(100 - len(cases)):
        raw = bytes(rng.randint(1, 255) for _ in range(32))  # no all-zero
        ts    = rng.randint(1_000_000_000, 2_000_000_000)
        nonce = rng.randint(0, 0xFFFFFFFFFFFFFFFF)
        cases.append((raw, ts, nonce))

    return cases[:100]  # cap at exactly 100


def main():
    test_cases = build_test_cases()
    khash = KHeavyhash()
    lines = []

    for i, (pre_pow_hash, timestamp, nonce) in enumerate(test_cases):
        expected = khash.hash(pre_pow_hash, timestamp, nonce)

        for lane in bytes_to_lanes(pre_pow_hash, PREPOW_LANES):
            lines.append(f"{lane:016x}")
        lines.append(f"{timestamp:016x}")
        lines.append(f"{nonce:016x}")
        for lane in bytes_to_lanes(expected, HASH_LANES):
            lines.append(f"{lane:016x}")

        print(f"Test {i:3d}: pre_pow_hash={pre_pow_hash.hex()[:16]}...  "
              f"ts={timestamp}  nonce={nonce}  "
              f"hash={expected.hex()[:16]}...")

    out_path = os.path.join(SCRIPT_DIR, "expected_vectors.mem")
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"\nWrote {len(test_cases)} tests ({len(lines)} words) to {out_path}")


if __name__ == "__main__":
    main()
