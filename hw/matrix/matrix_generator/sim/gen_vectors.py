"""Generate expected matrix vectors for matrix_generator testbench.

Covers three seed categories:
  1. Fixed reference seeds   — deterministic, documented expected values
  2. SHA256-derived seeds     — wide coverage across the input space
  3. Random seeds             — broad statistical coverage (fixed RNG for reproducibility)

For every seed the reference KHeavyhash implementation is used to obtain the
final full-rank matrix, including seeds that require multiple PRNG attempts.
Vectors that fail to produce a full-rank matrix within 1000 attempts are skipped.
"""

import hashlib
import os
import random
import struct
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(
    0, os.path.join(SCRIPT_DIR, "../../../../software/referance")
)
from kheavyhash_ref import KHeavyhash

# ── PRNG helpers (must match RTL exactly) ────────────────────────────────────


def xoshiro256pp_init(seed_bytes):
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


def generate_matrix_single_attempt(seed_bytes):
    """One PRNG pass — 64 rows x 4 calls x 16 nibbles. Returns matrix only."""
    state = xoshiro256pp_init(seed_bytes)
    matrix = []
    for _ in range(64):
        row = []
        for _ in range(4):
            rand_val = xoshiro256pp_next(state)
            for k in range(16):
                row.append((rand_val >> (k * 4)) & 0xF)
        matrix.append(row)
    return matrix


def check_full_rank(matrix):
    """Gaussian elimination over floats — matches reference rank check."""
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


# ── Seed collection ───────────────────────────────────────────────────────────

seeds_raw = []

# Category 1: Fixed reference seeds
FIXED = [
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "deadbeefcafebabe0123456789abcdeffedcba9876543210aabbccddeeff0011",
    "a" * 64,
    "f" * 64,
    "0123456789abcdef" * 4,
    "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
    "1122334455667788990011223344556677889900112233445566778899001122",
    "cafebabe" * 8,
    "deadd00d" * 8,
    "c0ffee00" * 8,
]
for h in FIXED:
    seeds_raw.append(("fixed", bytes.fromhex(h)))

# Category 2: SHA256-derived seeds (wide, deterministic spread)
for i in range(20):
    digest = hashlib.sha256(f"kaspa_matrix_test_vector_{i:04d}".encode()).digest()
    seeds_raw.append(("sha256", digest))

# Category 3: Pseudo-random seeds (fixed RNG seed for reproducibility)
rng = random.Random(0xDEADBEEF)
for _ in range(20):
    seed = bytes(rng.randint(0, 255) for _ in range(32))
    seeds_raw.append(("random", seed))

# Deduplicate while preserving order
seen = set()
seeds = []
for category, s in seeds_raw:
    if s not in seen and s != bytes(32):  # skip all-zero (forbidden PRNG state)
        seen.add(s)
        seeds.append((category, s))

# ── Generate vectors ──────────────────────────────────────────────────────────

ref = KHeavyhash()

test_cases = []  # (seed, final_matrix, needed_regen)
needs_regen_count = 0
first_attempt_count = 0
skipped_count = 0

for category, seed in seeds:
    first_matrix = generate_matrix_single_attempt(seed)
    first_ok = check_full_rank(first_matrix)

    try:
        final_matrix = ref._generate_matrix(seed)
    except RuntimeError:
        print(
            f"  SKIP  [{category}] {seed.hex()}: could not reach full rank in 1000 attempts"
        )
        skipped_count += 1
        continue

    needed_regen = not first_ok
    if needed_regen:
        needs_regen_count += 1
        tag = "regen"
        print(f"  REGEN [{category}] {seed.hex()}")
    else:
        first_attempt_count += 1
        tag = "first"
        assert final_matrix == first_matrix, "Reference mismatch on first-attempt seed"
        print(f"  OK    [{category}] {seed.hex()}")

    test_cases.append((seed, final_matrix, tag))

# ── Write vector file ─────────────────────────────────────────────────────────
# Format (identical to original, $readmemh compatible):
#   One comment line per test case (skipped by $readmemh)
#   Line:   256-bit PrePowHash, bytes reversed so $readmemh MSB-first load gives
#           PrePowHash[63:0] = LE word 0, etc.
#   64 lines: each row packed as 256-bit hex, element[0] in bits [3:0] (LSB).

out_path = os.path.join(SCRIPT_DIR, "expected_matrix.mem")
with open(out_path, "w") as f:
    f.write(
        f"// {len(test_cases)} test case(s)  "
        f"({first_attempt_count} first-attempt, {needs_regen_count} regen, "
        f"{skipped_count} skipped)\n"
    )
    for seed, matrix, tag in test_cases:
        f.write(f"// [{tag}] {seed.hex()}\n")
        f.write(f"{seed[::-1].hex()}\n")
        for row in matrix:
            val = 0
            for col in range(64):
                val |= (row[col] & 0xF) << (col * 4)
            f.write(f"{val:064x}\n")

# ── Summary ───────────────────────────────────────────────────────────────────
total = len(test_cases)
print(f"\n{'═' * 52}")
print(f"  Total test cases : {total}")
print(f"  Full rank first  : {first_attempt_count}")
print(f"  Required regen   : {needs_regen_count}")
print(f"  Skipped          : {skipped_count}")
print(f"{'═' * 52}")
print(f"  Wrote {total} test case(s) to {out_path}")
print(f"  Update matrix_tb.sv:  parameter NUM_TESTS = {total};")
print(f"{'═' * 52}")
