# cSHAKE256 - Customizable SHAKE256

## Overview

cSHAKE256 is a customizable extendable-output function (XOF) from NIST SP 800-185. It extends SHAKE256 with domain separation through two parameters:
- **N** (function-name): Function identifier (always empty in Kaspa)
- **S** (customization): Domain separation string

**Properties:**
- Based on Keccak sponge construction
- Capacity: 512 bits (64 bytes)
- Rate: 1088 bits (136 bytes)
- Variable output length
- 256-bit security strength

**Reference:** https://github.com/bcutil/kheavyhash

## Usage in kHeavyHash

kHeavyHash uses cSHAKE256 twice with different customization strings:

1. **Initial hash**: `cSHAKE256(header, 32, N="", S="ProofOfWorkHash")`
2. **Final hash**: `cSHAKE256(digest, 32, N="", S="HeavyHash")`

**Note:** Kaspa implementation uses only S (customization), with N (function-name) always empty.

## Implementation

```python
def _cshake256_myImplimentaion(
    self,
    data: bytes,
    output_length: int,
    function_name: str = "",
    customization: str = "",
) -> bytes:
    """Compute cSHAKE256 hash with domain separation."""
    from Crypto.Util._raw_api import (VoidPointer, SmartPointer,
                                      create_string_buffer, get_raw_buffer,
                                      c_size_t, c_uint8_ptr, c_ubyte)
    from Crypto.Hash.keccak import _raw_keccak_lib
    
    def left_encode(x):
        """Encode integer with length prefix on left."""
        if x == 0:
            return b"\x01\x00"
        n = (x.bit_length() + 7) // 8
        return bytes([n]) + x.to_bytes(n, "big")
    
    def encode_string(s):
        """Encode string with bit-length prefix."""
        if isinstance(s, str):
            s = s.encode("utf-8")
        bitlen = len(s) * 8
        return left_encode(bitlen) + s
    
    def bytepad(x, w):
        """Pad to multiple of w bytes."""
        z = left_encode(w) + x
        npad = (w - len(z) % w) % w
        return z + b"\x00" * npad
    
    # Constants
    capacity = 512  # bits
    rate = 136      # bytes (1088 bits)
    
    # Initialize Keccak state
    state = VoidPointer()
    result = _raw_keccak_lib.keccak_init(
        state.address_of(),
        c_size_t(capacity // 8),
        c_ubyte(24)  # 24 rounds
    )
    if result:
        raise ValueError(f"Keccak init failed: {result}")
    
    state_ptr = SmartPointer(state.get(), _raw_keccak_lib.keccak_destroy)
    
    # Determine padding byte and build prefix
    if customization:
        # cSHAKE mode: build prefix with domain separation
        # N is always empty (b'') in Kaspa implementation
        prefix_unpad = encode_string(b"") + encode_string(customization)
        prefix = bytepad(prefix_unpad, rate)
        padding_byte = 0x04  # cSHAKE padding
        
        # Absorb prefix
        result = _raw_keccak_lib.keccak_absorb(
            state_ptr.get(),
            c_uint8_ptr(prefix),
            c_size_t(len(prefix))
        )
        if result:
            raise ValueError(f"Absorb prefix failed: {result}")
    else:
        # SHAKE256 mode (when both N and S are empty)
        padding_byte = 0x1F  # SHAKE padding
    
    # Absorb data
    result = _raw_keccak_lib.keccak_absorb(
        state_ptr.get(),
        c_uint8_ptr(data),
        c_size_t(len(data))
    )
    if result:
        raise ValueError(f"Absorb data failed: {result}")
    
    # Squeeze output
    output_buffer = create_string_buffer(output_length)
    result = _raw_keccak_lib.keccak_squeeze(
        state_ptr.get(),
        output_buffer,
        c_size_t(output_length),
        c_ubyte(padding_byte)
    )
    if result:
        raise ValueError(f"Squeeze failed: {result}")
    
    return get_raw_buffer(output_buffer)
```

## Algorithm Steps

1. **Encode customization**: Create prefix from N and S parameters
2. **Pad to rate**: Align prefix to 136-byte boundary
3. **Absorb prefix**: XOR prefix into Keccak state
4. **Absorb data**: XOR input data into state
5. **Squeeze output**: Extract desired number of bytes

## Encoding Functions

### left_encode(x)
Encode integer with length prefix on left:
```
left_encode(0)   → 0x01 0x00
left_encode(136) → 0x01 0x88
left_encode(256) → 0x02 0x01 0x00
```

