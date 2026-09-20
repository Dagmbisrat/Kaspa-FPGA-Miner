# cSHAKE256 Pipelined Core — RTL Implementation

---

## Overview

`cshake256_pipelined_core` is a **Kaspa-specific** cSHAKE256 hash engine built as
a **feed-forward pipeline**: it accepts a new input every clock cycle and, after
a fixed fill latency, emits one 256-bit hash every clock cycle (throughput = 1
hash/cycle).

It hardcodes the two customization strings used by kHeavyHash
(`"ProofOfWorkHash"` and `"HeavyHash"`) and fixes the output at 256 bits, so all
general-purpose cSHAKE encoding collapses to a fixed datapath.

The `S` string and input size are fixed at **build time** by the `S_VALUE` and
`DATA_80BYTE` parameters, so each instance is dedicated to a single hash mode and
carries only the logic for that one configuration.

> **Two key simplifications make the streaming pipeline possible**
> 1. The cSHAKE **prefix block** (`bytepad(encode_string("") || encode_string(S), 136)`)
>    is constant for each `S`. Absorbing it is done **offline**, and the resulting
>    post-prefix Keccak state is hardcoded as a constant (`SPONGE_POW` / `SPONGE_HH`).
> 2. Every hash therefore needs only **one** Keccak-f[1600]: XOR the message block
>    into the precomputed sponge state, permute once, read the first 256 bits.

### Kaspa-Specific Shortcuts

| General cSHAKE256      | Kaspa Miner           | Simplification                        |
| ---------------------- | --------------------- | ------------------------------------- |
| Variable **N** string  | N = `""` always       | folded into the constant sponge state |
| Variable **S** string  | S = one of two values | Build-time `S_VALUE` picks one sponge constant |
| Variable output length | Always 256 bits       | No squeeze loop — read first 4 lanes  |
| Multi-block input      | 80B or 32B input      | Single block; build-time `DATA_80BYTE` pad offset |
| Prefix absorb (block 1)| Constant per S        | Precomputed → `SPONGE_POW`/`SPONGE_HH` |

---

## Ports & Parameters

### Parameters

| Parameter     | Default | Description                                                                  |
|:------------- |:-------:|:---------------------------------------------------------------------------- |
| `FOLDED`      | 0       | **0** = unfolded (spatial pipeline, 1 hash/cycle). **1** = folded (single reused register, 1 hash at a time, gated by `busy`). |
| `STAGES`      | 24      | Dual-meaning, depends on `FOLDED`. **Must divide 24.** See below.             |
| `S_VALUE`     | 0       | **Build-time** S string: **0** = `"ProofOfWorkHash"`, **1** = `"HeavyHash"`.  |
| `DATA_80BYTE` | 1       | **Build-time** input size: **0** = 32-byte input, **1** = 80-byte input.      |

> `STAGES` means a different physical thing depending on `FOLDED`:
> - `FOLDED=0`: register **layers** the fixed 24 `keccak_round` instances are
>   split into — an Fmax-vs-area knob, total instance count always 24.
> - `FOLDED=1`: physical `keccak_round` **instances** built, looped `24/STAGES`
>   times per hash — an area-vs-throughput knob.

> `S_VALUE` and `DATA_80BYTE` are **compile-time parameters, not ports** — each
> instance is dedicated to one hash mode. This removes the runtime `s_value`
> sponge MUX, drops the unused sponge table, and fixes the Stage-0 pad offset,
> saving area when many cores are instantiated (e.g. a throughput pipeline with
> one `S_VALUE=0` core feeding one `S_VALUE=1` core).

### Ports

```
┌──────────────────────────────────────────────────────────────────┐
│  cshake256_pipelined_core #(FOLDED, STAGES, S_VALUE, DATA_80BYTE)│
│                                                                  │
│   clk             ───►             ───► hash_out [255:0]         │
│   rst             ───►             ───► valid_out                │
│   data_in [639:0] ───►             ───► busy                     │
│   valid_in        ───►                                           │
└──────────────────────────────────────────────────────────────────┘
```

| Port          | Dir | Width | Description                                                       |
|:------------- |:---:|:-----:|:----------------------------------------------------------------- |
| `clk`         | in  | 1     | Clock                                                             |
| `rst`         | in  | 1     | Synchronous reset — clears `valid_sr` (no false outputs)          |
| `data_in`     | in  | 640   | Input message; only `[255:0]` is used when `DATA_80BYTE = 0`      |
| `valid_in`    | in  | 1     | Assert to inject a new message on this cycle                      |
| `hash_out`    | out | 256   | cSHAKE256 result                                                  |
| `valid_out`   | out | 1     | High on the cycle `hash_out` is valid                            |
| `busy`        | out | 1     | `FOLDED=1` only: high while a fold is mid-flight — hold `valid_in` low until it deasserts. Tied to `0` when `FOLDED=0`. |

