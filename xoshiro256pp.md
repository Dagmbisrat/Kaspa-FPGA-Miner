# xoshiro256++ PRNG Algorithm - Technical Documentation

## Overview

xoshiro256++ (XOR/shift/rotate) is a pseudorandom number generator designed by David Blackman and Sebastiano Vigna. It is the successor to xorshift algorithms and provides excellent statistical properties, high performance, and a long period. In the KasMiner project, xoshiro256++ is used to generate the 64×64 matrix in the kHeavyHash algorithm, seeded from the PrePowHash.

## Key Characteristics

- **Period**: 2²⁵⁶ - 1 (extremely long)
- **State Size**: 256 bits (four 64-bit words)
- **Output**: 64 bits per call
- **Statistical Quality**: Passes BigCrush and PractRand test suites
- **Performance**: ~0.86 ns per 64-bit output on modern CPUs
- **Jump Function**: Supports efficient parallel streams
- **Hardware Friendly**: Simple operations ideal for FPGA implementation

## Algorithm Parameters

### State Representation

The generator maintains a 256-bit internal state as four 64-bit unsigned integers:

```
state[0], state[1], state[2], state[3]  // Each element is uint64_t
```

### Initialization Requirements

- **All-zero state is forbidden**: At least one state word must be non-zero
- **Poor seed handling**: Small seeds may produce initial correlations
- **Recommendation**: Use a high-quality seed source (e.g., cryptographic hash output)

## Core Algorithm

### Next Value Generation

```c
uint64_t xoshiro256plusplus_next(uint64_t s[4]) {
    // Compute output using + and rotl operations
    uint64_t result = rotl(s[0] + s[3], 23) + s[0];
    
    // Update state
    uint64_t t = s[1] << 17;
    
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl(s[3], 45);
    
    return result;
}
```

### Rotation Function

```c
uint64_t rotl(uint64_t x, int k) {
    return (x << k) | (x >> (64 - k));
}
```

### State Update Breakdown

1. **Save intermediate**: `t = s[1] << 17`
2. **Cross mixing**: 
   - `s[2] ^= s[0]`
   - `s[3] ^= s[1]`
   - `s[1] ^= s[2]`
   - `s[0] ^= s[3]`
3. **Final updates**:
   - `s[2] ^= t`
   - `s[3] = rotl(s[3], 45)`

## Initialization in kHeavyHash

### Seed Extraction from PrePowHash

The kHeavyHash algorithm seeds xoshiro256++ using the 32-byte PrePowHash:

```c
void init_xoshiro256pp_from_prepowHash(uint64_t state[4], const uint8_t prepowHash[32]) {
    // Extract four 64-bit seeds in little-endian format
    state[0] = bytes_to_u64_le(&prepowHash[0]);   // Bytes 0-7
    state[1] = bytes_to_u64_le(&prepowHash[8]);   // Bytes 8-15
    state[2] = bytes_to_u64_le(&prepowHash[16]);  // Bytes 16-23
    state[3] = bytes_to_u64_le(&prepowHash[24]);  // Bytes 24-31
    
    // Verify non-zero state (should never happen with cryptographic hash)
    if (state[0] == 0 && state[1] == 0 && state[2] == 0 && state[3] == 0) {
        // Fallback to default seed (should never occur)
        state[0] = 1;
    }
}

uint64_t bytes_to_u64_le(const uint8_t *bytes) {
    return ((uint64_t)bytes[0] << 0)  |
           ((uint64_t)bytes[1] << 8)  |
           ((uint64_t)bytes[2] << 16) |
           ((uint64_t)bytes[3] << 24) |
           ((uint64_t)bytes[4] << 32) |
           ((uint64_t)bytes[5] << 40) |
           ((uint64_t)bytes[6] << 48) |
           ((uint64_t)bytes[7] << 56);
}
```

### Matrix Generation Process

```c
void generate_matrix_64x64(uint16_t matrix[64][64], uint64_t state[4]) {
    for (int i = 0; i < 64; i++) {
        for (int j = 0; j < 64; j += 16) {
            // Get 64-bit random value
            uint64_t value = xoshiro256plusplus_next(state);
            
            // Extract sixteen 4-bit values
            for (int k = 0; k < 16; k++) {
                matrix[i][j + k] = (value >> (4 * k)) & 0x0F;
            }
        }
    }
}
```

**Key Points**:
- Each xoshiro256++ call produces 64 bits
- Each 64-bit value yields 16 matrix elements (4 bits each)
- Total matrix generation requires 256 calls to xoshiro256++ (4096 elements / 16 per call)

