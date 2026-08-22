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
| `NUM_STAGES`  | 24      | Keccak pipeline register layers. **Must divide 24.** Fmax-vs-area knob.       |
| `S_VALUE`     | 0       | **Build-time** S string: **0** = `"ProofOfWorkHash"`, **1** = `"HeavyHash"`.  |
| `DATA_80BYTE` | 1       | **Build-time** input size: **0** = 32-byte input, **1** = 80-byte input.      |

> `S_VALUE` and `DATA_80BYTE` are **compile-time parameters, not ports** — each
> instance is dedicated to one hash mode. This removes the runtime `s_value`
> sponge MUX, drops the unused sponge table, and fixes the Stage-0 pad offset,
> saving area when many cores are instantiated (e.g. a throughput pipeline with
> one `S_VALUE=0` core feeding one `S_VALUE=1` core). A single time-shared engine
> that must compute both hashes should instead use the serial `cshake256_core`.

### Ports

```
┌───────────────────────────────────────────────────────────────┐
│  cshake256_pipelined_core #(NUM_STAGES, S_VALUE, DATA_80BYTE) │
│                                                              │
│   clk         ───►                 ───► hash_out [255:0]     │
│   rst         ───►                 ───► valid_out            │
│   data_in [639:0] ───►                                       │
│   valid_in    ───►                                           │
└───────────────────────────────────────────────────────────────┘
```

| Port          | Dir | Width | Description                                                       |
|:------------- |:---:|:-----:|:----------------------------------------------------------------- |
| `clk`         | in  | 1     | Clock                                                             |
| `rst`         | in  | 1     | Synchronous reset — clears `valid_sr` (no false outputs)          |
| `data_in`     | in  | 640   | Input message; only `[255:0]` is used when `DATA_80BYTE = 0`      |
| `valid_in`    | in  | 1     | Assert to inject a new message on this cycle                      |
| `hash_out`    | out | 256   | cSHAKE256 result                                                  |
| `valid_out`   | out | 1     | High on the cycle `hash_out` is valid                            |

> There is **no** `start`/`done` handshake. Drive `valid_in` every cycle for full
> throughput; `valid_out` tracks each result `NUM_STAGES + 2` cycles later.

---

## Pipeline Architecture

The datapath is a straight feed-forward pipeline — no feedback, no FSM:

```
              stage 0            stage 1                 NUM_STAGES Keccak layers
          ┌───────────┐     ┌───────────────┐     ┌────────────────────────────────────┐
 data_in─►│ Encode Msg│─pr0►│ XOR into      │─pr1►│ [R rounds]─►reg ... [R rounds]─►reg├─► hash_out
 valid_in ┊(comb)     ┊     ┊ SpongeState   ┊     ┊  kstate[0]        kstate[N-1]      ┊   valid_out
          └───────────┘     └───────────────┘     └────────────────────────────────────┘
                              ▲ SPONGE_POW / SPONGE_HH        R = ROUNDS_PER_STAGE = 24/NUM_STAGES
```

| Stage        | Register  | Function                                                        |
|:------------ |:--------- |:-------------------------------------------------------------- |
| 0 Encode     | `pr0` (1088b) | Build the padded 136-byte message block (combinational)     |
| 1 XOR Sponge | `pr1` (1600b) | XOR `pr0` into the precomputed sponge constant (`S_VALUE`-selected) |
| Keccak ×N    | `kstate[0..N-1]` (1600b each) | Each layer runs `ROUNDS_PER_STAGE` rounds then registers |
| Output       | —         | `hash_out = kstate[NUM_STAGES-1][255:0]` (combinational)        |

The `NUM_STAGES` layers hold `NUM_STAGES × ROUNDS_PER_STAGE = 24` `keccak_round`
instances total, with **static** round constants (`GLOBAL_R = st*ROUNDS_PER_STAGE + r`,
sweeping `RC[0..23]`).

### Throughput, Latency & the NUM_STAGES Knob

- **Throughput:** always **1 hash/cycle** — a new `valid_in` may be asserted every
  cycle; `NUM_STAGES` does **not** change throughput.
