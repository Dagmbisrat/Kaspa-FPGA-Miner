# matmul_pipelined_unit — RTL Implementation

---

## Overview

`matmul_pipelined_unit` is the kHeavyHash **matrix-vector multiply** built as a
**feed-forward pipeline**: it accepts a new 64-nibble vector every clock cycle
and, after a fixed fill latency, emits one 64-nibble product every clock cycle
(throughput = 1 result/cycle).

For a constant 64×64 nibble matrix `M` and a streaming vector `v`, it computes

```
  result[i] = ( sum_{j=0..63} M[i][j] * v[j] ) >> 10      (4-bit nibble, i = 0..63)
```

The 64×64 matrix is **constant for every nonce in a block**, so it is supplied
once and held while vectors stream through. The 64-term dot product for all 64
rows is evaluated in parallel and its summation is pipelined across `NUM_STAGES`
register layers (segmented accumulation) — mirroring `cshake256_pipelined_core`.

### Kaspa-Specific Shortcuts

| General matrix multiply     | Kaspa Miner              | Simplification                         |
| --------------------------- | ------------------------ | -------------------------------------- |
| Arbitrary element width     | 4-bit nibbles (0–15)     | 4×4 multipliers, 14-bit accumulators   |
| Re-loaded operands          | Matrix constant per block| Loaded once, then vectors stream       |
| Generic normalization       | Fixed `>> 10` to a nibble| Wire slice `acc[13:10]`, no divider    |

---

## Ports & Parameters

### Parameters

| Parameter         | Default | Description                                                                 |
|:----------------- |:-------:|:--------------------------------------------------------------------------- |
| `NUM_STAGES`      | 8       | Pipeline register layers. **Must divide 64.** Fmax-vs-area knob.            |
| `INTERNAL_MATRIX` | 1       | **Build-time** matrix source: **1** = internal flops + write port (standalone TB), **0** = matrix wired from `matrix_in` (in-core, no storage). |

> `INTERNAL_MATRIX` is a **compile-time parameter, not a port**. In-core the unit
> is built with `INTERNAL_MATRIX = 0` and reads the matrix combinationally from
> the widened `matrix_cache.matrix_flat`, so it carries no matrix storage of its
> own. The standalone testbench uses the default `INTERNAL_MATRIX = 1` and loads
> the matrix through the `wr_matrix_*` port.

### Ports

```
┌──────────────────────────────────────────────────────────────────┐
│  matmul_pipelined_unit #(NUM_STAGES, INTERNAL_MATRIX)            │
│                                                                  │
│   clk            ───►                  ───► product_out [255:0]  │
│   rst            ───►                  ───► valid_out            │
│   vector_in [255:0] ───►                                         │
│   valid_in       ───►                                            │
│                                                                  │
│   wr_matrix_en   ───►   (INTERNAL_MATRIX = 1 only)               │
│   n16th_value [7:0] ─►                                           │
│   wr_matrix_data [63:0] ─►                                       │
│                                                                  │
│   matrix_in [16383:0] ─►(INTERNAL_MATRIX = 0 only)               │
└──────────────────────────────────────────────────────────────────┘
```

| Port             | Dir | Width | Description                                                     |
|:---------------- |:---:|:-----:|:--------------------------------------------------------------- |
| `clk`            | in  | 1     | Clock                                                           |
| `rst`            | in  | 1     | Async reset — clears the accumulators, vector pipe and `valid`  |
| `wr_matrix_en`   | in  | 1     | Matrix write enable (`INTERNAL_MATRIX = 1`)                     |
| `n16th_value`    | in  | 8     | Write address: `[7:2]` = row, `[1:0]` = 16-element group        |
| `wr_matrix_data` | in  | 64    | 16 nibbles for the addressed group                              |
| `matrix_in`      | in  | 16384 | Whole matrix, `matrix_in[(i*64+j)*4 +: 4] = M[i][j]` (`INTERNAL_MATRIX = 0`) |
| `vector_in`      | in  | 256   | 64 × 4-bit nibbles, swapped packing (see below)                 |
| `valid_in`       | in  | 1     | Assert to inject a new vector this cycle                        |
| `product_out`    | out | 256   | 64 × 4-bit result nibbles, swapped packing                      |
| `valid_out`      | out | 1     | High on the cycle `product_out` is valid                        |

