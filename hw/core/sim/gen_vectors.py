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

# Import reference implementation
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REF_DIR = os.path.join(SCRIPT_DIR, "..", "..", "..", "software", "referance")
sys.path.insert(0, REF_DIR)

from kheavyhash_ref import KHeavyhash

PREPOW_LANES = 4  # 256 bits / 64-bit lanes
HASH_LANES   = 4  # 256 bits / 64-bit lanes


def bytes_to_lanes(b: bytes, num_lanes: int) -> list:
    """Convert bytes to N x 64-bit little-endian lanes, zero-padded."""
    padded = b.ljust(num_lanes * 8, b"\x00")
    return list(struct.unpack(f"<{num_lanes}Q", padded))


# (pre_pow_hash, timestamp, nonce)
# Note: all-zero and all-0xFF pre_pow_hash are degenerate xoshiro256++ seeds
# (PRNG outputs all zeros forever) so they are excluded.
TEST_CASES = [
    # --- Spec test vector (docs/KHeavyhash.md) ---
    (
        bytes.fromhex("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
        1234567890,
        100,
    ),
    # --- Incrementing bytes ---
    (
        bytes(range(32)),
        1_000_000_000,
        42,
    ),
    # --- Same pre_pow_hash, different nonces (exercises matrix reuse path) ---
    (
        bytes.fromhex("deadbeefcafebabe0123456789abcdef0123456789abcdeffeedfacedeadbeef"),
        1_700_000_000,
        1,
    ),
    (
        bytes.fromhex("deadbeefcafebabe0123456789abcdef0123456789abcdeffeedfacedeadbeef"),
        1_700_000_000,
        2,
    ),
    (
        bytes.fromhex("deadbeefcafebabe0123456789abcdef0123456789abcdeffeedfacedeadbeef"),
        1_700_000_000,
        1000,
    ),
    # --- Different pre_pow_hash (forces matrix regeneration) ---
    (
        bytes.fromhex("aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"),
        9_999_999_999,
        7,
    ),
    # --- Another distinct block ---
    (
        bytes.fromhex("0102030405060708010203040506070801020304050607080102030405060708"),
        1_600_000_000,
        9999,
    ),
]


def main():
    khash = KHeavyhash()
    lines = []

    for i, (pre_pow_hash, timestamp, nonce) in enumerate(TEST_CASES):
        expected = khash.hash(pre_pow_hash, timestamp, nonce)

        # pre_pow_hash: 4 x 64-bit little-endian lanes → pre_pow_hash[63:0] .. [255:192]
        for lane in bytes_to_lanes(pre_pow_hash, PREPOW_LANES):
            lines.append(f"{lane:016x}")

        # timestamp and nonce (plain 64-bit values)
        lines.append(f"{timestamp:016x}")
        lines.append(f"{nonce:016x}")

        # expected hash_out: 4 x 64-bit little-endian lanes → hash_out[63:0] .. [255:192]
        for lane in bytes_to_lanes(expected, HASH_LANES):
            lines.append(f"{lane:016x}")

        print(f"Test {i}:")
        print(f"  pre_pow_hash : {pre_pow_hash.hex()}")
        print(f"  timestamp    : {timestamp}")
        print(f"  nonce        : {nonce}")
        print(f"  expected     : {expected.hex()}")

    out_path = os.path.join(SCRIPT_DIR, "expected_vectors.mem")
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"\nWrote {len(TEST_CASES)} tests ({len(lines)} words) to {out_path}")


if __name__ == "__main__":
    main()