- **Fill latency:** `NUM_STAGES + 2` cycles (encode + XOR sponge + `NUM_STAGES` layers).
- **Critical path (Fmax):** `ROUNDS_PER_STAGE = 24/NUM_STAGES` Keccak rounds.

| `NUM_STAGES` | rounds/stage | Throughput | Critical path | 1600-bit regs |
|:------------:|:------------:|:----------:|:-------------:|:-------------:|
| 24           | 1            | 1 hash/cyc | 1 round (highest Fmax) | 24 + `pr1`   |
| 12           | 2            | 1 hash/cyc | 2 rounds      | 12 + `pr1`    |
| 8            | 3            | 1 hash/cyc | 3 rounds      | 8 + `pr1`     |
| 1            | 24           | 1 hash/cyc | 24 rounds (lowest Fmax) | 1 + `pr1`   |

> `NUM_STAGES` trades **Fmax for register area**; the Keccak *logic* is always the
> full 24 rounds. Default `NUM_STAGES = 24` maximizes Fmax; lower it only to shrink
> registers and pack more cores.

### valid_out Alignment

`valid_in` is delayed through `valid_sr` and tapped at `valid_sr[LAT-2]`
(`LAT = NUM_STAGES + 2`) so `valid_out` lines up **exactly** with `hash_out`.
`valid_sr` is the only register cleared by `rst`, which guarantees no spurious
`valid_out` during the initial fill even though the datapath registers power up
undefined.

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
hash_out = kstate[NUM_STAGES-1][255:0]
         = A[0][0] (bits  63:0)   | A[1][0] (bits 127:64)
         | A[2][0] (bits 191:128) | A[3][0] (bits 255:192)
```

---

## Resource Usage

```
  cshake256_pipelined_core
   ├─ Stage 0  Encode Msg        (combinational)
   ├─ Stage 1  XOR into SpongeState (combinational + pr1 register)
   └─ Keccak layers × NUM_STAGES
        └─ keccak_round  ×24 total (theta/rho/pi/chi/iota, purely combinational)
```

```
  Resource                Source                         Size (NUM_STAGES = 24)
  ──────────────────────  ─────────────────────────────  ──────────────────────
  Encoded block register  pr0                            1,088 FF
  Sponge-state register   pr1                            1,600 FF
  Keccak pipeline regs    kstate[0..NUM_STAGES-1]        NUM_STAGES × 1,600 FF
  Valid shift register    valid_sr                       NUM_STAGES + 2 FF
  Keccak round logic      keccak_round ×24               24 rounds of theta..iota
  ──────────────────────  ─────────────────────────────  ──────────────────────
  Total (NUM_STAGES=24)                                  1088 + 25×1600 ≈ 41,088 FF
```

Lower `NUM_STAGES` reduces the `kstate` register count (= `NUM_STAGES`) proportionally
while keeping all 24 rounds of combinational logic.

**Critical path:** `ROUNDS_PER_STAGE` chained `keccak_round` blocks. At the default
`NUM_STAGES = 24` this is a single round — the same bound as any 1-round-per-cycle
Keccak design, but here at 1 hash/cycle throughput.

---

## Verification

Two Verilator testbenches drive the core from the Python reference model:

```
make runtest                 # correctness (HeavyHash + ProofOfWorkHash) + latency
make throughput              # 1 hash/cycle steady-state benchmark
make runtest    NUM_STAGES=N # build the DUT with N pipeline layers (N | 24)
make throughput NUM_STAGES=N
```

- **`cshake256_tb`** sends inputs back-to-back and compares each hash to the
  reference on consecutive cycles.
- **`throughput_tb`** drives `valid_in` every cycle and reports measured
  hashes/cycle (converges to the ideal 1.0).

---

## References

- **NIST SP 800-185** — SHA-3 Derived Functions (cSHAKE specification)
- **NIST FIPS 202** — SHA-3 Standard (Keccak-f[1600])
- **kHeavyHash** — https://github.com/bcutil/kheavyhash
- **Companion docs** — [cSHAKE256 algorithm](cSHAKE256.md) | [Keccak-f RTL](keccak.md)
- **Design notes** — `hw/crypto/cshake256/rtl/Notes.txt`
