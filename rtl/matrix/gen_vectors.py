"""Generate expected matrix vectors for matrix_generator testbench.

Uses the reference kheavyhash implementation to produce expected matrix
contents for known PrePowHash seeds that achieve full rank on the first attempt.
"""

import struct
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../software/referance"))
from kheavyhash_ref import KHeavyhash


def xoshiro256pp_init(seed_bytes):
    """Init PRNG state using little-endian byte interpretation (matches reference)."""
    state = []
    for i in range(4):
        offset = i * 8
        value = struct.unpack("<Q", seed_bytes[offset : offset + 8])[0]
        state.append(value)
    return state


def rotl64(value, shift):
    shift = shift % 64
    return ((value << shift) | (value >> (64 - shift))) & 0xFFFFFFFFFFFFFFFF


def xoshiro256pp_next(state):
    result = (state[0] + state[3]) & 0xFFFFFFFFFFFFFFFF
    result = rotl64(result, 23)
    result = (result + state[0]) & 0xFFFFFFFFFFFFFFFF

    t = (state[1] << 17) & 0xFFFFFFFFFFFFFFFF

    state[2] ^= state[0]
    state[3] ^= state[1]
    state[1] ^= state[2]
    state[0] ^= state[3]

    state[2] ^= t
    state[3] = rotl64(state[3], 45)

    return result


def generate_matrix(seed_bytes):
    """Generate 64x64 matrix matching reference (little-endian seed init)."""
    state = xoshiro256pp_init(seed_bytes)
    matrix = []
    for _ in range(64):
        row = []
        for _ in range(4):  # 4 PRNG calls per row, 16 nibbles each
            rand_val = xoshiro256pp_next(state)
            for k in range(16):
                element = (rand_val >> (k * 4)) & 0xF
                row.append(element)
        matrix.append(row)
    return matrix


def check_full_rank(matrix):
    """Check if matrix has full rank using Gaussian elimination (matches reference)."""
    n = len(matrix)
    eps = 1e-9
    B = [[float(matrix[i][j]) for j in range(n)] for i in range(n)]
    rank = 0
    row_selected = [False] * n
    for i in range(n):
        j = 0
        while j < n:
            if not row_selected[j] and abs(B[j][i]) > eps:
                break
            j += 1
        if j != n:
            rank += 1
            row_selected[j] = True
            pivot = B[j][i]
            for p in range(i + 1, n):
                B[j][p] /= pivot
            for k in range(n):
                if k != j and abs(B[k][i]) > eps:
                    factor = B[k][i]
                    for p in range(i + 1, n):
                        B[k][p] -= B[j][p] * factor
    return rank == n


# Test seeds - find ones that are full rank on first attempt
TEST_SEEDS = [
    bytes.fromhex("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
    bytes.fromhex(
        "deadbeefcafebabe0123456789abcdef fedcba9876543210 aabbccddeeff0011".replace(
            " ", ""
        )
    ),
    bytes.fromhex("a" * 64),
]

ref = KHeavyhash()

seeds_used = []
for seed in TEST_SEEDS:
    matrix = generate_matrix(seed)
    if check_full_rank(matrix):
        ref_matrix = ref._generate_matrix(seed)
        assert matrix == ref_matrix, f"Matrix mismatch for seed {seed.hex()}"
        seeds_used.append((seed, matrix))
        print(f"Seed {seed.hex()}: full rank on first attempt ✓")
    else:
        print(f"Seed {seed.hex()}: NOT full rank on first attempt, skipping")

if not seeds_used:
    print("ERROR: No test seeds produced full-rank matrix on first attempt")
    sys.exit(1)

# Write vector file
# Format:
#   Line 0: number of test cases
#   For each test case:
#     Line: 256-bit PrePowHash (hex)
#     64 lines: each row as 256-bit hex (nibble[0] in LSB)
#
# Row encoding: element[0] in bits [3:0], element[1] in bits [7:4], ..., element[63] in bits [255:252]
# This matches the matrix_cache storage: matrix[row][col] stored at col*4 +: 4

with open("expected_matrix.mem", "w") as f:
    f.write(f"// {len(seeds_used)} test case(s)\n")
    for seed, matrix in seeds_used:
        # Write PrePowHash with bytes reversed so that $readmemh (MSB-first)
        # loads it such that PrePowHash[63:0] = LE(seed[0:8]), etc.
        f.write(f"{seed[::-1].hex()}\n")
        # Write each row
        for row_idx, row in enumerate(matrix):
            # Pack 64 nibbles into 256-bit value
            # element[0] at bits [3:0] (LSB), element[63] at bits [255:252] (MSB)
            val = 0
            for col in range(64):
                val |= (row[col] & 0xF) << (col * 4)
            f.write(f"{val:064x}\n")

print(f"\nWrote {len(seeds_used)} test case(s) to expected_matrix.mem")
