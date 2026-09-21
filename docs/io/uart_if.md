# UART Host Interface

---

## Overview

`hw/core` (the hashing pipeline) is done and verified. Per the roadmap,
Phase 2 is the host interface, with UART as the first transport adapter
(simple, and simulatable in Verilator without a real PHY). This doc defines
the **UART wire protocol** — how bytes on TX/RX map onto reads/writes of
`work_controller`'s register map.

Implemented in [`hw/io/uart/rtl/uart_if.sv`](../../hw/io/uart/rtl/uart_if.sv),
verified by [`tb/uart_if_tb.sv`](../../hw/io/uart/tb/uart_if_tb.sv) against
a stand-in register-bus memory, not a real
[`work_controller`](../work_controller.md) — the two haven't been wired
together and tested end to end yet.

`uart_if` only knows bytes-in/bytes-out and the register bus. It has no idea
what `CTRL` or `TARGET` mean — that's `work_controller`'s job.

---

## 1. Where it sits

```
   ┌─────────┐   UART (TX/RX/GND, 8N1)   ┌───────────┐   reg bus    ┌─────────────────┐        ┌──────┐
   │  Host   │ ◄───────────────────────► │  uart_if  │ ◄──────────► │ work_controller │ ◄────► │ core │
   │  (PC)   │      3 wires, 3 Mbaud     │  (this)   │ addr/wdata/  │ (register map)  │        │  ×N  │
   └─────────┘                           └───────────┘ rdata/we/re  └─────────────────┘        └──────┘
```

---

## 2. Link parameters

- Standard UART, **8N1**, 3-wire (TX, RX, GND) — no flow control. Traffic is
  tiny either direction (a work packet in, rare finds out), so transport
  is not a throughput bottleneck here.
- Default **3,000,000 baud** (easy for common FT232/CP2102 USB-UART bridges),
  exposed as build-time parameters `CLK_FREQ_HZ` / `BAUD_RATE` rather than
  hardcoded.

---

## 3. Register map

`work_controller`'s register map, byte-addressed:

| Offset    | Name              | Dir | Width                        |
|:---------:|:------------------|:---:|:------------------------------|
| 0x00      | CTRL              | W   | 32b (bit0=START, bit1=STOP)   |
| 0x04      | STATUS            | R   | 32b (bit0=busy, bit1=found_valid) |
| 0x08–0x24 | PPH[0..7]         | W   | 8×32b (256b pre_pow_hash)     |
| 0x28–0x2C | TIMESTAMP[0..1]   | W   | 2×32b (64b)                   |
| 0x30–0x4C | TARGET[0..7]      | W   | 8×32b (256b)                  |
| 0x50–0x54 | NONCE_BASE[0..1]  | W   | 2×32b (64b)                   |
| 0x58–0x5C | FOUND_NONCE[0..1] | R   | 2×32b, pops FIFO front        |
| 0x60      | FOUND_WORKID      | R   | 8b                             |
| 0x64      | FOUND_COUNT       | R   | pending finds                 |

Every UART transaction moves **exactly one 32-bit register**. Multi-word
fields (PPH, TARGET, TIMESTAMP, NONCE_BASE) are just several transactions
back-to-back — the host's job, not the adapter's. This keeps `uart_if`
stateless across frames and its FSM small, in the same accessibility-first
spirit as folding the core down for resource-constrained FPGAs.

---

## 4. Frame format — fixed 8 bytes, both directions

No length field, no variable-size buffering — one frame shape covers every
case:

```
   byte:    0      1      2      3     4     5     6      7
          ┌─────┬──────┬──────┬─────┬─────┬─────┬─────┬───────┐
          │ SOF │ CMD  │ ADDR │ D0  │ D1  │ D2  │ D3  │  CHK  │
          └─────┴──────┴──────┴─────┴─────┴─────┴─────┴───────┘
           0xAA          reg     32-bit register value,        XOR of
                        offset      little-endian             bytes 1..6
```

`CMD` bit layout:

