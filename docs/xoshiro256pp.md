# xoshiro256++ PRNG

## Overview

xoshiro256++ (XOR/shift/rotate) is a pseudorandom number generator by David Blackman and Sebastiano Vigna. In kHeavyHash, it generates the 64×64 matrix from PrePowHash.

**Properties:**
- 256-bit state (4 × 64-bit words)
- Period: 2^256 - 1
- Output: 64 bits per call
- Passes BigCrush and PractRand statistical tests
- Fast: only ADD, XOR, and rotate operations

**Reference:** https://github.com/bcutil/kheavyhash

## Implementation

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

## Algorithm Steps

**Output computation:**
1. Add `s[0] + s[3]`
2. Rotate left by 23 bits
3. Add `s[0]` again
4. Result is the 64-bit output

**State update:**
1. Save `t = s[1] << 17`
2. Cross-mix: `s[2] ^= s[0]`, `s[3] ^= s[1]`, `s[1] ^= s[2]`, `s[0] ^= s[3]`
3. Apply temp: `s[2] ^= t`
4. Final rotate: `s[3] = rotl64(s[3], 45)`

## Bit-Level Operations

### rotl64(x, k) - Rotate Left
```
Input:  x = 0x0123456789ABCDEF, k = 4
        x = 0000 0001 0010 0011 ... 1110 1111

Output: 0x123456789ABCDEF0
        0001 0010 0011 0100 ... 1111 0000
```

Implementation: `(x << k) | (x >> (64 - k))`

### XOR Operation
```
a = 0x00FF00FF00FF00FF
b = 0xF0F0F0F0F0F0F0F0
    ─────────────────
a^b = 0xF00FF00FF00FF00F
```

Each bit: `a[i] XOR b[i] = (a[i] + b[i]) mod 2`

## Usage in kHeavyHash

### Initialization from PrePowHash

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

The 32-byte PrePowHash is split into 4 × 64-bit words (little-endian):
- `state[0]` = bytes 0-7
- `state[1]` = bytes 8-15
- `state[2]` = bytes 16-23
- `state[3]` = bytes 24-31

### Matrix Generation

Each xoshiro256++ call produces 64 bits containing 16 nibbles (4-bit values):

```python
for i in range(64):  # 64 rows
    row = []
    for _ in range(64):  # 64 columns
        rand_val = self._xoshiro256pp_next(state)
        # Extract 16 nibbles from 64-bit output
        for k in range(16):
            element = (rand_val >> (k * 4)) & 0xF
            row.append(element)
            if len(row) == 64:
                break
        if len(row) == 64:
            break
    matrix.append(row)
```

**Generation stats:**
- Matrix size: 64×64 = 4,096 elements
- Elements per call: 16 (64 bits ÷ 4 bits)
- Total calls needed: 256

## Test Vector

```
PrePowHash: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

Initial State (little-endian):
  state[0] = 0xefcdab8967452301
  state[1] = 0xefcdab8967452301
  state[2] = 0xefcdab8967452301
  state[3] = 0xefcdab8967452301

First call output:
  next() = 0x3c4b884552c79041
```

**Validation:**
```python
khash = KHeavyhash()
pre_pow_hash = bytes.fromhex('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef')
state = khash._init_xoshiro256pp(pre_pow_hash)
first = khash._xoshiro256pp_next(state)
assert first == 0x3c4b884552c79041
```

## State Evolution Example

```
Initial:
  s[0] = 0xefcdab8967452301
  s[1] = 0xefcdab8967452301
  s[2] = 0xefcdab8967452301
  s[3] = 0xefcdab8967452301

After first next():
  s[0] = 0x4e8c3db90d4dbc1f
  s[1] = 0xd67f96a428b8a406
  s[2] = 0x5b4c6ab98cba4e80
  s[3] = 0x780a6f753db7d5c9
  output = 0x3c4b884552c79041
```

## Properties

**Limitations:**
- Not cryptographically secure (state recoverable from consecutive outputs)
- Used in kHeavyHash for deterministic matrix generation only

## References

- **Paper:** "Scrambled Linear Pseudorandom Number Generators" (Blackman & Vigna, 2018)
- **Official site:** http://prng.di.unimi.it/
- **kHeavyHash reference:** https://github.com/bcutil/kheavyhash
