# cSHAKE256 - Customizable SHAKE256

## Overview

cSHAKE256 is a customizable extendable-output function (XOF) from NIST SP 800-185. It extends SHAKE256 with domain separation through two parameters:
- **N** (function-name): Function identifier
- **S** (customization): Additional customization string

**Key Properties:**
- Based on Keccak sponge construction
- Capacity: 512 bits (64 bytes)
- Rate: 1088 bits (136 bytes)
- Variable output length
- 256-bit security strength

## Usage in kHeavyHash

kHeavyHash uses cSHAKE256 twice with domain separation:

1. **Initial Hash**: `cSHAKE256(header, 32, N="", S="ProofOfWorkHash")`
2. **Final Hash**: `cSHAKE256(digest, 32, N="", S="HeavyHash")`

**Note**: In the Kaspa implementation (via Go and PyCryptodome), only the S parameter is used; N is always empty.

## Implementation

### Core Algorithm

```python
def cshake256(data, output_len, function_name="", customization=""):
    """
    NIST SP 800-185 cSHAKE256 implementation.
    
    Note: Kaspa implementation only uses customization (S parameter),
    with function_name (N parameter) always empty.
    """
    from Crypto.Util._raw_api import (VoidPointer, SmartPointer,
                                      create_string_buffer, get_raw_buffer,
                                      c_size_t, c_uint8_ptr, c_ubyte)
    from Crypto.Hash.keccak import _raw_keccak_lib
    
    # Encoding functions per NIST SP 800-185
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
        return left_encode(len(s) * 8) + s
    
    def bytepad(x, w):
        """Pad to multiple of w bytes."""
        z = left_encode(w) + x
        return z + b'\x00' * ((w - len(z) % w) % w)
    
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
        # prefix = bytepad(encode_string(N) || encode_string(S), rate)
        prefix_unpad = encode_string(function_name) + encode_string(customization)
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
    output_buffer = create_string_buffer(output_len)
    result = _raw_keccak_lib.keccak_squeeze(
        state_ptr.get(),
        output_buffer,
        c_size_t(output_len),
        c_ubyte(padding_byte)
    )
    if result:
        raise ValueError(f"Squeeze failed: {result}")
    
    return get_raw_buffer(output_buffer)
```

## Critical Implementation Details

### Padding Bytes
- **cSHAKE256**: Uses padding byte `0x04`
- **SHAKE256**: Uses padding byte `0x1F`

This difference means you **cannot** implement cSHAKE256 using `hashlib.shake_256()` (which hardcodes `0x1F` padding). You must use the raw Keccak primitive with explicit padding control.

### Encoding Functions

**left_encode(x)**: Encode integer with length prefix
```
left_encode(0)   → 0x01 0x00
left_encode(136) → 0x01 0x88
left_encode(256) → 0x02 0x01 0x00
```

**encode_string(S)**: Encode string with bit-length
```
encode_string("")     → 0x01 0x00
encode_string("ABC")  → 0x01 0x18 0x41 0x42 0x43
```

**bytepad(X, w)**: Pad to rate boundary
```
bytepad(X, 136) = left_encode(136) || X || 0x00...
```

### Kaspa/PyCryptodome Behavior

The reference implementations use:
- **N** (function-name): Always empty (`""` or `b""`)
- **S** (customization): Domain string (`"ProofOfWorkHash"` or `"HeavyHash"`)

Example:
```python
# Kaspa's usage via PyCryptodome
from Crypto.Hash import cSHAKE256

shake = cSHAKE256.new(custom=b"ProofOfWorkHash")
shake.update(header_data)
result = shake.read(32)
```

Internally, PyCryptodome's `cSHAKE256.new(custom=x)` does:
```python
cSHAKE_XOF(data=None, custom=x, capacity=512, function=b'')
```

So N is hardcoded to empty, and only S (custom) varies.

## Keccak Sponge Construction

### State Structure
- 1600-bit state: 25 lanes of 64 bits each
- Arranged as 5×5 matrix

### Absorbing Phase
```
For each rate-sized block:
  1. XOR block into first 'rate' bits of state
  2. Apply Keccak-f[1600] permutation (24 rounds)
```

### Squeezing Phase
```
While more output needed:
  1. Extract first 'rate' bits from state
  2. If more needed: Apply Keccak-f[1600] and repeat
```

### Keccak-f[1600] Permutation

Each round applies 5 transformations:
1. **θ (theta)**: Column parity mixing
2. **ρ (rho)**: Bit rotations
3. **π (pi)**: Lane permutation
4. **χ (chi)**: Non-linear mixing (only non-linear step)
5. **ι (iota)**: Round constant addition

24 rounds total, with different round constants per round.

## FPGA Implementation

### Resource Requirements
- **State**: 1600 bits (25 × 64-bit registers)
- **Logic**: ~8K-12K LUTs for single-round pipeline
- **Frequency**: 200-400 MHz typical
- **Throughput**: 136 bytes per 24 cycles (single core)

### Optimization Strategies
1. **Rate-aligned processing**: Handle 136-byte blocks efficiently
2. **Prefix caching**: Pre-compute domain separation prefixes
3. **Pipeline depth**: Trade latency for frequency
4. **Parallel cores**: Multiple independent instances for mining

### Typical Architecture
```
Input Buffer (136 bytes)
    ↓
State XOR
    ↓
Keccak-f[1600] (24 rounds)
    ↓
Output Extraction
```

## Security Properties

- **Preimage resistance**: 256 bits
- **Collision resistance**: 128 bits (birthday bound)
- **Domain separation**: Different (N,S) pairs are cryptographically independent

## References

- **NIST SP 800-185**: SHA-3 Derived Functions
- **NIST FIPS 202**: SHA-3 Standard
- **Keccak Team**: https://keccak.team/
- **PyCryptodome Source**: https://github.com/Legrandin/pycryptodome
