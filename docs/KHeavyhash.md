# kHeavyHash Algorithm - Technical Specification

## Overview

kHeavyHash is Kaspa's proof-of-work algorithm, derived from HeavyHash. It combines cryptographic hashing (cSHAKE256) with matrix multiplication to achieve memory-hardness while remaining efficient on general-purpose hardware.

**Key Properties:**

- Core-dominant (emphasizes parallel processing)
- Matrix-based computational bottleneck
- Memory-hard (resistant to ASIC optimization)
- Deterministic and hardware-friendly

**Reference Implementation:** https://github.com/bcutil/kheavyhash

## Algorithm Inputs (80 bytes)

1. **PrePowHash** (32 bytes): Block header hash (with timestamp=0, nonce=0)
2. **Timestamp** (8 bytes): UNIX timestamp (little-endian uint64)
3. **Padding** (32 bytes): All zeros
4. **Nonce** (8 bytes): Mining nonce (little-endian uint64)

## Critical Implementation Detail

**The matrix is seeded from PrePowHash, NOT from the first cSHAKE256 output!**

This means:

- Matrix is deterministic based on PrePowHash alone
- Matrix does NOT change when nonce or timestamp changes
- **Optimization**: Generate matrix once per PrePowHash, reuse for all nonce attempts

```
                    80-Byte Input
                    ┌─────────────────────────────────────┐
                    │ PrePowHash │ Time │ Zeros │ Nonce   │
                    └──────┬──────────────────┬───────────┘
                           │                  │
                   ┌───────┘                  └───────┐
                   │                                  │
                   │ (first 32 bytes)                 │ (all 80 bytes)
                   │                                  │
                   ▼                                  ▼
          ┌─────────────────┐            ┌──────────────────────┐
          │  xoshiro256++   │            │ cSHAKE256            │
          │  Matrix Seed    │            │ "ProofOfWorkHash"    │
          └────────┬────────┘            └──────────┬───────────┘
                   │                                │
                   ▼                                ▼
          ┌─────────────────┐            ┌─────────────────────┐
          │  64×64 Matrix   │            │ Vector (64 nibbles) │
          │  (full-rank)    │            │                     │
          └────────┬────────┘            └───────────┬─────────┘
                   │                                 │
                   └────────────┬────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │  Matrix × Vector      │
                    │  (product >> 10)      │
                    └───────────┬───────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │  XOR with powHash     │
                    └───────────┬───────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │  cSHAKE256            │
                    │  "HeavyHash"          │
                    └───────────┬───────────┘
                                │
                                ▼
                         Final Hash (32 bytes)
```

## Algorithm Steps

### Step 1: Construct 80-byte Header

```python
def _construct_header(self, pre_pow_hash: bytes, timestamp: int, nonce: int) -> bytes:
    """Construct 80-byte header from input components."""
    if len(pre_pow_hash) != 32:
        raise ValueError("pre_pow_hash must be exactly 32 bytes")

    # Pack timestamp and nonce as little-endian 64-bit integers
    timestamp_bytes = struct.pack("<Q", timestamp)
    nonce_bytes = struct.pack("<Q", nonce)

    # Construct: pre_pow_hash + timestamp + padding + nonce
    header = pre_pow_hash + timestamp_bytes + b"\x00" * 32 + nonce_bytes
    return header
```

### Step 2: Initial cSHAKE256 Hash

```python
# Using custom implementation with raw Keccak primitives
pow_hash = self._cshake256_myImplimentaion(header, 32, "", "ProofOfWorkHash")
# Result: 32-byte hash
```

**Domain separation**: Uses customization string "ProofOfWorkHash"

### Step 3: Generate 64×64 Matrix (from PrePowHash)

**Initialize xoshiro256++ PRNG:**

```python
def _init_xoshiro256pp(self, seed_bytes: bytes) -> List[int]:
    """Initialize xoshiro256++ PRNG state from 32-byte seed."""
    if len(seed_bytes) != 32:
        raise ValueError("seed_bytes must be exactly 32 bytes")

    state = []
    for i in range(4):
        offset = i * 8
        value = struct.unpack("<Q", seed_bytes[offset : offset + 8])[0]
        state.append(value)

    return state
```