> There is **no** `start`/`done` handshake (unfolded) beyond `busy` (folded).
> Drive `valid_in` every cycle for full throughput when unfolded; `valid_out`
> tracks each result `STAGES + 2` cycles later (unfolded) or `24/STAGES + 2`
> cycles later (folded).

---

## Pipeline Architecture

`FOLDED` selects between two datapaths for the Keccak stage. Both share the
same Stage 0 (encode) / Stage 1 (XOR sponge) front end.

| Mode | STAGES means | Hashes in flight | Knob |
|:---- |:------------- |:----------------:|:---- |
| `FOLDED=0` (default) | pipeline register layers | many (1/cycle) | Fmax vs. area |
| `FOLDED=1` | physical round instances | 1 (`busy`-gated) | area vs. throughput |

### FOLDED=0 — Spatial Pipeline (default)

No feedback, no FSM — a straight feed-forward pipeline:

```
              stage 0            stage 1                  STAGES Keccak layers
          ┌───────────┐     ┌───────────────┐     ┌────────────────────────────────────┐
 data_in─►│ Encode Msg│─pr0►│ XOR into      │─pr1►│ [R rounds]─►reg ... [R rounds]─►reg├─► hash_out
 valid_in ┊(comb)     ┊     ┊ SpongeState   ┊     ┊  kstate[0]        kstate[N-1]      ┊   valid_out
          └───────────┘     └───────────────┘     └────────────────────────────────────┘
                              ▲ SPONGE_POW / SPONGE_HH        R = ROUNDS_PER_STAGE = 24/STAGES
```

| Stage        | Register  | Function                                                        |
|:------------ |:--------- |:-------------------------------------------------------------- |
| 0 Encode     | `pr0` (1088b) | Build the padded 136-byte message block (combinational)     |
| 1 XOR Sponge | `pr1` (1600b) | XOR `pr0` into the precomputed sponge constant (`S_VALUE`-selected) |
| Keccak ×N    | `kstate[0..N-1]` (1600b each) | Each layer runs `ROUNDS_PER_STAGE` rounds then registers |
| Output       | —         | `hash_out = kstate[STAGES-1][255:0]` (combinational)            |

The `STAGES` layers hold `STAGES × ROUNDS_PER_STAGE = 24` `keccak_round`
instances total, with **static** round constants (`GLOBAL_R = st*ROUNDS_PER_STAGE + r`,
sweeping `RC[0..23]`). No feedback means a new hash may enter every cycle
(initiation interval = 1); `busy` is tied low.

- **Throughput:** always **1 hash/cycle** — `STAGES` does **not** change it.
- **Fill latency:** `LAT = STAGES + 2` cycles (encode + XOR sponge + `STAGES` layers).
- **Critical path (Fmax):** `ROUNDS_PER_STAGE = 24/STAGES` Keccak rounds.

| `STAGES` | rounds/stage | Throughput | Critical path | 1600-bit regs |
|:--------:|:------------:|:----------:|:-------------:|:-------------:|
| 24       | 1            | 1 hash/cyc | 1 round (highest Fmax) | 24 + `pr1`   |
| 12       | 2            | 1 hash/cyc | 2 rounds      | 12 + `pr1`    |
| 8        | 3            | 1 hash/cyc | 3 rounds      | 8 + `pr1`     |
| 1        | 24           | 1 hash/cyc | 24 rounds (lowest Fmax) | 1 + `pr1`   |

> `STAGES` trades **Fmax for register area**; the Keccak *logic* is always the
> full 24 rounds. Default `STAGES = 24` maximizes Fmax; lower it only to shrink
> registers and pack more cores.

### FOLDED=1 — Single-Register Fold

Trades throughput for area: `STAGES` `keccak_round` instances chained
combinationally feed **one** reused 1600-bit register, looped `FOLD_ITERS =
24/STAGES` times per hash:

```
 pr1 ──►┌──────────────────────────────────────┐
        │ mux ─► [round]─►...─►[round] ×STAGES │─► fold_state ─► hash_out
        └──────────────▲───────────────────────┘   (also: valid_out, busy)
                        └── looped FOLD_ITERS = 24/STAGES times (mux re-selects fold_state)
```

- **Throughput:** 1 hash per `FOLD_ITERS` cycles — one hash resident at a time.
  `busy` gates re-entry so a caller can't corrupt a fold mid-flight.
