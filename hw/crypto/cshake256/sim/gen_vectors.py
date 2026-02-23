#!/usr/bin/env python3
"""
Generate test vectors for cshake256_core.

Core interface:
  - data_in[639:0]   : up to 80-byte message (640 bits)
  - data_80byte       : 0 = 32-byte input, 1 = 80-byte input
  - s_value           : 0 = S="ProofOfWorkHash", 1 = S="HeavyHash"
  - hash_out[255:0]   : 32-byte cSHAKE256 digest

Each test in the .mem file is 15 x 64-bit hex words:
  Word 0    : control  (bit 0 = s_value, bit 1 = data_80byte)
  Words 1-10: data_in  (10 lanes, little-endian, 640 bits)
  Words 11-14: expected hash (4 lanes, little-endian)

Requires: pip install pycryptodome
"""

import os
import struct

from Crypto.Hash import cSHAKE256

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

S_STRINGS = {
    0: b"ProofOfWorkHash",
    1: b"HeavyHash",
}

DATA_LANES = 10  # 640 bits / 64 = 10 lanes
HASH_LANES = 4   # 256 bits / 64 = 4 lanes

# Test inputs: (s_value, data_80byte, data_in_bytes)
TEST_CASES = [
    # --- 32-byte inputs (HeavyHash) ---
    # All zeros
    (1, 0, bytes(32)),
    # Incrementing bytes
    (1, 0, bytes(range(32))),
    # All 0xFF
    (1, 0, bytes([0xFF] * 32)),
    # Random-ish pattern
    (1, 0, bytes([i ^ 0xA5 for i in range(32)])),

    # --- 80-byte inputs (ProofOfWorkHash) ---
    # All zeros
    (0, 1, bytes(80)),
    # Incrementing bytes
    (0, 1, bytes(range(80))),
    # All 0xFF
    (0, 1, bytes([0xFF] * 80)),
    # Single byte set
    (0, 1, b"\x01" + bytes(79)),
    # Random-ish pattern
    (0, 1, bytes([i ^ 0xA5 for i in range(80)])),
    # Another pattern
    (0, 1, bytes([(i * 7 + 3) & 0xFF for i in range(80)])),
]


def bytes_to_lanes(b: bytes, num_lanes: int) -> list[int]:
    """Convert bytes to N x 64-bit little-endian lanes, zero-padded."""
    padded = b.ljust(num_lanes * 8, b"\x00")
    return list(struct.unpack(f"<{num_lanes}Q", padded))


def compute_cshake256(s_value: int, data: bytes) -> bytes:
    """Compute cSHAKE256(X=data, N=b'', S=S_STRINGS[s_value]), 32-byte output."""
    h = cSHAKE256.new(data=data, custom=S_STRINGS[s_value])
    return h.read(32)


def main():
    lines = []
    for i, (s_val, is_80byte, data_in) in enumerate(TEST_CASES):
        expected = compute_cshake256(s_val, data_in)

        # Control word: bit 0 = s_value, bit 1 = data_80byte
        control = s_val | (is_80byte << 1)
        lines.append(f"{control:016x}")

        # data_in lanes (10 x 64-bit, zero-padded for 32-byte inputs)
        for lane in bytes_to_lanes(data_in, DATA_LANES):
            lines.append(f"{lane:016x}")

        # expected hash lanes
        for lane in bytes_to_lanes(expected, HASH_LANES):
            lines.append(f"{lane:016x}")

        nbytes = 80 if is_80byte else 32
        print(f"Test {i}: s_value={s_val} data_80byte={is_80byte} ({nbytes}B) S={S_STRINGS[s_val].decode()!r}")
        print(f"  data_in : {data_in.hex()}")
        print(f"  expected: {expected.hex()}")

    out_path = os.path.join(SCRIPT_DIR, "expected_vectors.mem")
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(
        f"\nWrote {len(TEST_CASES)} tests ({len(lines)} words) to {out_path}"
    )


if __name__ == "__main__":
    main()
