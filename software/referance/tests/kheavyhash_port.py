"""Port script to test kHeavyHash with custom test vectors."""

import sys

from kheavyhash_ref import KHeavyhash


def main():
    if len(sys.argv) != 4:
        print("Usage: python port_test.py <pre_pow_hash_hex> <timestamp> <nonce>")
        print(
            "Example: python port_test.py 0000000000000000000000000000000000000000000000000000000000000000 0 0"
        )
        sys.exit(1)

    # Parse inputs
    pre_pow_hash = bytes.fromhex(sys.argv[1])
    timestamp = int(sys.argv[2])
    nonce = int(sys.argv[3])

    # Validate
    if len(pre_pow_hash) != 32:
        print("Error: pre_pow_hash must be 32 bytes (64 hex chars)")
        sys.exit(1)

    # Compute hash
    khash = KHeavyhash()
    result = khash.hash(pre_pow_hash, timestamp, nonce)

    # Print result
    print(result.hex())


if __name__ == "__main__":
    main()
