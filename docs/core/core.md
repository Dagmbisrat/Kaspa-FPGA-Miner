# kHeavyHash Mining Core — RTL Implementation

---

## Overview

`core` is the top-level kHeavyHash mining engine. It sequences four sub-modules across a four-stage pipeline to compute a single hash from `pre_pow_hash`, `timestamp`, and `nonce`. The matrix generation and first cSHAKE run are fully parallel in STAGE1, minimising latency per hash.

---

## Port List

| Port           | Dir | Width | Description                                      |
|:-------------- |:---:|:-----:|:------------------------------------------------ |
| `clk`          | in  | 1     | Clock                                            |
| `rst`          | in  | 1     | Async reset                                      |
| `start`        | in  | 1     | Begin hashing (held for one cycle)               |
| `pre_pow_hash` | in  | 256   | Block header hash — seeds the matrix             |
| `timestamp`    | in  | 64    | UNIX timestamp (little-endian uint64)            |
| `nonce`        | in  | 64    | Mining nonce (little-endian uint64)              |
| `hash_out`     | out | 256   | Final 32-byte kHeavyHash result                  |
| `done`         | out | 1     | High for one cycle when `hash_out` is valid      |

---

## State Diagram

```
              start = 1
                  │
                  ▼
       ┌──────────────────┐
       │       IDLE       │◄────────────────────────────────────────┐
       │   latch header   │                                         │
       └────────┬─────────┘                                         │ done = 1
                │                                                   │
                ▼                                         ┌─────────┴────────┐
┌───────────────────────────────────────────────┐        │       DONE       │
│  STAGE 1                                      │        │    hash_out      │
│                                               │        │    valid         │
│  ┌────────────────────┐ ┌───────────────────┐ │        └─────────▲────────┘
│  │  matrix_generator  │ │   cshake256_core  │ │                  │
│  │  ─────────────── ──│ │  ─────────────── ─│ │                  │
│  │  xoshiro256++      │ │  s="ProofOfWork   │ │                  │
│  │  rank check        │ │    Hash"          │ │                  │
│  │                    │ │  80-byte header   │ │                  │
│  │       │ wr         │ │                   │ │                  │
│  │       ▼            │ │  pow_hash latched │ │                  │
│  │  ┌──────────────┐  │ │  on done ─────►  │ │                  │
│  │  │ matrix_cache │  │ │   pow_hash_reg    │ │                  │
│  │  └──────────────┘  │ └───────────────────┘ │                  │
│  └────────────────────┘                       │                  │
│   matrix_gen_complete_reg && cshake_complete_reg               │
└───────────────────────┬───────────────────────┘                  │
                        │                                          │
                        ▼                                          │
┌───────────────────────────────────────────────┐                  │
│  STAGE 2                                      │                  │
│                                               │                  │
│  ┌────────────────────────────────────────┐   │                  │
│  │            matmul_unit                 │   │                  │
│  │  ────────────────────────────────────  │   │                  │
│  │  matrix_cache rd ──► matrix × vector   │   │                  │
│  │  (pow_hash_reg, 64 nibbles, 66 cycles) │   │                  │
│  │                                        │   │                  │
│  │  product latched on done ──►           │   │                  │
│  │    matrix_mul_product_out_reg          │   │                  │
│  └────────────────────────────────────────┘   │                  │
└───────────────────────┬───────────────────────┘                  │
                        │ matrix_mul_done                          │
                        ▼                                          │
┌───────────────────────────────────────────────┐                  │
│  STAGE 3                                      │                  │
│                                               │                  │
│  ┌────────────────────────────────────────┐   │                  │
│  │           cshake256_core               │   │                  │
│  │  ────────────────────────────────────  │   │                  │
│  │  s="HeavyHash"                         │   │                  │
│  │  32-byte (product XOR pow_hash_reg)    │   │                  │
│  │                                        │   │                  │
│  │  hash_out latched on done              │   │                  │
│  └────────────────────────────────────────┘   │                  │
└───────────────────────┬───────────────────────┘                  │
                        │ cshake_done                              │
                        └──────────────────────────────────────────┘
```

---

## Pipeline Stages

| State    | Work                                               | Advances When                                         |
|:-------- |:-------------------------------------------------- |:----------------------------------------------------- |
| `IDLE`   | Latch header; arm starts for STAGE1                | `start = 1`                                          |
| `STAGE1` | MatrixGen (from `pre_pow_hash`) \|\| cSHAKE256("ProofOfWorkHash") on 80-byte header | Both `matrix_gen_complete_reg` and `cshake_complete_reg` set |
| `STAGE2` | matmul: cached matrix × vector (64 nibbles from `pow_hash_reg`) | `matrix_mul_done`                             |
| `STAGE3` | cSHAKE256("HeavyHash") on `product XOR pow_hash`  | `cshake_done`                                        |
| `DONE`   | Assert `done` for one cycle                        | Immediately (returns to IDLE)                        |

---

## Sub-Module Hierarchy

```
  core
  ├── matrix_cache       (64×64 nibble store + PrePowHash tag)
  ├── matrix_generator   (xoshiro256++ PRNG + rank check)
  ├── matmul_unit        (matrix × vector, 66 cycles)
  └── cshake256_core     (shared between STAGE1 and STAGE3)
```

---

## Key Signals

```
  header_reg          — 640-bit latch: {nonce, 256'b0, timestamp, pre_pow_hash}
  pow_hash_reg        — captures cshake_hash_out when cshake_done in STAGE1
  matrix_mul_product_out_reg — captures product_out when matrix_mul_done in STAGE2

  matrix_gen_complete_reg — set when matrix_gen_done; cleared in IDLE
  cshake_complete_reg     — set when cshake_done in STAGE1; cleared in IDLE
```

### Cache Read Arbitration

`rd_en` and `rd_row` are muxed by state so only one consumer drives the cache at a time:

```
  STAGE1  →  matrix_gen_rd_en / matrix_gen_rd_row
  STAGE2  →  matrix_mul_rd_en / matrix_mul_rd_row
  other   →  0
```

### cSHAKE Reuse

The single `cshake256_core` instance is used twice:

```
  STAGE1:  data_80byte=1, s_value=0 ("ProofOfWorkHash"), data_in=header_reg
  STAGE3:  data_80byte=0, s_value=1 ("HeavyHash"),       data_in={384'b0, product XOR pow_hash}
```

The core's INIT state zeroes the Keccak state before each use, so no flush logic is needed between stages.

---

## References

- **Companion docs** — [cSHAKE256 Core](../crypto/cshake256_core.md) | [matrix_generator](../matrix/matrix_generator.md) | [kHeavyHash Algorithm](../KHeavyhash.md)
- **kHeavyHash** — https://github.com/bcutil/kheavyhash
