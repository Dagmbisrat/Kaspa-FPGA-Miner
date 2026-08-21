#!/usr/bin/env python3
"""
Generate matmul test vectors using the KHeavyHash Python reference.

The multiply + >>10 normalization is computed by the reference
KHeavyhash._matrix_vector_multiply, so the RTL is checked against the same
math as the production miner (software/referance/kheavyhash_ref.py).

expected_vectors.mem layout (all 256-bit / 64-hex-digit words):
   64 words      : matrix rows 0..63   plain packing   nibble c   = M[row][c]
   NUM_VEC words : input vectors        swapped packing nibble j^1 = v[j]
   NUM_VEC words : expected products    swapped packing nibble i^1 = r[i]

NUM_VEC must match the parameter of the same name in matmul_pipelined_tb.sv.
"""

import os
import sys
import random

# Import the reference implementation.
_REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(_REPO_ROOT, 'software', 'referance'))
from kheavyhash_ref import KHeavyhash  # noqa: E402

_KH        = KHeavyhash()
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
N          = 64
NUM_VEC    = 64            # must match matmul_pipelined_tb.sv

random.seed(0xC0FFEE)      # reproducible


def pack_plain(nibbles):
    """nibble c -> bits [c*4 +: 4]  (matches matrix_cache row packing)."""
    w = 0
    for c in range(N):
        w |= (nibbles[c] & 0xF) << (c * 4)
    return w


def pack_swapped(nibbles):
    """nibble j -> bits [(j^1)*4 +: 4]  (matches DUT vector/product packing)."""
    w = 0
    for j in range(N):
        w |= (nibbles[j] & 0xF) << ((j ^ 1) * 4)
    return w


def main():
    matrix = [[random.randint(0, 15) for _ in range(N)] for _ in range(N)]
    vectors = [[random.randint(0, 15) for _ in range(N)] for _ in range(NUM_VEC)]

    lines = []
    for r in range(N):
        lines.append(f"{pack_plain(matrix[r]):064x}")
    for v in vectors:
        lines.append(f"{pack_swapped(v):064x}")
    for v in vectors:
        result = _KH._matrix_vector_multiply(matrix, v)   # reference math
        lines.append(f"{pack_swapped(result):064x}")

    out_path = os.path.join(SCRIPT_DIR, "expected_vectors.mem")
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"N={N}  NUM_VEC={NUM_VEC}")
    print(f"Wrote {len(lines)} words ({N} matrix + {NUM_VEC} vec + "
          f"{NUM_VEC} expected) -> {out_path}")


if __name__ == "__main__":
    main()
