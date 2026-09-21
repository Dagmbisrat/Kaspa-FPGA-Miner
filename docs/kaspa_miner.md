# kaspa_miner — Design

---

## Overview

`kaspa_miner` is the top-level module for this repo's single-core miner —
the first thing here that's actually a complete, flashable miner rather
than one piece of it. It instantiates [`uart_if`](io/uart_if.md),
[`work_controller`](work_controller.md), and [`core`](core/core.md) and
wires them together directly. There's no logic of its own: it's a
structural/glue module, so its own ports collapse to `clk`, `rst`, `rx`,
`tx` — everything else the three pieces already expose to each other stays
internal.

None of the three have been tested wired together before now — each was
verified against a stand-in for its neighbor (`uart_if` against a bare
register-bus memory, `work_controller` against a real `core` but no
`uart_if`). This is the first end-to-end path from a host's UART bytes all
the way to a winning nonce and back.

---

## 1. Block diagram

```
                                kaspa_miner
   ┌────────────────────────────────────────────────────────────────────────────────┐
   │                                                                                │
   │   ┌───────────┐   addr/wdata/    ┌─────────────────┐  start/pph/ts/  ┌──────┐  │
rx─┼──►│           │   we/re/rdata    │                 │  nonce/target   │      │  │
   │   │  uart_if  │◄────────────────►│ work_controller │────────────────►│ core │  │
tx◄┼───│           │                  │                 │◄────────────────│      │  │ 
   │   └───────────┘                  └─────────────────┘  found/found_   └──────┘  │ 
   │                                                        nonce/found_            │
   │                                                        work_id                 │
   └────────────────────────────────────────────────────────────────────────────────┘
```

Every internal wire here is a direct port-to-port connection — same names
and widths on both sides, no muxing or reshaping in between:

| `uart_if` (master)     | `work_controller` (slave) |
|:-----------------------|:---------------------------|
| `addr`, `wdata`, `we`, `re` | `addr`, `wdata`, `we`, `re` |
| `rdata` (in)           | `rdata` (out)               |

| `work_controller`      | `core`                 |
|:------------------------|:------------------------|
| `start`, `pre_pow_hash`, `timestamp`, `nonce`, `target` (out) | matching inputs |
| `found`, `found_nonce`, `found_work_id` (in) | matching outputs |

---

## 2. Ports & parameters

### Ports

| Port  | Dir | Width | Description                           |
|:------|:---:|:-----:|:--------------------------------------|
| `clk` | in  | 1     | Clock, shared by all three submodules |
| `rst` | in  | 1     | Async reset, shared by all three      |
| `rx`  | in  | 1     | UART receive (host → miner)           |
| `tx`  | out | 1     | UART transmit (miner → host)          |

### Parameters

Forwarded straight through to the submodule that owns them, so nothing
about `core`'s area/throughput tradeoff or the UART link's timing is
hardcoded at this level:

| Parameter       | Default       | Owner       | Description                                  |
|:----------------|:-------------:|:-----------:|:-----------------------------------------------|
| `CSHAKE_STAGES` | 24            | `core`      | cSHAKE pipeline depth; must divide 24          |
| `MATMUL_STAGES` | 8             | `core`      | matmul pipeline depth; must divide 64          |
| `CSHAKE_FOLDED` | 0             | `core`      | fold both cSHAKE cores (area↓, throughput↓)    |
| `CLK_FREQ_HZ`   | 200,000,000   | `uart_if`   | system clock, for baud generation              |
| `BAUD_RATE`     | 3,000,000     | `uart_if`   | UART link speed                                |

`work_controller`'s own `FOUND_DEPTH` (found-FIFO depth) is left at its
existing default rather than forwarded — the task list above only calls
out `core`'s and `uart_if`'s tunables, and a shallow found FIFO is already
enough for a single core's rare `found` pulses.

---

## 3. Sequence: a full round trip

