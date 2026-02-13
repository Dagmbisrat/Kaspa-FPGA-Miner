"""Generate test vectors for xoshiro256pp SystemVerilog testbench."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..', 'software', 'referance'))

from kheavyhash_ref import KHeavyhash

kh = KHeavyhash()

# Same seed as testbench
state = [0x1234567890ABCDEF, 0xFEDCBA0987654321, 0xA5A5A5A5A5A5A5A5, 0x5A5A5A5A5A5A5A5A]

for i in range(10):
    s0, s1, s2, s3 = state
    result = kh._xoshiro256pp_next(state)

    print(f"// Iteration {i}")
    print(f"expected_out[{i}] = 64'h{result:016X};")
    print(f"expected_s0[{i}]  = 64'h{state[0]:016X};")
    print(f"expected_s1[{i}]  = 64'h{state[1]:016X};")
    print(f"expected_s2[{i}]  = 64'h{state[2]:016X};")
    print(f"expected_s3[{i}]  = 64'h{state[3]:016X};")
    print()