```
   bit:  7        6..2     1        0
        ┌──────┬─────────┬────────┬──────┐
        │ DIR  │  rsvd   │  NACK  │  OP  │
        └──────┴─────────┴────────┴──────┘
  DIR: 0 = host→FPGA request   1 = FPGA→host response
  OP:  0 = READ                1 = WRITE
  NACK:1 = checksum error (response only; DATA=0)
```

So in practice: `0x00`=read-req, `0x01`=write-req, `0x80`=read-resp,
`0x81`=write-ack, `0x82`=NACK.

`CHK = D1 ^ D2 ^ ... ^ D6` (XOR of CMD, ADDR, D0..D3) — an 8-bit XOR-reduce,
essentially free in hardware, and trivial to check in a test harness.

---

## 5. Worked examples (concrete, checksums included)

**Write `CTRL=1`** (start a job), addr `0x00`:

```
 host → FPGA:   AA 01 00 01 00 00 00 00     (CHK = 01^00^01^00^00^00 = 00)
 FPGA → host:   AA 81 00 01 00 00 00 80     (ack, CHK = 81^00^01^00^00^00 = 80)
```

**Read `FOUND_COUNT`**, addr `0x64` (say 1 pending find):

```
 host → FPGA:   AA 00 64 00 00 00 00 64     (CHK = 00^64^00^00^00^00 = 64)
 FPGA → host:   AA 80 64 01 00 00 00 E5     (CHK = 80^64^01^00^00^00 = E5)
```

**Sequence diagram, one write transaction:**

```
 HOST                                   uart_if                      work_controller
  │──AA 01 00 D0 D1 D2 D3 CHK──────────►│                                    │
  │        (RX shift, 8 UART bytes)     │──addr,wdata,we=1 (1 clk)──────────►│
  │                                     │◄──── (write applied) ──────────────│
  │◄──AA 81 00 D0 D1 D2 D3 CHK──────────│                                    │
  │        (TX ack, 8 UART bytes)       │                                    │
```

---

## 6. RX parser FSM

```
                    reset
                      │
                      ▼
             ┌─────────────────┐   byte == 0xAA
        ┌───►│    WAIT_SOF     │──────────────────┐
        │    └─────────────────┘                  ▼
        │      ▲ else: stay (scan for SOF)   ┌──────────┐
        │      │                             │   CMD    │
        │      │                             └────┬─────┘
        │      │                                  ▼
        │      │                             ┌──────────┐
        │      │                             │   ADDR   │
        │      │                             └────┬─────┘
        │      │                                  ▼
        │      │                        ┌─────────────────────┐
        │      │                        │ DATA0 → DATA1 →     │
        │      │                        │ DATA2 → DATA3       │
        │      │                        └──────────┬──────────┘
        │      │                                   ▼
        │      │                             ┌──────────┐
        │      │                             │   CHK    │
        │      │                             └────┬─────┘
        │      │                     chk bad │    │ chk ok
        └──────┴─────────────────────────────┘    ▼
                                              ┌───────────┐
                                              │ DISPATCH  │──► reg bus access,
                                              └───────────┘    then build + send
                                                                response frame
```

A bad checksum (or a mid-frame glitch) just drops back to `WAIT_SOF` and
resyncs on the next `0xAA` — no host-side retry protocol needed beyond
"resend if no response arrives."

---

## 7. TX side

One response (or ack/NACK) frame is built as soon as `DISPATCH` resolves, then
shifted out byte-by-byte at the configured baud. Only one frame in flight at
a time — matches the low-traffic, strict request/response nature of this
link (no need for a TX FIFO at this stage).

---

## 8. Verification

UART/PCIe PHYs aren't Verilator-simulatable, so `tb/uart_if_tb.sv` drives
this without any real PHY: a behavioral bit-bang UART model plays the host,
driving `uart_if`'s `rx` pin and sampling its `tx` pin at the configured
baud, against a stand-in register-bus memory (not a real `work_controller`).
Covers a write + readback, a bad-checksum request (expect NACK), and a
stray non-SOF byte before a valid frame (expect `WAIT_SOF` to resync).

---

## References

- [`core.md`](../core/core.md) — the `core` IP this interface feeds