### encode_string(s)
Encode string with bit-length:
```
encode_string("")     → 0x01 0x00
encode_string("ABC")  → 0x01 0x18 0x41 0x42 0x43
                        (0x18 = 24 bits = 3 bytes)
```

### bytepad(x, w)
Pad to rate boundary:
```
bytepad(x, 136) = left_encode(136) || x || 0x00...
                = 0x01 0x88 || x || padding
```

## Padding Bytes: The Critical Difference

**Why you cannot use `hashlib.shake_256()` for cSHAKE256:**

```
SHAKE256:  padding byte = 0x1F
cSHAKE256: padding byte = 0x04
```

The padding byte is applied during the final squeeze operation and affects the output. Python's `hashlib.shake_256()` hardcodes `0x1F`, making it impossible to implement cSHAKE256 correctly without raw Keccak access.

## Keccak Sponge Construction

### State Structure
- 1600-bit state = 25 lanes × 64 bits
- Arranged as 5×5 matrix
- Rate: 136 bytes (first 17 lanes)
- Capacity: 64 bytes (last 8 lanes)

### Absorbing Phase
```
For each 136-byte block:
  1. XOR block into first 136 bytes of state
  2. Apply Keccak-f[1600] permutation (24 rounds)
```

### Squeezing Phase
```
While more output needed:
  1. Extract first 136 bytes from state
  2. Apply Keccak-f[1600] if more output needed
  3. Repeat until desired length obtained
```

### Keccak-f[1600] Permutation

Each round applies 5 transformations (24 rounds total):

1. **θ (theta)**: XOR each bit with column parity
2. **ρ (rho)**: Rotate each lane by offset
3. **π (pi)**: Permute lane positions
4. **χ (chi)**: Non-linear mixing (only non-linear step)
5. **ι (iota)**: XOR round constant into lane[0]

## Bit-Level Example

### Input Absorption
```
State before XOR:
  Lane[0] = 0x0000000000000000
  Lane[1] = 0x0000000000000000
  ...

Input block (8 bytes = 1 lane):
  0x0123456789ABCDEF

State after XOR:
  Lane[0] = 0x0123456789ABCDEF
  Lane[1] = 0x0000000000000000
  ...

Then: Apply Keccak-f[1600] permutation
```

## Test Vectors

### Empty Input (SHAKE256 mode)
```
Input:  data = b"", N = "", S = ""
Output: (identical to SHAKE256)
```

### kHeavyHash: ProofOfWorkHash
```
Input:  data = 80-byte header
        N = ""
        S = "ProofOfWorkHash"
Output: 32 bytes (pow_hash)

Encoding:
  prefix = bytepad(encode_string(b"") + encode_string(b"ProofOfWorkHash"), 136)
  prefix = 0x01 0x88 0x01 0x00 0x01 0x90 "ProofOfWorkHash" 0x00...
           ^^^^^^^^  ^^^^^^^  ^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^ ^^^^^
           rate=136  N=""     S=18bytes  string content      padding
```

### kHeavyHash: HeavyHash
```
Input:  data = 32-byte digest
        N = ""
        S = "HeavyHash"
Output: 32 bytes (final hash)
```

## Complete Example

```python
khash = KHeavyhash()

# First cSHAKE256 call
header = bytes(80)  # Example 80-byte header
pow_hash = khash._cshake256_myImplimentaion(header, 32, "", "ProofOfWorkHash")
print(f"pow_hash: {pow_hash.hex()}")

# Second cSHAKE256 call
digest = bytes(32)  # Example 32-byte digest
final_hash = khash._cshake256_myImplimentaion(digest, 32, "", "HeavyHash")
print(f"final_hash: {final_hash.hex()}")
```

## Security Properties

- **Preimage resistance:** 256 bits
- **Collision resistance:** 128 bits (birthday bound)
- **Domain separation:** Different S values create cryptographically independent functions

## Properties

**Why domain separation matters:**
```
cSHAKE256(x, 32, "", "ProofOfWorkHash") ≠ cSHAKE256(x, 32, "", "HeavyHash")

Even with identical input x, different S values produce completely different outputs.
This prevents cross-protocol attacks and ensures cryptographic independence.
```

**Deterministic:**
- Same input + same customization = same output
- Required for blockchain consensus

**Extendable output:**
- Can produce any length output
- Output bits statistically independent

## References

- **NIST SP 800-185:** SHA-3 Derived Functions (official specification)
- **NIST FIPS 202:** SHA-3 Standard (Keccak specification)
- **Keccak Team:** https://keccak.team/
- **kHeavyHash reference:** https://github.com/bcutil/kheavyhash