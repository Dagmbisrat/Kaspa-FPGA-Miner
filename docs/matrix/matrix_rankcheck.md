# matrix_rankcheck — RTL Implementation

---

## Overview

`matrix_rankcheck` determines whether the 64×64 4-bit matrix stored in `matrix_cache` is **full rank** using Gaussian elimination over GF(2).

Each cache row is 256 bits (64 nibbles × 4 bits), treated as a vector in GF(2)^256. Elimination over the 64 row vectors counts linearly independent rows; `full_rank` is asserted when that count reaches 64.

---

## Port List

| Port          | Dir | Width | Description                              |
|:------------- |:---:|:-----:|:---------------------------------------- |
| `clk`         | in  | 1     | Clock                                    |
| `rst`         | in  | 1     | Async reset                              |
| `start`       | in  | 1     | Begin rank check                         |
| `done`        | out | 1     | High for one cycle when result is ready  |
| `full_rank`   | out | 1     | **1** = rank 64, **0** = rank < 64       |
| `rd_en`       | out | 1     | Cache read enable                        |
| `rd_row`      | out | 6     | Cache row address (0–63)                 |
| `rd_row_data` | in  | 256   | Row data returned by cache (1-cycle lat) |

---

## State Diagram

```
          start = 1
              │
              ▼
   ╔═════════╗     ╔═════════╗     ╔═════════╗     ╔═════════╗     ╔═════════╗
   ║  IDLE   ║────►║  LOAD   ║────►║  FLUSH  ║────►║  ELIM   ║────►║  DONE   ║
   ║  (000)  ║     ║  (001)  ║     ║  (010)  ║     ║  (011)  ║     ║  (100)  ║
   ╚═════════╝     ╚═════════╝     ╚═════════╝     ╚═════════╝     ╚═════════╝
                    64 cycles        1 cycle         ≤256 cycles      1 cycle
                    rd rows 0..63   drain row 63    col-by-col elim  assert done
```

### Cycle Budget

```
  Phase    Cycles    What Happens
  ──────   ──────    ──────────────────────────────────────────
  LOAD       64      Issue cache reads for rows 0..63 (1/cycle)
  FLUSH       1      Capture last row from cache pipeline
  ELIM      ≤256     One GF(2) column eliminated per cycle; exits early at rank=64
  DONE        1      Assert done
  ──────   ──────
  Total    ≤322      ~130 typical for a full-rank matrix
```

---

## GF(2) Gaussian Elimination

Each column bit `col` (0–255) is processed in one clock cycle:

1. **Pivot search** (combinational): scan rows `rank..63`, find lowest index `r` where `M[r][col] = 1`.
2. **Swap**: bring pivot row to position `M[rank]`.
3. **Eliminate**: XOR pivot into every other row that has `M[r][col] = 1`, clearing that column bit.
4. Increment `rank`; advance `col`.

Non-blocking assignments ensure all RHS reads within the `always_ff` body see pre-edge values — the swap and XOR are both clean in a single cycle.

**Termination:**
- `rank == 64` after a pivot found → `full_rank = 1`, go to DONE.
- `col == 255` exhausted before rank 64 → `full_rank = 0`, go to DONE.

---

## Working Matrix

```
  M[0..63]  — 64 × 256-bit registers (GF(2) row vectors)
  rank      — 7-bit counter, pivot rows placed so far
  col       — 8-bit counter, current bit-column under elimination
```

The working copy is loaded fresh from cache on every `start` pulse; the cache itself is not modified.

---

## Cache Interface

```
  rd_en  = (state == LOAD)        — active only during row loading
  rd_row = load_idx               — cycles 0..63
```

Cache has 1-cycle read latency: data for row `N` appears on the cycle after `rd_row = N` is asserted. FLUSH exists solely to drain this pipeline for row 63.

---

## References

- **Companion docs** — [matrix_generator](matrix_generator.md) | [matrix_cache](../rtl/matrix/matrix_cache.sv)
