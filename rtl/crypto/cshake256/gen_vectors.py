#!/usr/bin/env python3
"""
Generate test vectors for cshake256_core.

Core interface:
  - data_in[255:0]  : 32-byte message
  - s_value          : 0 = S="ProofOfWorkHash", 1 = S="HeavyHash"
  - hash_out[255:0]  : 32-byte cSHAKE256 digest

Each test in the .mem file is 9 x 64-bit hex words:
  Word 0   : control  (bit 0 = s_value)
  Words 1-4: data_in  (4 lanes, little-endian)
  Words 5-8: expected hash (4 lanes, little-endian)

Requires: pip install pycryptodome
"""

import struct

from Crypto.Hash import cSHAKE256

S_STRINGS = {
    0: b"ProofOfWorkHash",
    1: b"HeavyHash",
}

# Test inputs: (s_value, data_in_bytes)
TEST_CASES = [
    # All zeros, ProofOfWorkHash
    (0, bytes(32)),
    # All zeros, HeavyHash
    (1, bytes(32)),
    # Incrementing bytes, ProofOfWorkHash
    (0, bytes(range(32))),
    # Incrementing bytes, HeavyHash
    (1, bytes(range(32))),
    # All 0xFF, ProofOfWorkHash
    (0, bytes([0xFF] * 32)),
    # All 0xFF, HeavyHash
    (1, bytes([0xFF] * 32)),
    # Single byte set, ProofOfWorkHash
    (0, b"\x01" + bytes(31)),
    # Random-ish pattern, HeavyHash
    (1, bytes([i ^ 0xA5 for i in range(32)])),
]


def bytes_to_lanes(b: bytes) -> list[int]:
    """Convert 32 bytes to 4 x 64-bit little-endian lanes."""
    assert len(b) == 32
    return list(struct.unpack("<4Q", b))


def compute_cshake256(s_value: int, data: bytes) -> bytes:
    """Compute cSHAKE256(X=data, N=b'', S=S_STRINGS[s_value]), 32-byte output."""
    h = cSHAKE256.new(data=data, custom=S_STRINGS[s_value])
    return h.read(32)


def main():
    lines = []
    for i, (s_val, data_in) in enumerate(TEST_CASES):
        expected = compute_cshake256(s_val, data_in)

        # Control word
        lines.append(f"{s_val:016x}")

        # data_in lanes
        for lane in bytes_to_lanes(data_in):
            lines.append(f"{lane:016x}")

        # expected hash lanes
        for lane in bytes_to_lanes(expected):
            lines.append(f"{lane:016x}")

        print(f"Test {i}: s_value={s_val} S={S_STRINGS[s_val].decode()!r}")
        print(f"  data_in : {data_in.hex()}")
        print(f"  expected: {expected.hex()}")

    with open("expected_vectors.mem", "w") as f:
        f.write("\n".join(lines) + "\n")

    print(
        f"\nWrote {len(TEST_CASES)} tests ({len(lines)} words) to expected_vectors.mem"
    )


if __name__ == "__main__":
    main()
