#!/usr/bin/env python3
"""
Confirm the kHeavyHash target-compare byte order against a real Kaspa block.

The RTL compares `hash_out <= target`, where hash_out equals the hash bytes read
little-endian (byte 0 in the low bits). This tool computes the reference hash for
a known-accepted block and reports which byte order makes `hash <= target` true —
that order is kaspad's convention.

  - little-endian passes  -> RTL is already correct (no byte swap)
  - big-endian passes     -> byte-reverse hash_out before the compare

Usage:
    python3 check_target_order.py <pre_pow_hash_hex> <timestamp> <nonce> <target_hex>

  target_hex: 64-hex-digit (256-bit) target as a big-endian number, e.g. the
              value obtained by expanding the block's compact "bits".
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from kheavyhash_ref import KHeavyhash  # noqa: E402


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)

    pph = bytes.fromhex(sys.argv[1])
    ts = int(sys.argv[2])
    nonce = int(sys.argv[3])
    target = int(sys.argv[4], 16)
    if len(pph) != 32:
        print("pre_pow_hash must be 32 bytes (64 hex chars)")
        sys.exit(1)

    h = KHeavyhash().hash(pph, ts, nonce)
    le = int.from_bytes(h, "little")   # == RTL hash_out
    be = int.from_bytes(h, "big")

    print(f"hash            : {h.hex()}")
    print(f"target          : {target:064x}")
    print(f"hash (LE, = RTL): {le:064x}  <= target ? {le <= target}")
    print(f"hash (BE)       : {be:064x}  <= target ? {be <= target}")
    print()
    if le <= target and not (be <= target):
        print("=> kaspad uses LITTLE-endian. RTL `hash_out <= target` is CORRECT (no swap).")
    elif (be <= target) and not (le <= target):
        print("=> kaspad uses BIG-endian. Byte-REVERSE hash_out before the RTL compare.")
    elif le <= target and be <= target:
        print("=> both pass (target too loose to disambiguate). Try a tighter/real target.")
    else:
        print("=> neither passes. Check the inputs (pph/ts/nonce/target) - not a valid block?")


if __name__ == "__main__":
    main()
