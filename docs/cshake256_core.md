# cSHAKE256 Core — RTL Implementation

---

## Overview

`cshake256_core` is a **Kaspa-specific** cSHAKE256 hash engine. It hardcodes the two
customization strings used by kHeavyHash (`"ProofOfWorkHash"` and `"HeavyHash"`) and
fixes the output length at 256 bits, eliminating general-purpose encoding logic and
reducing the design to a compact two-absorb FSM.

> **Why not a general cSHAKE256?**
> The full spec supports variable N, S, output length, and multi-block absorb/squeeze.
> Kaspa only ever uses two fixed configurations — so the entire spec collapses to a
> fixed two-pass pipeline with a single-bit selector.

### Kaspa-Specific Shortcuts

| General cSHAKE256      | Kaspa Miner           | Simplification                              |
| ---------------------- | --------------------- | ------------------------------------------- |
| Variable **N** string  | N = `""` always       | `encode_string(N)` becomes constant `01 00` |
| Variable **S** string  | S = one of two values | 1-bit MUX between two `localparam`s         |
| Variable output length | Always 256 bits       | No squeeze loop — read first 4 lanes        |
| Multi-block input      | Always 256-bit input  | Single absorb block, no length tracking     |

---

## Module Structure

### `cshake256_core` — Top-Level Controller

Orchestrates prefix encoding and data absorption through two calls to the absorb sub-module.

```
┌─────────────────────────────────────────────────────────┐
│  cshake256_core                                         │
│                                                         │
│   Inputs             Outputs                            │
│   ───────            ────────                           │
│   clk          ───►  hash_out [255:0]                   │
│   rst          ───►  done                               │
│   start                                                 │
│   data_in [255:0]                                       │
│   s_value                                               │
└─────────────────────────────────────────────────────────┘
```

| Port       | Dir | Width | Description                                         |
|:---------- |:---:|:-----:|:--------------------------------------------------- |
| `clk`      | in  | 1     | Clock                                               |
| `rst`      | in  | 1     | Async reset                                         |
| `start`    | in  | 1     | Begin hashing                                       |
| `data_in`  | in  | 256   | Input data (header hash or digest)                  |
| `s_value`  | in  | 1     | **0** = `"ProofOfWorkHash"` , **1** = `"HeavyHash"` |
| `hash_out` | out | 256   | cSHAKE256 result                                    |
| `done`     | out | 1     | High for one cycle when hash is ready               |

### `cshake256_absorb` — Absorb Sub-Module

XORs a 1088-bit block into the rate portion of the Keccak state (17 lanes),
then runs one full Keccak-f[1600] permutation (~27 cycles per call).

See [cshake256_absorb](cshake256_absorb.md) for full design details.

---

## State Diagram

```
          ┌───────────────────────────────────────────────────────┐
          │                     start = 1                         │
          │                                                       │
          ▼                                                       │
   ╔═════════════╗         ╔═════════════╗                        │
   ║             ║         ║             ║                        │
   ║    INIT     ║────────►║   ENCODE    ║                        │
   ║   (001)     ║ 1 cyc   ║  PREFIX     ║                        │
   ║             ║         ║   (010)     ║                        │
   ╚═════════════╝         ╚══════╤══════╝                        │
                                  │                               │
                       Zero       │  absorb_done = 1              │
                       state,     │  (~27 cycles)                 │
                       reset      │                               │
                       absorber   ▼                               │
                           ╔═════════════╗                        │
                           ║             ║                        │
                           ║   ABSORB    ║                        │
                           ║   INPUT     ║                        │
                           ║   (011)     ║                        │
                           ║             ║                        │
                           ╚══════╤══════╝                        │
                                  │                               │
                                  │  absorb_done = 1              │
                                  │  (~27 cycles)                 │
                                  ▼                               │
   ╔═════════════╗         ╔═════════════╗                        │
   ║             ║◄────────║             ║                        │
   ║    IDLE     ║ 1 cyc   ║    DONE     ║                        │
   ║   (000)     ║         ║   (100)     ║────────────────────────┘
   ║             ║         ║             ║
   ╚═════════════╝         ╚═════════════╝
                            latch hash_out
```

### Cycle Budget

```
  Phase            Cycles     What Happens
  ─────────────    ──────     ─────────────────────────────────────
  INIT                 1      Zero state, reset absorber
  ENCODE_PREFIX      ~27      Build prefix block ──► XOR + Keccak-f
  ABSORB_INPUT       ~27      Pack data block   ──► XOR + Keccak-f
  DONE                 1      Latch hash_out[255:0]
  ─────────────    ──────
  Total              ~56      Two full permutations + overhead
```

---

## Kaspa-Specific Encoding

### The General Formula

In the full cSHAKE256 spec, a prefix block is built as:

```
bytepad( encode_string(N) || encode_string(S) , 136 )
```

### What Kaspa Hardcodes

Since N is always empty and S is one of two constants, the core builds the entire
prefix **combinationally** in `ENCODE_PREFIX` — no runtime encoding needed:

```
 Byte     Hex        Meaning
 ─────────────────────────────────────────────────────────────────
  [0]     01         left_encode(136) ── length-of-length = 1
  [1]     88         left_encode(136) ── value = 136 (0x88)
  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
  [2]     01         encode_string("") ── left_encode(0) len = 1
  [3]     00         encode_string("") ── left_encode(0) val = 0
  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
  [4]     01         encode_string(S) ── left_encode(bit_len) len
  [5]     78 / 48    S bit-length: 120 or 72
  [6+]    ...        S string bytes (little-endian ASCII)
  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
  [rest]  00         Zero-pad to 136 bytes ── bytepad for free
```

