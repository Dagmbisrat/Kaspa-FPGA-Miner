# work_controller — Design

---

## Overview

`work_controller` is the transport-agnostic "brain" between a transport
adapter (`uart_if` today) and the hashing `core`. It owns the register map
that [`uart_if`](io/uart_if.md) exposes over UART: it stores the job fields
the host writes, pulses `core.start` once a job is loaded, and collects
`core`'s winning nonces into a small FIFO the host polls.

It never touches UART bytes directly — it only speaks the plain
`addr/wdata/rdata/we/re` register bus, so swapping in `pcie_if`/`axi_if`
later means zero changes here.

---

## 1. Where it sits

```
   ┌─────────┐   UART    ┌───────────┐   reg bus    ┌─────────────────┐   start/pph/ts/       ┌──────┐
   │  Host   │ ◄────────►│  uart_if  │ ◄──────────► │ work_controller │   target/nonce   ────►│ core │
   │  (PC)   │           └───────────┘ addr/wdata/  │     (this)      │                       └──────┘
   └─────────┘                         rdata/we/re  └─────────────────┘ ◄── found/found_nonce/
                                                                            found_work_id
```

---

## 2. Register-bus contract (inherited from uart_if)

`we`/`re` each pulse for exactly one cycle, with `addr`/`wdata` already
stable that same cycle:

```
 clk    ──┐  ┌──┐  ┌──┐  ┌──┐  ┌──
          └──┘  └──┘  └──┘  └──┘
 addr   ──< 0x00      >───────────   (stable while we/re is high)
 we     ────┐  ┌───────────────      (write: register wdata this edge)
             └──┘
 re     ────────────┐  ┌───────      (read: rdata must be valid NEXT cycle)
                     └──┘
 rdata  ─────────────────< valid >──
```

`work_controller` satisfies the read side for free by keeping `rdata` a
**plain combinational address-decode** of its registers/FIFO head — always
valid, so it's trivially valid "the cycle after `re`" too. Any read-side
effect (the found FIFO pop, below) is gated on `re` itself, not on a
separate state machine.

---

## 3. Register map

| Offset    | Name              | Dir | Width | Backing storage                  |
|:---------:|:------------------|:---:|:-----:|:----------------------------------|
| 0x00      | CTRL              | W   | 32b   | `start` pulse (bit0)              |
| 0x04      | STATUS            | R   | 32b   | bit1 = found FIFO non-empty       |
| 0x08–0x24 | PPH[0..7]         | W   | 8×32b | `pph_reg[255:0]`                  |
| 0x28–0x2C | TIMESTAMP[0..1]   | W   | 2×32b | `ts_reg[63:0]`                    |
| 0x30–0x4C | TARGET[0..7]      | W   | 8×32b | `tgt_reg[255:0]`                  |
| 0x50–0x54 | NONCE_BASE[0..1]  | W   | 2×32b | `nonce_reg[63:0]`                 |
| 0x58–0x5C | FOUND_NONCE[0..1] | R   | 2×32b | found-FIFO head, word 0 pops it   |
| 0x60      | FOUND_WORKID      | R   | 8b    | found-FIFO head (same entry)      |
| 0x64      | FOUND_COUNT       | R   | 32b   | found-FIFO occupancy              |

`CTRL` bit1 (STOP) and `STATUS` bit0 (busy) exist in the address map for
forward compatibility but aren't wired to anything yet — `core` has no
pause input, and `FOUND_COUNT != 0` already tells the host everything it
needs about pending results.

---

## 4. Job registers -> core

Each word write just lands in a plain register — no double-buffering, no
"apply" step. `core` only samples `pre_pow_hash`/`timestamp`/`nonce`/`target`
at the instant `start` pulses, so it's safe for the host to build a job up
one word at a time and only "commit" it with the final `CTRL` write:

```
        addr        ┌─────────────┐
   ───────────────► │  decode &   │
        wdata       │  write mux  │
   ───────────────► │             │
        we          └──────┬──────┘
   ───────────────►        │
                    ┌───────┴────────┬─────────────┬──────────────┐
                    ▼                ▼             ▼              ▼
              pph_reg[255:0]   ts_reg[63:0]  tgt_reg[255:0]  nonce_reg[63:0]
                    │                │             │              │
                    └────────────────┴──────┬──────┴──────────────┘
                                             │ (all four feed core directly,
                                             │  read only at the instant below)
                                             ▼
                    CTRL write, bit0=1  ──►  core.start <= 1  (1 cycle pulse)
```

`core` handles the rest itself: a repeated `pre_pow_hash` skips straight to
streaming with the cached matrix (per [`core.md`](../core/core.md)); a new
one triggers its own regeneration. `work_controller` doesn't need to know
which case it is.

---

## 5. Sequence: loading and starting a job

```
 HOST (via uart_if)              work_controller                    core
   │                                    │                             │
   │ write PPH[0..7]   (8 words)  ────► │ pph_reg  <= wdata            │
   │ write TIMESTAMP[0..1] (2)    ────► │ ts_reg   <= wdata            │
   │ write TARGET[0..7]   (8)     ────► │ tgt_reg  <= wdata            │
   │ write NONCE_BASE[0..1] (2)   ────► │ nonce_reg<= wdata            │
   │ write CTRL = 1 (START)       ────► │ start <= 1 (1 clk) ────────► │ loads pph/ts/nonce/target,
   │                                    │                             │ begins streaming
```

18 word-writes to stage the job, then one `CTRL` write to fire it — matches
the UART frame-level walkthrough already in [`uart_if.md`](io/uart_if.md).

---

## 6. Found FIFO and the read-side pop

`core.found` is a single-cycle pulse; `work_controller` pushes it into a
small FIFO (rare event, shallow depth is plenty) and only pops it back out
when the host explicitly reads the low nonce word:

```
 core                    work_controller                      HOST (via uart_if)
  │ found=1                  │                                        │
  │ found_nonce=N       ────►│ push {N, found_work_id} → FIFO          │
  │ found_work_id=W          │ FOUND_COUNT++                           │
  │                          │                                        │
  │                          │ ◄──── read FOUND_COUNT (0x64) ──────────│  host polls
  │                          │ ──── 1 ────────────────────────────────►│
  │                          │ ◄──── read FOUND_NONCE[0] (0x58) ───────│  ***pops FIFO here***
  │                          │ ──── N[31:0] ──────────────────────────►│
  │                          │ ◄──── read FOUND_NONCE[1] (0x5C) ───────│  (same entry, no pop)
  │                          │ ──── N[63:32] ─────────────────────────►│
  │                          │ ◄──── read FOUND_WORKID (0x60) ─────────│  (same entry, no pop)
  │                          │ ──── W ────────────────────────────────►│
```

The pop happens on `(addr==0x58 && re)` only — reading `0x5C`/`0x60` just
reflects whatever the last pop latched, so the host must always read
`FOUND_NONCE[0]` first for a given entry. Multiple pending finds just repeat
the sequence: `FOUND_COUNT` reflects however many are still queued.

---

## 7. Verification plan

Same approach as `uart_if`: a register-bus testbench drives `addr/wdata/we/re`
directly (no `uart_if`, no PHY) against a real `core` instance, using the
existing Python-reference vectors from `hw/core/sim` to confirm a job loaded
through the register map produces the same winning nonce `core`'s own
testbench already checks.

---

## References

- [`uart_if.md`](io/uart_if.md) — the UART transport adapter this register bus is exposed through
- [`core.md`](../core/core.md) — the `core` IP being controlled