- **Fill latency:** `LAT = FOLD_ITERS + 2` cycles.
- **Area:** scales with `STAGES` instances instead of the fixed 24 — far fewer
  LUTs than `FOLDED=0`, at the cost of throughput.

> Same reuse pattern as `keccak_f1600.sv`'s single-instance case. Only
> meaningful for area-constrained builds where 1 hash/cycle isn't needed.

### valid_out Alignment

`valid_in` is delayed through `valid_sr` and tapped at `valid_sr[LAT-1]` — the
same tap in both modes, since `valid_sr[0]` already represents one register
hop and `hash_out` sits `LAT` hops from `data_in` either way — so `valid_out`
lines up **exactly** with `hash_out`. `valid_sr` is the only register cleared
by `rst`, which guarantees no spurious `valid_out` during the initial fill
even though the datapath registers power up undefined.

---

## Kaspa-Specific Encoding

### Prefix Block (precomputed → sponge constants)

In full cSHAKE256 the first rate block is:

```
bytepad( encode_string(N) || encode_string(S) , 136 )
```

Since `N = ""` and `S` is one of two constants, this block is fixed. It is absorbed
**offline** (XOR into the zero state + one Keccak-f[1600]) and the resulting state is
hardcoded:

```
 Byte     Hex        Meaning
 ─────────────────────────────────────────────────────────────────
  [0]     01         left_encode(136) ── length-of-length = 1
  [1]     88         left_encode(136) ── value = 136 (0x88)
  [2]     01         encode_string("") ── left_encode(0) len = 1
  [3]     00         encode_string("") ── left_encode(0) val = 0
  [4]     01         encode_string(S) ── left_encode(bit_len) len
  [5]     78 / 48    S bit-length: 120 ("ProofOfWorkHash") or 72 ("HeavyHash")
  [6+]    ...        S string bytes (little-endian ASCII)
  [rest]  00         Zero-pad to 136 bytes (bytepad)
```

The two resulting post-prefix states are stored as `SPONGE_POW[0:24]` and
`SPONGE_HH[0:24]` (25 × 64-bit lanes each) and selected at build time by `S_VALUE` in Stage 1 (the unused table is not synthesized).

### S Value Selection

```
 ┌─────────────┬──────────────────────┬───────────────────────────────────┐
 │  S_VALUE    │  S String            │  Usage in kHeavyHash              │
 ├─────────────┼──────────────────────┼───────────────────────────────────┤
 │     0       │  "ProofOfWorkHash"   │  First hash:  cSHAKE256(header)   │
 │             │  15 bytes, 120 bits  │  80-byte input (DATA_80BYTE = 1)  │
 ├─────────────┼──────────────────────┼───────────────────────────────────┤
 │     1       │  "HeavyHash"         │  Final hash:  cSHAKE256(digest)   │
 │             │   9 bytes,  72 bits  │  32-byte input (DATA_80BYTE = 0)  │
 └─────────────┴──────────────────────┴───────────────────────────────────┘
```

### Message Block Encoding (Stage 0)

Stage 0 builds the second (data) rate block combinationally into `pr0`. Standard
cSHAKE absorbs the message **raw** (no length prefix); the `0x04` cSHAKE domain
byte sits immediately past the message and the final pad bit `0x80` occupies the
top rate byte:

```
  80-byte input (DATA_80BYTE = 1):
  1087                           647 639                          0
  ┌──────┬───────────────────────┬────┬────────────────────────────┐
  │ 0x80 │     0x00 ... 00       │0x04│      data_in (640 bits)    │
  └──────┴───────────────────────┴────┴────────────────────────────┘

  32-byte input (DATA_80BYTE = 0):
  1087                                 263 255                    0
  ┌──────┬─────────────────────────────┬────┬──────────────────────┐
  │ 0x80 │        0x00 ... 00          │0x04│     data_in[255:0]   │
  └──────┴─────────────────────────────┴────┴──────────────────────┘
     ▲                                    ▲
     │  final Keccak pad bit              │  cSHAKE padding byte
     │  (high bit of last rate byte)      │  (0x04, NOT 0x1F → cSHAKE not SHAKE)
```

The message occupies the low bytes starting at bit 0, then the `0x04` domain
byte, with the rest zero — matching NIST cSHAKE256, which does **not** length-
prefix the data `X` (only `N` and `S` are `encode_string`-wrapped, and those are
folded into the sponge constant).

> **Critical distinction:** the `0x04` byte is what makes this **cSHAKE256** rather
> than SHAKE256 (`0x1F`). Since `S` is never empty, this is hardcoded.