**Generate matrix until full-rank:**

```python
def _generate_matrix(self, pre_pow_hash: bytes) -> List[List[int]]:
    """Generate 64x64 full-rank matrix from PrePowHash using xoshiro256++."""
    state = self._init_xoshiro256pp(pre_pow_hash)

    for attempt in range(1000):  # Max attempts
        matrix = []

        for i in range(64):
            row = []
            for _ in range(64):
                # Get next random value and extract 4 bits
                rand_val = self._xoshiro256pp_next(state)
                for k in range(16):  # 16 4-bit values per 64-bit random
                    element = (rand_val >> (k * 4)) & 0xF
                    row.append(element)
                    if len(row) == 64:
                        break
                if len(row) == 64:
                    break
            matrix.append(row)

        if self._check_matrix_rank(matrix):
            return matrix

    raise RuntimeError("Failed to generate full-rank matrix")
```

**Matrix properties:**

- 64×64 elements
- Each element is 4-bit value (0-15)
- Must be full-rank (linearly independent rows)
- Stored as 16-bit uint for computation

### Step 4: Create Vector from powHash

```python
def _create_vector_from_hash(self, hash_bytes: bytes) -> List[int]:
    """Convert 32-byte hash to 64-element vector of 4-bit values."""
    vector = []
    for byte in hash_bytes:
        upper_nibble = (byte >> 4) & 0xF
        lower_nibble = byte & 0xF
        vector.extend([upper_nibble, lower_nibble])
    return vector
```

### Step 5: Matrix-Vector Multiplication

```python
def _matrix_vector_multiply(self, matrix: List[List[int]], vector: List[int]) -> List[int]:
    """Multiply 64x64 matrix by 64-element vector with normalization."""
    result = []
    for i in range(64):
        dot_product = sum(matrix[i][j] * vector[j] for j in range(64))
        # Normalize by right-shifting 10 bits
        normalized_value = (dot_product >> 10) & 0xF
        result.append(normalized_value)
    return result
```

**Why shift by 10?**

- Max single product: 15 × 15 = 225
- Max sum of 64 products: 64 × 225 = 14,400 (14 bits)
- Shift right by 10: brings back to 4-bit range (0-15)

### Step 6: XOR Product with powHash

```python
def _xor_with_hash(self, product_vector: List[int], original_hash: bytes) -> bytes:
    """XOR the matrix multiplication result with the original powHash."""
    result = bytearray(32)
    for i in range(32):
        upper_nibble = product_vector[i * 2]
        lower_nibble = product_vector[i * 2 + 1]
        recombined_byte = (upper_nibble << 4) | lower_nibble
        xored_byte = recombined_byte ^ original_hash[i]
        result[i] = xored_byte
    return bytes(result)
```

### Step 7: Final cSHAKE256 Hash

```python
# Using custom implementation with raw Keccak primitives
final_hash = self._cshake256_myImplimentaion(digest, 32, "", "HeavyHash")
# Result: 32-byte final hash (no byte reversal)
```

**Domain separation**: Uses customization string "HeavyHash"

## Complete Pseudocode

```python
def hash(self, pre_pow_hash: bytes, timestamp: int, nonce: int) -> bytes:
    """Compute the complete kHeavyHash for given inputs."""
    # Step 1: Construct 80-byte header
    header = self._construct_header(pre_pow_hash, timestamp, nonce)

    # Step 2: Initial cSHAKE256 with "ProofOfWorkHash" domain
    pow_hash = self._cshake256_myImplimentaion(header, 32, "", "ProofOfWorkHash")

    # Step 3: Generate or retrieve cached matrix from pre_pow_hash
    matrix = self._generate_matrix(pre_pow_hash)

    # Step 4: Create 64-element vector from pow_hash
    vector = self._create_vector_from_hash(pow_hash)

    # Step 5: Matrix-vector multiplication with normalization
    product_vector = self._matrix_vector_multiply(matrix, vector)

    # Step 6: XOR product with original pow_hash
    digest = self._xor_with_hash(product_vector, pow_hash)

    # Step 7: Final cSHAKE256 with "HeavyHash" domain
    final_hash = self._cshake256_myImplimentaion(digest, 32, "", "HeavyHash")

    return final_hash
```