> The remaining bits of the 1088-bit `absorb_buffer` default to zero,
> so `bytepad` padding requires no extra logic.

### S Value Selection

```
 ┌─────────────┬──────────────────────┬───────────────────────────────────┐
 │  s_value    │  S String            │  Usage in kHeavyHash              │
 ├─────────────┼──────────────────────┼───────────────────────────────────┤
 │     0       │  "ProofOfWorkHash"   │  First hash:  cSHAKE256(header)   │
 │             │  15 bytes, 120 bits  │                                   │
 ├─────────────┼──────────────────────┼───────────────────────────────────┤
 │     1       │  "HeavyHash"         │  Final hash:  cSHAKE256(digest)   │
 │             │   9 bytes,  72 bits  │                                   │
 └─────────────┴──────────────────────┴───────────────────────────────────┘
```

Both strings are stored as little-endian ASCII `localparam`s and MUXed into
the absorb buffer by the single `s_value` bit.

---

## Data Block Padding (`ABSORB_INPUT`)

The 256-bit input is placed at the bottom of the 1088-bit absorb buffer with
cSHAKE256 domain-separation padding:

```
  1087                                 263  255                    0
  ┌──────┬─────────────────────────────┬────┬──────────────────────┐
  │ 0x80 │        0x00 ... 00          │0x04│      data_in         │
  │      │      (implicit zeros)       │    │     (256 bits)       │
  └──────┴─────────────────────────────┴────┴──────────────────────┘
     ▲                                    ▲
     │                                    │
     │  Final Keccak pad bit              │  cSHAKE padding byte
     │  (high bit of last rate byte)      │  (0x04, NOT 0x1F)
```

> **Critical distinction:** The `0x04` padding byte is what makes this
> cSHAKE256 rather than SHAKE256 (which uses `0x1F`). Since the core
> is always in cSHAKE mode (S is never empty), this is hardcoded.

---

## Datapath

```
                           s_value
                              │
              ┌───────────────┼───────────────┐
              │           ┌───▼───┐           │
              │           │ S MUX │           │
              │           │ 0 / 1 │           │
              │           └───┬───┘           │
              │               │               │
              │   ┌───────────▼────────────┐  │
              │   │    Prefix Builder      │  │
              │   │  left_encode + S bytes │  │
              │   └───────────┬────────────┘  │
              │               │               │
              │       ┌───────▼───────┐       │
  data_in ────┼──────►│ absorb_buffer │       │
  [255:0]     │       │  1088-bit MUX │       │
              │       │ (prefix/data) │       │
              │       └───────┬───────┘       │
              │               │               │
              │       ┌───────▼───────┐       │
              │       │    absorber   │       │
              │       │  XOR 17 lanes │       │
              │       │      +        │       │
              │       │ Keccak-f[1600]│       │
              │       │  (24 rounds)  │       │
              │       └───────┬───────┘       │
              │               │               │
              │       ┌───────▼───────┐       │
              │       │  data_state   │       │
              │       │ 1600-bit reg  │       │
              │       └───────┬───────┘       │
              │               │               │
              │       ┌───────▼───────┐       │
              │       │   hash_out    │       │
              │       │ [255:0] latch │       │
              │       └───────────────┘       │
              │                               │
              └───────────────────────────────┘
```

---

## Resource Usage

### Sub-Module Hierarchy

```
  cshake256_core
   └─── cshake256_absorb
         └─── keccak_f1600
               └─── keccak_round    (combinational, instantiated once, iterated 24x)
```

### Register & Logic Breakdown

```
  Resource                Source               Size
  ──────────────────────  ───────────────────  ──────────────────────────
  Keccak state register   cshake256_absorb     1,600 FF  (25 x 64-bit lanes)
  Data state register     cshake256_core       1,600 FF
  Hash output register    cshake256_core         256 FF
  Absorb buffer MUX       cshake256_core       1,088-bit  2:1 MUX
  S-string MUX            cshake256_core         120-bit  2:1 MUX
  Keccak round logic      keccak_round          ~50k gates (theta/rho/pi/chi/iota)
  Round counter            keccak_f1600            5-bit counter
  FSM registers           both modules         3-bit + 2-bit
  ──────────────────────  ───────────────────  ──────────────────────────
  Total registers                              ~3,456 FF
```

**Critical path:** The `keccak_round` combinational block (all five Keccak steps in
a single cycle). This is the same bottleneck as any single-round-per-cycle Keccak design.

### Why Two 1600-bit State Registers?

The core keeps its own `data_state` to hold the Keccak state **between** the two absorb
passes. The absorber's internal state is reset (via `rst`) before each pass, and the
core feeds accumulated state back through `absorb_state_out`. This keeps the absorber
a simple single-block unit — it doesn't need to manage multi-pass state internally.

```
  Pass 1 (prefix):   absorber resets ──► XOR + permute ──► result → data_state
  Pass 2 (data):     absorber resets ──► XOR + permute ──► result → data_state → hash_out
```

---

## References

- **NIST SP 800-185** — SHA-3 Derived Functions (cSHAKE specification)
- **NIST FIPS 202** — SHA-3 Standard (Keccak-f[1600])
- **kHeavyHash** — https://github.com/bcutil/kheavyhash
- **Companion docs** — [cSHAKE256 Absorb RTL](cshake256_absorb.md) | [cSHAKE256 algorithm](cSHAKE256.md) | [Keccak-f RTL](keccak.md)