> **Note (fix):** an earlier revision prepended `left_encode(bit_len)` to the
> message (`0x02 0x02 0x80` / `0x02 0x01 0x00`) — a non-standard `encode_string(X)`
> wrap. That was removed so the core matches standard cSHAKE / the kHeavyHash
> reference; the `SPONGE_*` prefix constants are unaffected.

---

## Output

The 256-bit result is the first four lanes of the final Keccak state, read as
little-endian bytes:

```
hash_out = kstate[STAGES-1][255:0]     (FOLDED=0)
         = fold_state[255:0]           (FOLDED=1)
         = A[0][0] (bits  63:0)   | A[1][0] (bits 127:64)
         | A[2][0] (bits 191:128) | A[3][0] (bits 255:192)
```

---

## Resource Usage

### FOLDED=0 (spatial pipeline)

```
  cshake256_pipelined_core
   ├─ Stage 0  Encode Msg        (combinational)
   ├─ Stage 1  XOR into SpongeState (combinational + pr1 register)
   └─ Keccak layers × STAGES
        └─ keccak_round  ×24 total (theta/rho/pi/chi/iota, purely combinational)
```

```
  Resource                Source                         Size (STAGES = 24)
  ──────────────────────  ─────────────────────────────  ──────────────────────
  Encoded block register  pr0                            1,088 FF
  Sponge-state register   pr1                            1,600 FF
  Keccak pipeline regs    kstate[0..STAGES-1]            STAGES × 1,600 FF
  Valid shift register    valid_sr                       STAGES + 2 FF
  Keccak round logic      keccak_round ×24               24 rounds of theta..iota
  ──────────────────────  ─────────────────────────────  ──────────────────────
  Total (STAGES=24)                                      1088 + 25×1600 ≈ 41,088 FF
```

Lower `STAGES` reduces the `kstate` register count (= `STAGES`) proportionally
while keeping all 24 rounds of combinational logic.

**Critical path:** `ROUNDS_PER_STAGE` chained `keccak_round` blocks. At the default
`STAGES = 24` this is a single round — the same bound as any 1-round-per-cycle
Keccak design, but here at 1 hash/cycle throughput.

### FOLDED=1 (single-register fold)

```
  Resource                Source                         Size
  ──────────────────────  ─────────────────────────────  ──────────────────────
  Encoded block register  pr0                            1,088 FF
  Sponge-state register   pr1                            1,600 FF
  Fold register           fold_state                     1,600 FF (single, reused)
  Iteration counter       iter                           log2(24/STAGES) FF
  Fold-active flag        fold_active                    1 FF
  Valid shift register    valid_sr                       24/STAGES + 2 FF
  Keccak round logic      keccak_round ×STAGES           STAGES rounds of theta..iota
  ──────────────────────  ─────────────────────────────  ──────────────────────
```

Round-instance count (and LUTs) scale with `STAGES` instead of the fixed 24 —
roughly `~1-5k LUT` vs. `~20-40k LUT` for `FOLDED=0`, at the cost of only 1
hash in flight at a time. See `hw/tools/fpga_estimate.py`.

---

## Verification

Two Verilator testbenches drive the core from the Python reference model:

```
make runtest                        # correctness (HeavyHash + ProofOfWorkHash) + latency
make throughput                     # 1 hash/cycle steady-state benchmark (FOLDED=0 only)
make runtest FOLDED=0 STAGES=N      # N pipeline layers (N | 24)
make runtest FOLDED=1 STAGES=N      # N physical round instances (N | 24)
```

- **`cshake256_tb`** streams back-to-back when `LATENCY` exceeds the batch
  size, otherwise interleaves one send+receive per hash (always interleaved
  when `FOLDED=1`, since `busy` allows only one hash in flight).
- **`throughput_tb`** drives `valid_in` every cycle and reports measured
  hashes/cycle (converges to the ideal 1.0). Only exercises `FOLDED=0` — a
  folded build trades throughput for area by design.

> Pass a unique `OBJDIR=` per config — the build rule keys off source mtimes,
> not `-G` values, so switching `STAGES`/`FOLDED` without touching sources
> silently reuses a stale binary.

---

## References

- **NIST SP 800-185** — SHA-3 Derived Functions (cSHAKE specification)
- **NIST FIPS 202** — SHA-3 Standard (Keccak-f[1600])
- **kHeavyHash** — https://github.com/bcutil/kheavyhash
- **Companion docs** — [cSHAKE256 algorithm](cSHAKE256.md) | [Keccak-f RTL](keccak.md)