## xoshiro256++ PRNG

```python
def _xoshiro256pp_next(self, state: List[int]) -> int:
    """Generate next 64-bit pseudorandom number using xoshiro256++."""
    # xoshiro256++ algorithm
    result = (state[0] + state[3]) & 0xFFFFFFFFFFFFFFFF
    result = self._rotl64(result, 23)
    result = (result + state[0]) & 0xFFFFFFFFFFFFFFFF

    t = (state[1] << 17) & 0xFFFFFFFFFFFFFFFF

    state[2] ^= state[0]
    state[3] ^= state[1]
    state[1] ^= state[2]
    state[0] ^= state[3]

    state[2] ^= t
    state[3] = self._rotl64(state[3], 45)

    return result

def _rotl64(self, value: int, shift: int) -> int:
    """Rotate a 64-bit integer left by specified number of bits."""
    shift = shift % 64
    return ((value << shift) | (value >> (64 - shift))) & 0xFFFFFFFFFFFFFFFF
```

**Properties:**

- 256-bit state (4 × 64-bit words)
- Period: 2^256 - 1
- Passes BigCrush and PractRand tests
- Fast and hardware-friendly

## cSHAKE256 Usage

**First call:**

```python
pow_hash = self._cshake256_myImplimentaion(header, 32, "", "ProofOfWorkHash")
```

**Second call:**

```python
final_hash = self._cshake256_myImplimentaion(digest, 32, "", "HeavyHash")
```

**Note**: Kaspa implementation uses only the S (customization) parameter, with N (function-name) always empty. See `cSHAKE256.md` for details.

## FPGA Implementation Notes

### Resource Estimates (per core)

- **LUTs**: ~15K-25K (cSHAKE256 + matrix logic)
- **Registers**: ~3K-5K
- **BRAM**: 2-4 blocks (matrix storage)
- **DSP**: 64+ (matrix multiplication)
- **Frequency**: 200-400 MHz

### Optimization Strategies

1. **Matrix caching**: Generate once per PrePowHash, reuse for all nonces
2. **Parallel matrix multiply**: Use DSP slices for multiply-accumulate
3. **Pipeline cSHAKE256**: 24-cycle Keccak-f[1600] permutation
4. **Multiple cores**: Parallelize nonce search

### Linear Mining Architecture

```
Nonce Generator
      ↓
  cSHAKE256 Core (Step 2)
      ↓
  Vector Extractor (Step 4)
      ↓
  Matrix × Vector (Step 5) ← Matrix Cache (from PrePowHash)
      ↓
  XOR Logic (Step 6)
      ↓
  cSHAKE256 Core (Step 7)
      ↓
  Difficulty Check
```

## Test Vectors

### Example 1: Complete Test Vector

```
Input:
  PrePowHash:  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  Timestamp:   1234567890
  Nonce:       100

Output:
  Final Hash:  17a025e1b6d26e81c82b603cc0c1e10b13b782b2d75234b4bcb34a311206dee3
```

**Usage:**

```python
khash = KHeavyhash()
pre_pow_hash = bytes.fromhex('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef')
result = khash.hash(pre_pow_hash, 1234567890, 100)
assert result.hex() == '17a025e1b6d26e81c82b603cc0c1e10b13b782b2d75234b4bcb34a311206dee3'
```

### Validation

- Hash should be deterministic
- Same PrePowHash → same matrix
- Different nonces → different outputs
- Full-rank matrix requirement must be met

## Security Properties

- **Preimage resistance**: 256-bit (from cSHAKE256)
- **Collision resistance**: 128-bit (birthday bound)
- **Memory hardness**: From matrix storage requirement
- **Domain separation**: Cryptographic independence via cSHAKE256 customization

## References

- **Reference Implementation**: https://github.com/bcutil/kheavyhash
- **Kaspa GitHub**: https://github.com/kaspanet
- **NIST SP 800-185**: cSHAKE specification
- **xoshiro/xoroshiro**: http://prng.di.unimi.it/
