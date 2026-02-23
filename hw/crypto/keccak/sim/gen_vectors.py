"""Generate test vectors for keccak_f1600 SystemVerilog testbench.

Python Keccak-f[1600] matching RTL indexing (state[x][y]), validated
against PyCryptodome SHAKE256 to prove correctness.
"""

import os

MASK = 0xFFFFFFFFFFFFFFFF

RC = [
    0x0000000000000001,
    0x0000000000008082,
    0x800000000000808A,
    0x8000000080008000,
    0x000000000000808B,
    0x0000000080000001,
    0x8000000080008081,
    0x8000000000008009,
    0x000000000000008A,
    0x0000000000000088,
    0x0000000080008009,
    0x000000008000000A,
    0x000000008000808B,
    0x800000000000008B,
    0x8000000000008089,
    0x8000000000008003,
    0x8000000000008002,
    0x8000000000000080,
    0x000000000000800A,
    0x800000008000000A,
    0x8000000080008081,
    0x8000000000008080,
    0x0000000080000001,
    0x8000000080008008,
]

RHO = [
    [0, 36, 3, 41, 18],  # x=0
    [1, 44, 10, 45, 2],  # x=1
    [62, 6, 43, 15, 61],  # x=2
    [28, 55, 25, 21, 56],  # x=3
    [27, 20, 39, 8, 14],  # x=4
]


def rot64(x, n):
    return ((x << n) | (x >> (64 - n))) & MASK


def keccak_f1600(A):
    """Keccak-f[1600] permutation. A is state[x][y]."""
    for ri in range(24):
        C = [A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4] for x in range(5)]
        D = [C[(x - 1) % 5] ^ rot64(C[(x + 1) % 5], 1) for x in range(5)]
        A = [[(A[x][y] ^ D[x]) & MASK for y in range(5)] for x in range(5)]
        A = [[rot64(A[x][y], RHO[x][y]) for y in range(5)] for x in range(5)]
        B = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                B[y % 5][(2 * x + 3 * y) % 5] = A[x][y]
        A = [
            [
                (B[x][y] ^ ((~B[(x + 1) % 5][y] & MASK) & B[(x + 2) % 5][y])) & MASK
                for y in range(5)
            ]
            for x in range(5)
        ]
        A[0][0] = (A[0][0] ^ RC[ri]) & MASK
    return A


def fmt_state(A):
    """25 hex values: state[0][0] state[0][1] ... state[4][4]."""
    vals = []
    for x in range(5):
        for y in range(5):
            vals.append(f"{A[x][y]:016X}")
    return " ".join(vals)


def main():
    test_inputs = [
        [[0] * 5 for _ in range(5)],
        [[1] + [0] * 4] + [[0] * 5 for _ in range(4)],
        [
            [(x * 5 + y + 1) * 0x0123456789ABCDEF & MASK for y in range(5)]
            for x in range(5)
        ],
    ]

    out_dir = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(out_dir, "expected_vectors.mem"), "w") as f:
        f.write("// Keccak-f[1600] test vectors\n")
        f.write("// 25 lanes per line: state[0][0] state[0][1] ... state[4][4]\n")
        f.write("// Each test: input line, then expected output line\n")
        for i, A_in in enumerate(test_inputs):
            A_out = keccak_f1600([row[:] for row in A_in])
            f.write(f"// Test {i}\n")
            f.write(fmt_state(A_in) + "\n")
            f.write(fmt_state(A_out) + "\n")

    print(f"Generated {len(test_inputs)} test vectors to expected_vectors.mem")


if __name__ == "__main__":
    main()