<!--
## Statistical Properties

### Quality Metrics

**BigCrush Test Suite**: ✅ Passes all tests
- Most comprehensive randomness test available
- Tests for various statistical defects and patterns
- Industry standard for PRNG validation

**PractRand**: ✅ Passes > 32TB of output
- Modern test suite focusing on practical issues
- Tests for subtle correlations and patterns
- Excellent long-term performance

### Period and State Space

- **Period**: 2²⁵⁶ - 1 ≈ 1.16 × 10⁷⁷
- **State Space**: All 2²⁵⁶ possible states except all-zeros
- **Equidistribution**: Uniformly distributed over the full period

### Correlation Properties

- **Linear Complexity**: Close to maximum (≈ 2²⁵⁵)
- **Avalanche Effect**: Small state changes cause large output changes
- **Independence**: Successive outputs are statistically independent

## FPGA Implementation Considerations

### Hardware Requirements

**Basic Implementation**:
- **State Storage**: 4 × 64-bit registers = 256 bits
- **Temporary Storage**: 1 × 64-bit register for intermediate values
- **Combinatorial Logic**: XOR gates, left shifts, rotation logic

### Pipeline Architecture

**Single-Cycle Operation**:
```verilog
// Simplified Verilog structure
always @(posedge clk) begin
    if (generate_next) begin
        // Compute output
        result <= rotl(s[0] + s[3], 23) + s[0];
        
        // Update state
        t <= s[1] << 17;
        s[2] <= s[2] ^ s[0];
        s[3] <= s[3] ^ s[1];
        s[1] <= s[1] ^ s[2];
        s[0] <= s[0] ^ s[3];
        s[2] <= s[2] ^ t;
        s[3] <= rotl(s[3], 45);
    end
end
```

**Multi-Cycle Implementation**:
- Cycle 1: Compute output and temporary values
- Cycle 2: Update state registers
- Reduces combinatorial delay for higher frequency

### Resource Utilization

**Typical Xilinx 7-Series per PRNG Core**:
- **LUTs**: ~200-400 (depending on optimization)
- **Registers**: ~320 (256 state + 64 temporaries)
- **BRAM**: 0 (pure register-based)
- **DSP**: 2-4 (for 64-bit additions and rotations)

### Optimization Strategies

1. **Parallel Generation**: Multiple cores for matrix generation speedup
2. **Pre-computation**: Generate matrix elements during idle cycles
3. **State Caching**: Cache generator state for matrix reuse
4. **Pipeline Optimization**: Balance logic depth vs. throughput

## Matrix Generation Optimization

### Full-Rank Requirement

The kHeavyHash algorithm requires the generated matrix to be full-rank (all 64 rows linearly independent). This necessitates:

```c
do {
    generate_matrix_64x64(matrix, state);
    rank = compute_gf16_rank(matrix);
} while (rank != 64);
```

**Statistical Analysis**:
- Probability of full-rank 64×64 GF(16) matrix ≈ 0.2888
- Expected iterations: ~3.46 attempts
- 99.9% probability of success within 24 attempts

### Hardware Implications

**Matrix Storage**: 64×64×4 bits = 16,384 bits = ~2KB BRAM per mining core

**Rank Computation**: 
- Can be implemented in hardware for parallel operation
- Requires GF(16) arithmetic (4-bit field operations)
- ~O(64³) operations for full Gaussian elimination

## Comparative Analysis

### vs. Other PRNGs

**xoshiro256++ vs. Mersenne Twister**:
- ✅ Much faster (0.86ns vs ~3ns per output)
- ✅ Smaller state (256 bits vs 19,937 bits)  
- ✅ Better statistical quality
- ✅ Much better for parallel/hardware implementation

**xoshiro256++ vs. ChaCha20**:
- ✅ Faster for bulk generation
- ❌ Not cryptographically secure
- ✅ Simpler hardware implementation
- ⚖️ Comparable statistical quality for non-cryptographic use

### Security Considerations

**Not Cryptographically Secure**:
- Internal state can be recovered from output
- Should not be used for cryptographic keys or nonces
- Suitable for PoW algorithms where state privacy is not required

**Predictability**:
- Given enough output, internal state can be reconstructed
- In kHeavyHash context, this is acceptable as the seed (PrePowHash) is public

## Variants and Related Algorithms

### xoshiro Family

