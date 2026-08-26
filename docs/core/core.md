# kHeavyHash Mining Core — RTL Implementation

---

## Overview

`core` is the top-level kHeavyHash mining engine, built as a **streaming
pipeline**: given a block (`pre_pow_hash`, `timestamp`, starting `nonce`), it
sweeps nonces and emits **one finished hash per clock cycle**, each tagged with
the nonce that produced it.

The 64×64 matrix is **constant per block**, so it is generated once (blocking)
and then held in the cache while nonces stream through a feed-forward chain of
three 1-result/cycle IPs:

```
  nonce++ ─► cshake1 ─► matmul ─► XOR(pow_hash) ─► cshake2 ─► hash_out
            (POW,80B)   (matrix)                  (HH,32B)     + nonce_out
```

This replaces the earlier per-nonce sequential FSM: matrix generation is
amortised across the whole block, and after the fill latency the pipeline
sustains 1 nonce/cycle.

---

## Ports & Parameters

### Parameters

| Parameter       | Default | Description                                        |
|:--------------- |:-------:|:-------------------------------------------------- |
| `CSHAKE_STAGES` | 24      | cSHAKE pipeline layers (both cores). Must divide 24.|
| `MATMUL_STAGES` | 8       | matmul pipeline layers. Must divide 64.            |

### Ports

| Port           | Dir | Width | Description                                      |
|:-------------- |:---:|:-----:|:------------------------------------------------ |
| `clk`          | in  | 1     | Clock                                            |
| `rst`          | in  | 1     | Async reset                                      |
| `start`        | in  | 1     | Pulse to load a block and begin streaming        |
| `pre_pow_hash` | in  | 256   | Block header hash — matrix seed, stable per block |
| `timestamp`    | in  | 64    | UNIX timestamp (little-endian uint64)            |
| `nonce`        | in  | 64    | Starting nonce for the stream                    |
| `target`       | in  | 256   | Difficulty target; a hash passes if `hash <= target` |
| `hash_out`     | out | 256   | Streamed 32-byte kHeavyHash result               |
| `nonce_out`    | out | 64    | Nonce that produced the current `hash_out`       |
| `valid_out`    | out | 1     | High on the cycle `hash_out`/`nonce_out` are valid|
| `found`        | out | 1     | Pulse when a streamed hash meets `target`         |
| `found_nonce`  | out | 64    | The winning nonce                                |
| `found_work_id`| out | 8     | Job/work id the winning nonce belongs to         |

> There is no per-nonce `start`/`done` handshake on the datapath. Each IP's
> `valid_out` feeds the next IP's `valid_in`, so validity flows automatically.

---

## Two-Phase Control

The core tracks `pph_reg` — the pph the cached matrix was built for — and
compares the incoming `pre_pow_hash` against it (a combinational, non-blocking
check).

```
          start
            │
   ┌────────▼──────────┐  pre_pow_hash == pph_reg
   │  load block regs  │──────────────────────────► STREAM
   │  (pph,ts,nonce)   │  (matrix already cached)
   └────────┬──────────┘
            │ pre_pow_hash != pph_reg (new block)
            ▼
   ┌───────────────────┐  matrix_generator done
   │       GEN         │──────────────────────────► STREAM
   │  (blocking regen) │
   └───────────────────┘
```

- **GEN** — pulse `matrix_gen_start`, hold `valid_in = 0`, wait for a *fresh*
  generator completion, then update `pph_reg` and stream.
- **STREAM** — free-run `nonce_ctr`, assert `valid_in` every cycle. Stays here
  streaming; a new `start` reloads and repeats the decision.

Matrix (re)generation therefore happens **only on a new block**; identical
`pre_pow_hash` re-uses the cached matrix and streams immediately.

> **`gen_ack`**: `matrix_generator.done` is a *level* that stays high after the
> first generation, not a pulse. The FSM waits for `done` to go **low then high**
> (`gen_ack`) so a block switch cannot mistake the stale-high level for a fresh
> completion and stream before the new matrix is ready.

---

## Streaming Datapath

Every STREAM cycle:

| Step | Block | Detail |
|:---- |:----- |:------ |
| 1 | header | `{nonce_ctr, 256'b0, timestamp, pre_pow_hash}` (80 bytes) |
| 2 | **cSHAKE1** | `S_VALUE=0` (ProofOfWorkHash), 80-byte → `pow_hash` |
| 3 | vector | `vector_in = pow_hash` directly (nibble packing matches) |
| 4 | **matmul** | `INTERNAL_MATRIX=0`, reads whole matrix from cache `matrix_flat` → `product` |
| 5 | XOR | `digest = product ^ pow_hash` (`pow_hash` delayed by the matmul latency) |
| 6 | **cSHAKE2** | `S_VALUE=1` (HeavyHash), 32-byte digest → `hash_out` |

