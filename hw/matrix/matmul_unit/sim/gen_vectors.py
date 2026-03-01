"""
Generate matmul_unit test vectors.

Output file: expected_vectors.mem
Format per test case (66 lines):
  line  0      : vector_in          (256-bit, nibble-swapped packing)
  lines 1-64   : matrix rows 0..63  (256-bit, LSB-first packing)
  line  65     : expected product    (256-bit, nibble-swapped packing)

Packing conventions:
  Matrix rows  — element j at bits [j*4 +: 4]  (LSB-first, matches matrix_cache)
  Vector / product — element j at bits [(j^1)*4 +: 4]  (nibble-swapped)
    j^1 swaps nibbles within each byte so that element 2k (the high nibble of
    byte k in Python convention) sits at bits [8k+7:8k+4], matching how the
    hardware reads vector_in and writes product_out after the j^1 fix.

Reference: software/referance/kheavyhash_ref.py _matrix_vector_multiply()
"""

import os
import sys

# Locate the reference implementation
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REF_DIR = os.path.join(SCRIPT_DIR, "..", "..", "..", "..", "software", "referance")
sys.path.insert(0, os.path.normpath(REF_DIR))

from kheavyhash_ref import KHeavyhash

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def pack256(nibbles: list[int]) -> int:
    """Pack 64 nibbles, element j at bits [j*4 +: 4]. Used for matrix rows."""
    val = 0
    for j, n in enumerate(nibbles):
        val |= (n & 0xF) << (j * 4)
    return val


def pack256_swapped(nibbles: list[int]) -> int:
    """Pack 64 nibbles, element j at bits [(j^1)*4 +: 4].

    Used for vector_in and product_out: j^1 swaps nibbles within each byte so
    that the high nibble of byte k (Python element 2k) sits at bits [8k+7:8k+4].
    """
    val = 0
    for j, n in enumerate(nibbles):
        val |= (n & 0xF) << ((j ^ 1) * 4)
    return val


def fmt256(val: int) -> str:
    """Format a 256-bit integer as a 64-character lowercase hex string."""
    return f"{val:064x}"


def random_nibble_vector() -> list[int]:
    """Return 64 random 4-bit values."""
    raw = os.urandom(32)
    nibbles = []
    for b in raw:
        nibbles.append((b >> 4) & 0xF)
        nibbles.append(b & 0xF)
    return nibbles


def matmul_ref(matrix: list[list[int]], vector: list[int]) -> list[int]:
    """Reference matrix-vector multiply (mirrors _matrix_vector_multiply)."""
    result = []
    for i in range(64):
        dot = sum(matrix[i][j] * vector[j] for j in range(64))
        result.append((dot >> 10) & 0xF)
    return result


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------


def generate(n_tests: int = 20, out_file: str = "expected_vectors.mem") -> None:
    ref = KHeavyhash()
    out_path = os.path.join(SCRIPT_DIR, out_file)

    first_attempt = regen = 0

    with open(out_path, "w") as f:
        for t in range(n_tests):
            pre_pow_hash = os.urandom(32)
            vector = random_nibble_vector()

            # Use the reference to build a full-rank matrix
            ref.clear_matrix_cache()
            matrix = ref._generate_matrix(pre_pow_hash)

            attempt = getattr(ref, "_last_attempt", 1)  # best-effort tracking
            if attempt == 1:
                first_attempt += 1
            else:
                regen += 1

            product = matmul_ref(matrix, vector)

            # Write test case (66 lines)
            f.write(f"// test {t}  pre_pow_hash={pre_pow_hash.hex()}\n")
            f.write(fmt256(pack256_swapped(vector)) + "\n")  # line 0:    vector_in  (swapped)
            for row in matrix:                               # lines 1-64: matrix rows (LSB-first)
                f.write(fmt256(pack256(row)) + "\n")
            f.write(fmt256(pack256_swapped(product)) + "\n") # line 65:   product    (swapped)

            print(
                f"test {t:3d}: vector={fmt256(pack256(vector))[:16]}..."
                f"  product={fmt256(pack256(product))[:16]}..."
            )

    print(f"\nWrote {n_tests} test(s) to {out_path}")
    print(f"({first_attempt} first-attempt, {regen} regen)")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Generate matmul_unit test vectors")
    parser.add_argument(
        "-n",
        "--num-tests",
        type=int,
        default=20,
        help="Number of test cases to generate (default: 20)",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="expected_vectors.mem",
        help="Output .mem filename (default: expected_vectors.mem)",
    )
    args = parser.parse_args()

    generate(args.num_tests, args.output)