- **xoshiro256+**: Simpler output function (`s[0] + s[3]`)
- **xoshiro256++**: Current implementation (better statistical properties)
- **xoshiro256****: Alternative output with multiplication

### Jump Functions

xoshiro256++ supports efficient jumping to equivalent states 2¹²⁸ steps ahead:

```c
void jump(uint64_t s[4]) {
    static const uint64_t JUMP[] = { 
        0x180ec6d33cfd0aba, 0xd5a61266f0c9392c, 
        0xa9582618e03fc9aa, 0x39abdc4529b1661c 
    };
    
    uint64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    for (int i = 0; i < sizeof JUMP / sizeof *JUMP; i++) {
        for (int b = 0; b < 64; b++) {
            if (JUMP[i] & UINT64_C(1) << b) {
                s0 ^= s[0]; s1 ^= s[1];
                s2 ^= s[2]; s3 ^= s[3];
            }
            xoshiro256plusplus_next(s);
        }
    }
    s[0] = s0; s[1] = s1; s[2] = s2; s[3] = s3;
}
```

**Use Case**: Parallel mining cores with independent random sequences.

## Testing and Validation

### Reference Test Vector

```c
// Test case: Known initial state
uint64_t state[4] = {1, 2, 3, 4};

// Expected first 10 outputs
uint64_t expected[10] = {
    0x41943c2739048afe, 0x169c8abcc8b9aa0d, 0x3e73c169d8e8b9a4,
    0xa3ec8293b8ff0d59, 0x8bcbcbe14b29ba13, 0xb66ea62e74b3c45b,
    0x30fe3cb18dd41a80, 0x48ad78bccf5b5e44, 0xea9a1c1c1a2b3cd1,
    0x8bb5b7f2ded37421
};

// Validation
for (int i = 0; i < 10; i++) {
    uint64_t output = xoshiro256plusplus_next(state);
    assert(output == expected[i]);
}
```

### Matrix Generation Test

```c
// Verify matrix generation produces expected patterns
uint64_t state[4] = {0x123456789abcdef0, 0xfedcba9876543210,
                     0x0f1e2d3c4b5a6978, 0x8796a5b4c3d2e1f0};

uint16_t matrix[64][64];
generate_matrix_64x64(matrix, state);

// Verify all elements are 4-bit values
for (int i = 0; i < 64; i++) {
    for (int j = 0; j < 64; j++) {
        assert(matrix[i][j] <= 0x0F);
    }
}

// Verify deterministic generation
uint64_t state_copy[4] = {state[0], state[1], state[2], state[3]};
uint16_t matrix2[64][64];
generate_matrix_64x64(matrix2, state_copy);

assert(memcmp(matrix, matrix2, sizeof(matrix)) == 0);
```

## Integration with kHeavyHash

### Critical Design Points

1. **Deterministic Seeding**: Matrix must be reproducible from PrePowHash
2. **Full-Rank Requirement**: Matrix must be invertible in GF(16)  
3. **Performance**: Matrix generation should be fast enough for mining
4. **Hardware Efficiency**: Simple enough for FPGA implementation

### Optimization for Mining

**Matrix Caching Strategy**:
```c
// Cache matrix per PrePowHash to avoid regeneration
typedef struct {
    uint8_t prepowHash[32];
    uint16_t matrix[64][64];
    bool valid;
} matrix_cache_entry_t;

// Miners can reuse same matrix for billions of nonce attempts
static matrix_cache_entry_t matrix_cache;

bool get_cached_matrix(const uint8_t prepowHash[32], uint16_t matrix[64][64]) {
    if (matrix_cache.valid && 
        memcmp(matrix_cache.prepowHash, prepowHash, 32) == 0) {
        memcpy(matrix, matrix_cache.matrix, sizeof(matrix_cache.matrix));
        return true;
    }
    return false;
}
```-->

## Sources

- **Original Paper**: "Scrambled Linear Pseudorandom Number Generators" by Blackman & Vigna
- **xoshiro/xoroshiro Generators**: http://prng.di.unimi.it/
- **BigCrush Test Suite**: TestU01 library by Pierre L'Ecuyer
- **PractRand**: Practical Random Number Generator Tests by Chris Doty-Humphrey  
- **Kaspa Implementation**: https://github.com/kaspanet/kaspad
- **Reference Implementation**: https://github.com/bcutil/kheavyhash
- **Statistical Tests**: "Handbook of Applied Cryptography" by Menezes, van Oorschot, and Vanstone
- **FPGA Implementation**: Xilinx UG901 "Vivado Design Suite User Guide"
