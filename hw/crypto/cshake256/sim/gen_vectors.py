#!/usr/bin/env python3
"""
Generate test vectors for cshake256_pipelined_core.

Hash computation
---------------
The hardware stage0 block is:
    left_encode(bitlen(X)) || X || 0x04 || zeros || 0x80

So to match the hardware we pre-encode X before passing it to the reference
cSHAKE implementation (which absorbs its data argument raw):

    encoded = left_encode(bitlen(X)) + X
    hash    = _cshake256_myImplimentaion(encoded, 32, "", S)

This is equivalent to the NIST encode_string(X) wrapping and matches
what the RTL sponge constants (SPONGE_POW / SPONGE_HH) were derived for.

Vector file layout (16 tests total):
  Words   0 – 119 : 8 HeavyHash tests      (s_value=1, 32-byte input)
  Words 120 – 239 : 8 ProofOfWorkHash tests (s_value=0, 80-byte input)

Each test block = 15 x 64-bit hex words:
  Word  0    : control  (bit 0 = s_value, bit 1 = data_80byte)
  Words 1-10 : data_in  (10 little-endian 64-bit lanes)
  Words 11-14: expected hash (4 little-endian 64-bit lanes)

Requires: pip install pycryptodome
"""

import os
import struct
import random
import sys

# ── Import reference cSHAKE implementation ───────────────────────────────────
# Repo layout:  hw/crypto/cshake256/sim/gen_vectors.py
#               software/referance/kheavyhash_ref.py
_REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(_REPO_ROOT, 'software', 'referance'))
from kheavyhash_ref import KHeavyhash  # noqa: E402

_KH = KHeavyhash()

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_LANES  = 10
HASH_LANES  = 4
S_NAMES     = {0: "ProofOfWorkHash", 1: "HeavyHash"}

random.seed(0xDEAD_BEEF)  # reproducible


def rand_bytes(n: int) -> bytes:
    return bytes(random.randint(0, 255) for _ in range(n))


# ── 8 HeavyHash tests  (s_value=1, 32-byte input) ───────────────────────────
HH_CASES = [
    (1, 0, bytes(range(32))),                                  # incrementing
    (1, 0, bytes([0xFF] * 32)),                                # all ones
    (1, 0, bytes([i ^ 0xA5 for i in range(32)])),             # XOR-A5
    (1, 0, bytes([i ^ 0x5A for i in range(32)])),             # XOR-5A
    (1, 0, bytes([0x01] + [0x00] * 31)),                      # single LSB
    (1, 0, bytes([(i * 31 + 7) & 0xFF for i in range(32)])),  # linear
    (1, 0, rand_bytes(32)),                                    # random-1
    (1, 0, rand_bytes(32)),                                    # random-2
]

# ── 8 ProofOfWorkHash tests  (s_value=0, 80-byte input) ─────────────────────
POW_CASES = [
    (0, 1, bytes(range(80))),                                  # incrementing
    (0, 1, bytes([0xFF] * 80)),                                # all ones
    (0, 1, bytes([i ^ 0xA5 for i in range(80)])),             # XOR-A5
    (0, 1, bytes([i ^ 0x5A for i in range(80)])),             # XOR-5A
    (0, 1, bytes([0x01] + [0x00] * 79)),                      # single LSB
    (0, 1, bytes([(i * 31 + 7) & 0xFF for i in range(80)])),  # linear
    (0, 1, rand_bytes(80)),                                    # random-1
    (0, 1, rand_bytes(80)),                                    # random-2
]

ALL_CASES = HH_CASES + POW_CASES
NUM_HH    = len(HH_CASES)   # must match NUM_HH_TESTS  in cshake256_tb.sv
NUM_POW   = len(POW_CASES)  # must match NUM_POW_TESTS in cshake256_tb.sv


def left_encode(value: int) -> bytes:
    """NIST SP 800-185 left_encode."""
    if value == 0:
        return b"\x01\x00"
    n = (value.bit_length() + 7) // 8
    return bytes([n]) + value.to_bytes(n, "big")


def cshake256_hash(s_val: int, data: bytes) -> bytes:
    """
    Compute the hash exactly as the RTL does.

    Stage0 places left_encode(bitlen(data)) before the raw bytes, so we
    pre-encode here before handing off to the reference implementation which
    absorbs its data argument raw (no length prefix of its own).
    """
    encoded = left_encode(len(data) * 8) + data   # = encode_string(data)
    return _KH._cshake256_myImplimentaion(encoded, 32, "", S_NAMES[s_val])


def bytes_to_lanes(b: bytes, num_lanes: int) -> list[int]:
    padded = b.ljust(num_lanes * 8, b"\x00")
    return list(struct.unpack(f"<{num_lanes}Q", padded))


def main() -> None:
    lines: list[str] = []

    for idx, (s_val, is_80, data) in enumerate(ALL_CASES):
        digest  = cshake256_hash(s_val, data)
        control = s_val | (is_80 << 1)
        lines.append(f"{control:016x}")

        for lane in bytes_to_lanes(data, DATA_LANES):
            lines.append(f"{lane:016x}")

        for lane in bytes_to_lanes(digest, HASH_LANES):
            lines.append(f"{lane:016x}")

        nbytes = 80 if is_80 else 32
        print(f"Test {idx:2d}  [{S_NAMES[s_val]:>15s}]  {nbytes:2d}B  "
              f"data={data[:6].hex()}…  hash={digest.hex()}")

    out_path = os.path.join(SCRIPT_DIR, "expected_vectors.mem")
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"\nGroups : {NUM_HH} HeavyHash + {NUM_POW} ProofOfWorkHash = {len(ALL_CASES)} tests")
    print(f"Wrote  : {len(lines)} words → {out_path}")


if __name__ == "__main__":
    main()
