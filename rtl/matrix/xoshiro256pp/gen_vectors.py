"""Generate test vectors for xoshiro256pp SystemVerilog testbench."""

import os
import sys

sys.path.insert(
    0,
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "software", "referance"),
)

from kheavyhash_ref import KHeavyhash

NUM_ITERS = 10
SEED = [0x1234567890ABCDEF, 0xFEDCBA0987654321, 0xA5A5A5A5A5A5A5A5, 0x5A5A5A5A5A5A5A5A]

kh = KHeavyhash()
state = list(SEED)

out_dir = os.path.dirname(os.path.abspath(__file__))

with open(os.path.join(out_dir, "expected_vectors.mem"), "w") as f:
    # Line 0: seed values (out=0, s0, s1, s2, s3) packed as one 320-bit hex word
    f.write(f"// seed: out s0 s1 s2 s3\n")
    f.write(f"{0:016X}{SEED[0]:016X}{SEED[1]:016X}{SEED[2]:016X}{SEED[3]:016X}\n")
    f.write(f"// iterations: out s0 s1 s2 s3\n")
    for i in range(NUM_ITERS):
        result = kh._xoshiro256pp_next(state)
        f.write(
            f"{result:016X}{state[0]:016X}{state[1]:016X}{state[2]:016X}{state[3]:016X}\n"
        )

print(f"Generated {NUM_ITERS} test vectors to expected_vectors.mem")