The matmul reads the matrix **combinationally in parallel** (all 64×64 nibbles)
from the widened `matrix_cache.matrix_flat`, because a 1-vector/cycle multiply
cannot use the cache's one-row-per-cycle read port.

### pow_hash alignment for the XOR

`pow_hash` is both the matmul vector and (per kHeavyHash) the XOR operand for the
digest. Since the matmul adds `M_LAT = MATMUL_STAGES` cycles, `pow_hash` is
delayed by `M_LAT` in a shift register so nonce N's product meets nonce N's
`pow_hash`.

### Nonce tagging

The hash carries no nonce, so `nonce_ctr` is shifted down a delay line matched to
the full pipeline latency and presented as `nonce_out`, aligned with `hash_out`:

```
  TOTAL_LAT = C_LAT + M_LAT + C_LAT ,  C_LAT = CSHAKE_STAGES + 2 ,  M_LAT = MATMUL_STAGES
```

---

## Sub-Module Hierarchy

```
  core
  ├── matrix_cache             (64×64 nibble store + PrePowHash tag + matrix_flat)
  ├── matrix_generator         (xoshiro256++ PRNG + rank check; blocking, per block)
  ├── cshake256_pipelined_core (Cshake1: S=0/80B) ─► pow_hash
  ├── matmul_pipelined_unit    (INTERNAL_MATRIX=0, matrix_in = matrix_flat)
  └── cshake256_pipelined_core (Cshake2: S=1/32B) ─► hash_out
```

The cache write port is driven only by the generator; its one-row read port is
used only by the generator's rank check. The matmul reads the parallel
`matrix_flat` tap, so there is no read-port contention during streaming.

---

## Nibble Conventions

The kHeavyHash nibble packing lines up so no explicit conversion is needed:

```
  vector_in = pow_hash                       (matmul swapped packing matches byte->nibble)
  digest    = product_out ^ pow_hash         (plain 256-bit XOR)
  header    = {nonce, 256'b0, timestamp, pre_pow_hash}
```

---

## Difficulty Target Compare

A tail stage after cSHAKE2 compares each streamed `hash_out` against `target`
(latched per work as `tgt_reg`) and pulses `found` with the winning `found_nonce`
when `hash <= target`. `target` is a runtime input (difficulty changes per job)
and is **not** tied to the pph: a target-only change costs nothing (no matrix
regeneration).

A small `work_id` (incremented on each new-work `start`) rides down a delay line
alongside the nonce. `found` only fires when the result's `work_id` matches the
current job, so stale in-flight results from a previous job are ignored and every
`found_nonce` is attributed to the right work (`found_work_id`).

> **Byte order (confirmed):** kaspad's `pow.toBig()` treats the hash as
> little-endian, which is exactly how `hash_out` is packed - so the raw 256-bit
> `hash_out <= target` matches kaspad's `CheckProofOfWork` (no byte swap needed).
> The host supplies `target` as the plain 256-bit integer expanded from `bits`.

---

## Not Yet Included (by design)

- **Block-switch drain** - a few in-flight results at a block boundary can be
  wrong-but-harmless (no hardware hazard); they are filtered by `work_id`.

---

## Verification

A Verilator testbench (`tb/core_tb.sv`) drives the core from the Python reference
`KHeavyhash.hash()` across three phases and checks every streamed `hash_out` by
its `nonce_out`:

```
make runtest                     # gen vectors, build, run
make runtest MATMUL_STAGES=16    # override pipeline depth (must divide 64)
make runtest CSHAKE_STAGES=12    # override cSHAKE depth (must divide 24)
```

- Phase 0: fresh matrix generation (block A)
- Phase 1: cache-hit re-use (block A, new nonce base)
- Phase 2: block switch + regeneration (block B)

All 96 streamed hashes and 96 target-compare decisions match the reference (192 checks) at 1 nonce/cycle.

---

## References

- **Companion docs** — [cSHAKE256 Core](../crypto/cshake256_core.md) | [matmul_pipelined_unit](../matrix/matmul_pipelined_unit.md) | [matrix_generator](../matrix/matrix_generator.md) | [kHeavyHash Algorithm](../KHeavyhash.md)
- **kHeavyHash** — https://github.com/bcutil/kheavyhash