One job loaded over UART, streamed through `core`, and a winning nonce
read back out — the register-level detail of each leg is already covered
in [`uart_if.md`](io/uart_if.md) §4–5 (frame format) and
[`work_controller.md`](work_controller.md) §5–6 (register map / found
FIFO); this shows how those two legs chain together through `kaspa_miner`:

```
 HOST                    uart_if                 work_controller              core
  │                                                                              │
  │──AA 01 08 <PPH0> CHK───►│                           │                        │
  │                         │──addr=0x08,we,wdata──────►│ pph_words[0]<=wdata    │
  │◄──AA 81 08 <PPH0> CHK───│◄──── (write applied) ─────│                        │
  │        ... repeat for PPH1..7, TIMESTAMP0..1, TARGET0..7, NONCE_BASE0..1 ... │
  │                         │                           │                        │
  │──AA 01 00 00000001 CHK─►│ (CTRL = START)            │                        │
  │                         │──addr=0x00,we,wdata=1────►│ start<=1 (1 clk)──────►│ loads pph/ts/
  │◄──AA 81 00 00000001 CHK─│◄──── (write applied) ─────│                        │ nonce/target,
  │                         │                           │                        │ streams nonces
  │                         │                           │◄── found,found_nonce=N,│
  │                         │                           │    found_work_id=W ────│
  │                         │                           │ push {N,W} → found FIFO│
  │                         │                           │                        │
  │──AA 00 64 00000000 CHK─►│ (poll FOUND_COUNT)        │                        │
  │                         │──addr=0x64,re────────────►│ rdata<=1               │
  │◄──AA 80 64 00000001 CHK─│◄──── 1 ───────────────────│                        │
  │                         │                           │                        │
  │──AA 00 58 00000000 CHK─►│ (read FOUND_NONCE[0])     │                        │
  │                         │──addr=0x58,re────────────►│ rdata<=N[31:0], pops   │
  │◄──AA 80 58 N[31:0] CHK──│◄──── N[31:0] ─────────────│ FIFO                   │
  │                         │                           │                        │
  │──AA 00 5C 00000000 CHK─►│ (read FOUND_NONCE[1])     │                        │
  │                         │──addr=0x5C,re────────────►│ rdata<=N[63:32]        │
  │◄──AA 80 5C N[63:32] CHK─│◄──── N[63:32] ────────────│ FIFO                   │
  │                         │                           │                        │
  │──AA 00 60 00000000 CHK─►│ (read FOUND_WORKID)       │                        │
  │                         │──addr=0x60,re────────────►│ rdata<=W               │
  │◄──AA 80 60 000000W CHK──│◄──── W ───────────────────│                        │
```

18 word-writes stage the job (matching `work_controller.md` §5), one
`CTRL` write fires it, `core` streams and finds a winner entirely on its
own, and the host drains it back out with the same poll-then-pop sequence
`work_controller.md` §6 already describes — `kaspa_miner` doesn't add or
change any of that behavior, it just makes the wire between the pieces
real.

---

## 4. Verification plan

The first real end-to-end test across all three pieces: drive actual UART
bytes at `rx` using bit-bang host tasks (same approach as
`hw/io/uart/tb/uart_if_tb.sv`), load a real job built from the Python-
reference vectors already used by `hw/core/sim` and
`hw/work_controller/tb/work_controller_tb.sv`, and check that a correctly
framed response carrying the expected winning nonce comes back out `tx`.
Everything downstream of `rx`/`tx` — the register map, the job load, the
streaming, the found FIFO — is already verified individually by the three
submodules' own testbenches; this testbench's job is only to confirm the
wiring between them is correct, not to re-prove any of that logic.

---

## References

- [`uart_if.md`](io/uart_if.md) — the UART transport adapter
- [`work_controller.md`](work_controller.md) — the register-bus slave / job controller
- [`core/core.md`](core/core.md) — the hashing pipeline
