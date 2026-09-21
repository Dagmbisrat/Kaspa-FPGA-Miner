# KasMiner: Kaspa FPGA Miner (KHeavyHash)

An open-source FPGA implementation of the **Kaspa KHeavyHash proof-of-work algorithm** for Xilinx Kintex-7 FPGAs. The goal is a miner users can flash onto an FPGA they have, from the **XC7K325T** down to smaller, cheaper boards like the **XC7K70T**.

`kaspa_miner` (streaming core, `work_controller` register map, and `uart_if`
UART transport, all wired into a single flashable top level) is verified
end to end in simulation and, on the XC7K325T with `CSHAKE_FOLDED=1,
CSHAKE_STAGES=4`, fits and closes timing in Vivado.

---

## Design Philosophy

This project's goal is a **Kaspa miner users can flash onto the FPGA they have**, not a paper max-throughput design that only fits on expensive boards.

The core is **area/throughput tunable**: `CSHAKE_FOLDED` trades raw hashes/cycle for a dramatically smaller flip-flop footprint (a single reused register instead of one register layer per pipeline stage), so it fits on resource-constrained FPGAs that a fully unfolded, 1-hash/cycle design never would. **Folded is the practical default for most users.** Full unfolded throughput is there for anyone with a large enough FPGA to use it.

Correctness and accessibility first. Raw throughput is a knob, not the whole point.

---

## What is KHeavyHash?

KHeavyHash is Kaspa's proof-of-work algorithm. It combines two cSHAKE256 hashes with a 64×64 matrix multiplication to create a memory-hard workload that is resistant to naive ASIC optimisation. Each hash requires:

1. **cSHAKE256** ("ProofOfWorkHash") on the 80-byte block header
2. **Matrix generation** from `PrePowHash` using xoshiro256++ PRNG (generated once per block, reused across nonces)
3. **Matrix × vector** multiplication (64×64 × 64 nibbles)
4. **cSHAKE256** ("HeavyHash") on the XOR of the product and the first hash

---

## Architecture

### Single Core Pipeline

Each `core` instance is a **streaming pipeline**, not a per-nonce FSM: once a
block's matrix is cached, nonces flow continuously through a feed-forward
chain, admitting a new one every `N_MAX` cycles:

```
nonce++ → cSHAKE1 → matmul → XOR(pow_hash) → cSHAKE2 → hash_out
         (POW,80B)  (matrix)                (HH,32B)   + nonce_out
```

A small control FSM (`GEN → LOAD → STREAM`) only runs on a **new block**: it
(re)generates the 64×64 matrix and rebuilds matmul's product tables, then
streams. A repeated `PrePowHash` skips straight to `STREAM` and reuses the
cached matrix/tables. See [core.md](docs/core/core.md) for the full pacing
and tag-FIFO details.

### Fmax & Area/Throughput Tradeoffs

**`CSHAKE_FOLDED=1` is the recommended default for most FPGAs.** It folds
both cSHAKE cores down to a single reused register instead of one register
layer per pipeline stage, a dramatically smaller flip-flop footprint, at
the cost of processing one item at a time instead of one per cycle. `core`'s
admission pacing (`N_MAX`) adapts automatically, so nothing else needs to
change. Matmul folding isn't implemented yet, but the same admission
mechanism already supports it.

`CSHAKE_FOLDED=0` (unfolded, full 1-nonce/cycle throughput) is available for
anyone with a large enough FPGA to spend the flip-flops. Both modes are
also pipelined with a parametric register-layer depth (`CSHAKE_STAGES`,
`MATMUL_STAGES`, both must divide 24/64) to trade Fmax against flip-flop
count independently of folding.

- On **XC7K325T** with `CSHAKE_FOLDED=1, CSHAKE_STAGES=4` (Vivado synthesis):
  75.5% LUT, 23.9% FF, real Fmax **~139 MHz** (target 8.5 ns / 117.6 MHz,
  WNS +1.32 ns).

At full pipeline depth, throughput per core approaches:

```
Throughput_per_core ≈ Fmax / N_MAX   (N_MAX=1 unfolded, e.g. 200 MHz → ~200 MH/s per core)
```

