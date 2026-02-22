# matrix_generator — RTL Implementation

---

## Overview

`matrix_generator` produces the 64×64 4-bit matrix required by kHeavyHash from a 256-bit `PrePowHash`. It drives `matrix_cache` with the generated data and delegates rank verification to an embedded `matrix_rankcheck` instance. If the requested `PrePowHash` is already cached, generation is skipped entirely.

---

## Port List

| Port               | Dir | Width | Description                                      |
|:------------------ |:---:|:-----:|:------------------------------------------------ |
| `clk`              | in  | 1     | Clock                                            |
| `rst`              | in  | 1     | Async reset                                      |
| `start`            | in  | 1     | Begin matrix generation                          |
| `PrePowHash`       | in  | 256   | Seed for xoshiro256++ and cache tag              |
| `done`             | out | 1     | High when a valid full-rank matrix is in cache   |
| `wr_matrix_en`     | out | 1     | Cache matrix write enable                        |
| `wr_PrePowHash_en` | out | 1     | Cache PrePowHash tag write enable                |
| `n16th_value`      | out | 8     | PRNG call counter (0–255); selects write address |
| `wr_matrix_data`   | out | 64    | PRNG output word to write to cache               |
| `rd_en`            | out | 1     | Cache read enable (OR of generator + rankcheck)  |
| `rd_row`           | out | 6     | Cache row address                                |
| `rd_row_data`      | in  | 256   | Cache row data (for rankcheck)                   |
| `rd_PrePowHash`    | in  | 256   | Cached PrePowHash tag (for cache-hit check)      |

---

## State Diagram

```
          start = 1
              │
              ▼
   ╔══════════════╗   rd_PrePowHash==PrePowHash   ╔══════════╗
   ║     IDLE     ║──────────────────────────────►║          ║
   ║    (000)     ║                               ║   DONE   ║
   ╚══════════════╝                               ║  (100)   ║◄───────┐
          │                                       ╚══════════╝        │
          │ cache miss                                  │             │
          ▼                                            IDLE           │
   ╔══════════════╗                                                   │
   ║ IDLE_CHECK   ║                                                   │
   ║    (001)     ║ ─── seed PRNG state from PrePowHash               │
   ╚══════════════╝                                                   │
          │                                                           │
          ▼         n16th_value = 0xFF                                │
   ╔══════════════╗──────────────────────►╔══════════════╗            │
   ║   GENERATE   ║                       ║  RANK_CHECK  ║            │
   ║    MATRIX    ║◄──────────────────────║    (011)     ║            │
   ║    (010)     ║   !full_rank          ╚══════════════╝            │
   ╚══════════════╝                              │                    │
                                          full_rank                   │
                                                 └───────────────────►┘
```

### State Summary

| State             | Action                                                         |
|:----------------- |:-------------------------------------------------------------- |
| `IDLE`            | Assert `rd_en` to pre-fetch cache tag for next cycle           |
| `IDLE_CHECK`      | Compare `rd_PrePowHash` vs `PrePowHash`; seed PRNG from hash   |
| `GENERATE_MATRIX` | Clock PRNG 256× writing 64-bit words; tag cache on first write |
| `RANK_CHECK`      | Wait for `matrix_rankcheck`; loop back if not full rank        |
| `DONE`            | Assert `done` for one cycle; return to IDLE                    |

---

## Matrix Generation

xoshiro256++ is **combinational** — one new output word per clock cycle.

```
  PRNG calls : 256  (n16th_value 0x00 → 0xFF)
  Output/call: 64 bits = 16 nibbles (4-bit elements)
  Total      : 256 × 16 = 4,096 nibbles → 64×64 matrix
```

`n16th_value` doubles as the cache write address (which 64-bit slot in the flat 256-word cache store to write to).

On `n16th_value == 0` the `wr_PrePowHash_en` tag is written alongside the first matrix word, so the cache is tagged atomically with the first data.

---

## Cache-Hit Fast Path

During IDLE, `rd_en_gen` is asserted to pre-fetch the stored `rd_PrePowHash` tag. In IDLE_CHECK (next cycle), if `rd_PrePowHash == PrePowHash` the FSM jumps directly to DONE — no generation needed.

---

## Sub-Module Hierarchy

```
  matrix_generator
   ├── xoshiro256pp      (combinational PRNG — see xoshiro256pp.md)
   └── matrix_rankcheck  (GF(2) Gaussian elimination — see matrix_rankcheck.md)
```

`rd_en` is the logical OR of the generator's own read enable (`rd_en_gen`) and the rankcheck's (`rd_en_rank`). Their activity windows do not overlap.

---

## Key Signals

```
  n16th_value      — 8-bit counter; one PRNG call per cycle in GENERATE_MATRIX
  done_generation  — combinational; high when n16th_value reaches 0xFF
  start_rank_check — combinational; pulses simultaneously with done_generation
  full_rank        — result from matrix_rankcheck; if 0, regeneration loops
```

---

## References

- **Companion docs** — [matrix_rankcheck](matrix_rankcheck.md) | [xoshiro256++](xoshiro256pp.md)
- **kHeavyHash** — https://github.com/bcutil/kheavyhash