> There is **no** `start`/`done` handshake. Drive `valid_in` every cycle for full
> throughput; `valid_out` tracks each result `NUM_STAGES` cycles later.

---

## Pipeline Architecture

The datapath is a straight feed-forward pipeline — no feedback, no FSM:

```
             stage 0              stage 1                    stage NUM_STAGES-1
         ┌────────────┐       ┌───────────────┐           ┌───────────────────┐
vector_in│ cols 0..C-1│ acc0  │ cols C..2C-1  │ acc1 ...  │ last C columns    │─► product_out
────────►│ dot + acc  │─reg─► │ dot + acc     │─reg─► ... │ dot + acc         │   (acc >> 10)
valid_in ┊(comb)      ┊  vec  ┊(comb)         ┊  vec      ┊(comb)             ┊─► valid_out
         └────────────┘       └───────────────┘           └───────────────────┘
              ▲ matrix cols read combinationally (shared, constant per block)
                                          C = COLS_PER_STAGE = 64 / NUM_STAGES
```

| Stage       | Register            | Function                                                        |
|:----------- |:------------------- |:--------------------------------------------------------------- |
| st = 0..N-1 | `acc[st][0..63]` (14b each) | Add this stage's `C` columns to the running dot product for all 64 rows |
| st = 0..N-2 | `g_fwd.fwd_q` (shrinking)  | Forward only the still-unused vector columns to the next stage |
| valid       | `valid_pipe[0..N-1]`| One-bit token aligned to the accumulator latency               |
| Output      | —                   | `product_out[(i^1)*4 +: 4] = acc[NUM_STAGES-1][i][13:10]` (comb) |

Total 4×4 multipliers = 64 × 64 = **4096**, independent of `NUM_STAGES` — the
reduction is only *sliced* differently in time.

### Throughput, Latency & the NUM_STAGES Knob

- **Throughput:** always **1 vector/cycle** — `NUM_STAGES` does not change it.
- **Fill latency:** `LAT = NUM_STAGES` cycles (`product_out` is a combinational
  slice of the last accumulator register).
- **Critical path (Fmax):** the `COLS_PER_STAGE`-term adder chain of one stage.

| `NUM_STAGES` | cols/stage | Throughput | Critical path            | acc 14b regs |
|:------------:|:----------:|:----------:|:------------------------:|:------------:|
| 1            | 64         | 1 vec/cyc  | 64-term add (lowest Fmax)| 1 × 64       |
| 8            | 8          | 1 vec/cyc  | 8-term add               | 8 × 64       |
| 16           | 4          | 1 vec/cyc  | 4-term add               | 16 × 64      |
| 64           | 1          | 1 vec/cyc  | 1 multiply (highest Fmax)| 64 × 64      |

> `NUM_STAGES` trades **Fmax for register area**; the multiply *logic* is always
> the full 4096 products. Deeper pipelines raise Fmax at the cost of latency and
> flops.

### valid_out Alignment

`valid_in` is shifted through `valid_pipe` and tapped at `valid_pipe[NUM_STAGES-1]`
so `valid_out` lines up exactly with `product_out`. `valid_pipe` and the
accumulators are cleared by `rst`, guaranteeing no spurious `valid_out` during
the initial fill.

---

## Shrinking Vector Forwarding

A new vector enters every cycle, so each stage must keep the vector belonging to
its in-flight result. Rather than copy the full 256-bit vector down every stage,
`vector_in` is **de-swapped once** into plain column order and then each stage
consumes its `COLS_PER_STAGE` columns from the low nibbles and forwards **only
the still-unused columns**:

```
  vec_plain = de-swap(vector_in)            column j at nibble j
  stage st input : columns [st*C .. 63]     (plain packed, col st*C at nibble 0)
  stage st uses  : low C nibbles            (its own columns)
  stage st fwd   : input >> (C*4)           (drop the columns it just consumed)
```

The carried vector therefore shrinks by `C` columns each layer, cutting the
vector-forwarding registers from `NUM_STAGES × 256` to the triangular sum:

```
  forwarding flops = 128 × (NUM_STAGES - 1) bits
```

e.g. at `NUM_STAGES = 8`: **2048 → 896 bits** (~56% fewer), with identical
results. Accumulators and the multiply core are unchanged.

---

## Nibble Conventions

Matching `matrix_cache` / `gen_vectors.py`:

```
  Matrix   : matrix_in[(i*64 + j)*4 +: 4] = M[i][j]   (plain, = matrix_cache.matrix_flat)
  Vector   : vector_in[(j ^ 1)*4 +: 4]    = v[j]      (swapped: adjacent nibbles paired)
  Product  : product_out[(i ^ 1)*4 +: 4]  = result[i] (swapped)
```

The `^1` swap on `vector_in`/`product_out` matches the byte/nibble ordering of
the surrounding kHeavyHash datapath; internally the unit de-swaps the vector so
the multiply and forwarding use plain column order.

---

## Matrix Source & Load

### Internal (`INTERNAL_MATRIX = 1`, standalone TB)

The matrix lives in `matrix[64][64]` flops, written 16 nibbles per cycle exactly
like `matrix_cache`:

```
  n16th_value[7:2] = row      n16th_value[1:0] = 16-element group
  full load = 64 rows × 4 groups = 256 writes (with valid_in = 0)
```

### Wired (`INTERNAL_MATRIX = 0`, in-core)

No internal storage. The matrix is a combinational tap of the widened
`matrix_cache.matrix_flat` bus, so the constant per-block matrix is read straight
from the cache while vectors stream. See the integration notes below.

---

## In-Core Integration

Because every stage reads the shared matrix combinationally, the matrix must be
**stable** for the whole time a vector is in flight:

1. **Gate the stream.** Hold `valid_in = 0` until the matrix generator asserts
   `done` — the generator is the block-level blocking IP.
2. **Drain before reload.** When switching blocks, stop `valid_in` and wait
   `LAT = NUM_STAGES` cycles so all in-flight vectors exit before the generator
   overwrites the matrix; otherwise those vectors read a mixed old/new matrix
   and produce wrong (but harmless) results — there is no hardware hazard.

A single shared matrix means no double-buffering: block switches cost one
`LAT`-cycle drain plus the generator's fill time, amortized over the millions of
nonces streamed per block.

---

## Resource Usage

```
  matmul_pipelined_unit
   ├─ Matrix source   internal flops (INTERNAL_MATRIX=1) OR matrix_in tap (=0)
   ├─ Multiply core   4096 × (4×4) products + 64 reduction trees (combinational)
   ├─ Accumulators    acc[NUM_STAGES][64] × 14b
   ├─ Vector forward  shrinking fwd_q registers (triangular)
   └─ Valid pipe      valid_pipe[NUM_STAGES]
```

```
  Resource                Source                       Size
  ──────────────────────  ───────────────────────────  ─────────────────────────────
  Matrix (internal only)  matrix[64][64]               16,384 FF  (0 when wired)
  Accumulators            acc[NUM_STAGES][64]          NUM_STAGES × 64 × 14 FF
  Vector forwarding       fwd_q per stage              128 × (NUM_STAGES − 1) FF
  Valid shift register    valid_pipe                   NUM_STAGES FF
  Multiply logic          4×4 nibble multipliers ×4096 independent of NUM_STAGES
```

Lower `NUM_STAGES` reduces the accumulator and forwarding registers proportionally
while keeping all 4096 products of combinational logic.

---

## Verification

A Verilator testbench drives the unit from vectors generated by the Python
reference model (`KHeavyhash._matrix_vector_multiply`):

```
make runtest                  # internal-matrix build (write port)
make wiretest                 # wired-matrix build (matrix_in, INTERNAL_MATRIX=0)
make vectors                  # regenerate sim/expected_vectors.mem from the reference
make runtest  NUM_STAGES=N    # build with N pipeline layers (N | 64)
```

- `sim/gen_vectors.py` computes each expected product with the reference multiply
  and writes `sim/expected_vectors.mem` (64 matrix rows, then vectors, then
  expected products).
- `matmul_pipelined_tb` loads that file, streams the vectors back-to-back with
  `valid_in` high every cycle, and checks each `product_out` against the
  reference while asserting exactly one `valid_out` per vector, `LAT` cycles
  behind the input stream.
- Both modes pass 64/64 at 1 vector/cycle for `NUM_STAGES` ∈ {1, 8, 16, 64}.

---

## References

- **kHeavyHash** — https://github.com/bcutil/kheavyhash
- **Companion docs** — [matrix_generator](matrix_generator.md) | [matrix_rankcheck](matrix_rankcheck.md) | [xoshiro256++](xoshiro256pp.md)
- **Pipeline sibling** — [cSHAKE256 pipelined core](../crypto/cshake256_core.md)
