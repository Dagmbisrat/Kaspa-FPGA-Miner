# cSHAKE256 Absorb — RTL Implementation

---

## Overview

`cshake256_absorb` performs one sponge absorb step: XOR a 1088-bit block into the
rate portion of the Keccak state, then run a full Keccak-f[1600] permutation.
It is a stateless worker — the parent resets it between calls.

---

## Ports

```
┌──────────────────────────────────────────────────┐
│  cshake256_absorb                                │
│                                                  │
│   clk ──────►                  ───► done         │
│   rst ──────►                  ───► state_out    │
│   start ────►                       [1599:0]     │
│   input_block [1087:0] ──►                       │
│   input_valid ──────────►                        │
└──────────────────────────────────────────────────┘
```

| Port          | Dir | Width | Description                        |
|:------------- |:---:|:-----:|:---------------------------------- |
| `clk`         | in  |     1 | Clock                              |
| `rst`         | in  |     1 | Async reset — zeroes all state     |
| `start`       | in  |     1 | Begin absorb + permute             |
| `input_block` | in  |  1088 | Rate-sized block to XOR into state |
| `input_valid` | in  |     1 | Block ready (tied high by core)    |
| `done`        | out |     1 | High for one cycle when complete   |
| `state_out`   | out |  1600 | Full Keccak state after permute    |

---

## State Diagram

```
   ╔════════════╗    start & valid     ╔══════════════╗
   ║            ║─────────────────────►║              ║
   ║    IDLE    ║                      ║  ABSORB_XOR  ║
   ║   (00)     ║                      ║    (01)      ║
   ║            ║◄──┐                  ║              ║
   ╚════════════╝   │                  ╚══════╤═══════╝
        ▲           │                         │  1 cycle
        │           │                         │  (XOR input into 17 lanes)
   ╔════╧═══════╗   │                  ╔══════▼═══════╗
   ║            ║   │                  ║              ║
   ║    DONE    ║   │                  ║   PERMUTE    ║
   ║   (11)     ║───┘                  ║    (10)      ║
   ║            ║                      ║              ║
   ╚════════════╝◄─────────────────────╚══════════════╝
                    perm_done                24 cycles
```

```
  Phase         Cycles    Action
  ──────────    ──────    ──────────────────────────────
  ABSORB_XOR        1    XOR input_block into lanes 0–16
  PERMUTE          25    One-cycle start pulse + 24 Keccak rounds
  DONE              1    Assert done, return to IDLE
  ──────────    ──────
  Total            ~27
```

---

## Design

### XOR into Rate

The 1088-bit `input_block` maps onto the first 17 of 25 Keccak lanes (the rate portion).
Lane indexing follows `lane = x + 5*y`, matching the `keccak_round` convention:

```
  input_block bit range        lane [x][y]
  ──────────────────────       ───────────
  [  0*64 +: 64 ]             [0][0]   lane  0
  [  1*64 +: 64 ]             [1][0]   lane  1
       ...                       ...
  [  4*64 +: 64 ]             [4][0]   lane  4
  [  5*64 +: 64 ]             [0][1]   lane  5
       ...                       ...
  [ 16*64 +: 64 ]             [1][3]   lane 16
  ──────────────────────       ───────────
  Lanes 17–24 (capacity)      untouched
```

Each lane is XORed with its current value: `state_next[x][y] = state[x][y] ^ input_block[...]`

### Keccak Permutation Control

The absorber must issue a **single-cycle start pulse** to `keccak_f1600`, then wait.
A `perm_started` flag prevents re-asserting `start` on subsequent PERMUTE cycles:

```
  perm_start = (current_state == PERMUTE) && !perm_started
```

Without this, `keccak_f1600` would reload `state_in` every cycle (its start branch
has priority over the round-advance branch), stalling the permutation.

### State Persistence

The absorber's 1600-bit state register **persists across the FSM** — it is only
zeroed on `rst`. The parent core uses `rst` to clear state between absorb passes
when needed. Within a single pass, state accumulates normally:

```
  IDLE ──► state unchanged
  ABSORB_XOR ──► state ^= input_block (rate lanes only)
  PERMUTE ──► state = keccak_f1600(state)   (on perm_done)
  DONE ──► state unchanged, output on state_out
```

### Output Flattening

The internal state uses a 2D array `[0:4][0:4]` of 64-bit lanes. The 1600-bit
`state_out` is flattened with `lane_idx = x + 5*y`:

```
  state_out[ lane_idx*64 +: 64 ] = state[x][y]
```

---

## Resources

```
  Resource              Size
  ────────────────────  ────────────────────────────────
  State register        1,600 FF  (25 x 64-bit lanes)
  FSM register              2-bit
  perm_started flag         1 FF
  keccak_f1600          ~50k gates + 1,600 FF + 5-bit ctr
  ────────────────────  ────────────────────────────────
  Total                 ~3,200 FF + ~50k gates
```

> The absorber owns the majority of the flip-flops in the full
> `cshake256_core` hierarchy. See [cshake256_core](cshake256_core.md)
> for the complete resource breakdown.

---

## References

- **Parent module** — [cSHAKE256 Core RTL](cshake256_core.md)
- **Sub-module** — [Keccak-f RTL](keccak.md)
- **Algorithm** — [cSHAKE256](cSHAKE256.md)