### Host Interface

`work_controller` is the transport-agnostic register-map "brain" between a
transport adapter and `core`: it stages a job (pre-pow hash, timestamp,
target, nonce base) one register write at a time, fires `core.start` once
the last word lands, and collects winning nonces into a small FIFO the host
polls. It only speaks a plain `addr/wdata/rdata/we/re` register bus, so
swapping transports means zero changes here. See
[work_controller.md](docs/work_controller.md).

`uart_if` is the first transport adapter: a fixed 8-byte framed protocol
(SOF/CMD/ADDR/DATA×4/CHK) over 3-wire UART, moving one 32-bit register per
frame. Simple and fully Verilator-simulatable without a real PHY.
See [uart_if.md](docs/io/uart_if.md).

`kaspa_miner` wires `uart_if`, `work_controller`, and `core` together into
the complete, flashable single-core miner, verified end to end (host UART
bytes in, a real found nonce back out) in [kaspa_miner.md](docs/kaspa_miner.md).

```
Host (PC) ── UART ──► uart_if ── reg bus ──► work_controller ──► core ──► found FIFO
                       └────────────────────── kaspa_miner ──────────────────────┘
```

---

## Repository Structure

```
hw/
├── core/               # Top-level kHeavyHash core (streaming pipeline + block-load FSM)
│   ├── rtl/            #   core.sv, matrix_cache.sv
│   ├── tb/             #   core_tb.sv
│   ├── sim/            #   gen_vectors.py, expected_vectors.mem
│   ├── crypto/         # (only core uses these, so they live under it)
│   │   ├── cshake256/  #   cSHAKE256 engine (parametric STAGES, optional FOLDED)
│   │   └── keccak/     #   Keccak-f[1600] permutation (24-round, single-cycle)
│   ├── matrix/
│   │   ├── matrix_generator/ # xoshiro256++ PRNG + GF(2) rank check
│   │   └── matmul_unit/      # 64×64 matrix-vector multiply (parametric STAGES, must divide 64)
│   └── utils/
│       └── xoshiro256pp/     # Combinational xoshiro256++ PRNG
├── work_controller/    # Transport-agnostic register map ("brain" between host and core)
│   ├── rtl/            #   work_controller.sv
│   └── tb/             #   work_controller_tb.sv (drives the register bus directly)
├── io/
│   └── uart/           # UART transport adapter (framed register-bus bridge)
│       ├── rtl/        #   uart_if.sv
│       └── tb/         #   uart_if_tb.sv (bit-bang UART host model, no PHY)
├── miner/
│   └── kaspa_miner/    # Top-level single-core miner: uart_if + work_controller + core wired together
│       ├── rtl/        #   kaspa_miner.sv
│       └── tb/         #   kaspa_miner_tb.sv (bit-bang UART host model, full round trip)
└── tools/
    └── fpga_estimate.py # Analytical flip-flop usage estimate per IP

software/
└── referance/          # Python reference implementation (kheavyhash_ref.py)

docs/                   # Design documentation per module
```

---

## Verification

Every module has a Verilator testbench. The hashing pipeline (`core` and
below) is driven by a Python reference model: test vectors are generated
from `kheavyhash_ref.py` and compared against RTL output. `work_controller`
and `uart_if` aren't part of that hash math, so they're verified against
stand-ins instead: `uart_if` drives a bare register-bus memory with a
behavioral bit-bang UART host model (no real PHY needed), and
`work_controller` drives a real `core` instance directly over the register
bus (no `uart_if`), reusing `core`'s own reference vectors to confirm a job
loaded through the register map produces the same winning nonce.
`kaspa_miner`'s testbench is the first to combine all three for real: it
bit-bangs actual UART frames at `rx`/`tx` to load a job and reads a found
nonce back out the wire, reusing the same reference vectors.

```
make runtest    # generate vectors (if applicable), compile, simulate
make wave       # open waveform in GTKWave
```

Run from any module directory under `hw/` (e.g. `hw/core/`, `hw/work_controller/`, `hw/io/uart/`, `hw/miner/kaspa_miner/`).

---

## License

MIT License. See `LICENSE`.
