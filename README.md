# KasMiner — Kaspa FPGA Miner (KHeavyHash)

An open-source FPGA implementation of the **Kaspa KHeavyHash proof-of-work algorithm**, built so it can actually be flashed and run on the Xilinx Kintex-7 FPGAs people have — from small development boards up to the **XC7K325T** for those chasing maximum throughput.

> ⚠️ **Status:** Work in progress — streaming core (folded and unfolded modes) with difficulty compare, a `work_controller` register map, a `uart_if` UART transport adapter, and `kaspa_miner` (all three wired together into a single flashable top level) are built and verified end-to-end in simulation; next up is synthesis/timing closure, then multi-core scaling.

---

## Design Philosophy

This project's goal is a **Kaspa miner people can actually flash onto the FPGA they have**, not a paper max-throughput design that only fits on expensive boards.

The core is **area/throughput tunable**: `CSHAKE_FOLDED` trades raw hashes/cycle for a dramatically smaller flip-flop footprint (a single reused register instead of one register layer per pipeline stage), so it fits on resource-constrained FPGAs that a fully unfolded, 1-hash/cycle design never would. **Folded is the practical default for most users** — full unfolded throughput is there for anyone with a large enough FPGA to use it.

Primary objective:
> Ship a correct, flashable Kaspa miner that runs on common Kintex-7 FPGAs first; maximise hashes per second per watt on larger boards second.

Development order:
1. Correctness first — bit-exact against the Python reference, in both folded and unfolded modes
2. Make it fit — area-efficient (folded) configuration as the default target for common FPGAs
3. Then optimise — Fmax, timing closure, and unfolded/multi-core throughput for those with room to spare
4. Integrate a host interface (PCIe preferred)
5. Close timing and optimise routing

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
layer per pipeline stage — a dramatically smaller flip-flop footprint, at
the cost of processing one item at a time instead of one per cycle. `core`'s
admission pacing (`N_MAX`) adapts automatically, so nothing else needs to
change. Matmul folding isn't implemented yet, but the same admission
mechanism already supports it.

`CSHAKE_FOLDED=0` (unfolded, full 1-nonce/cycle throughput) is available for
anyone with a large enough FPGA to spend the flip-flops — both modes are
also pipelined with a parametric register-layer depth (`CSHAKE_STAGES`,
`MATMUL_STAGES` — must divide 24/64) to trade Fmax against flip-flop count
independently of folding.

- Target: **180–220 MHz** on XC7K70T (baseline), then XC7K325T

At full pipeline depth, throughput per core approaches:

```
Throughput_per_core ≈ Fmax / N_MAX   (N_MAX=1 unfolded, e.g. 200 MHz → ~200 MH/s per core)
```

### Multi-Core Scaling (Planned)

After single-core optimisation, multiple cores will be replicated via generate loops, each assigned a non-overlapping nonce range. A lightweight result FIFO collects valid nonce outputs. Expected scaling:

```
Total_Throughput = Fmax × Core_Count
```

Target range on XC7K70T: **~1–2 GH/s** (resource-constrained). Scaling to **2–4 GH/s** on XC7K325T once validated.

### Host Interface

`work_controller` is the transport-agnostic register-map "brain" between a
transport adapter and `core`: it stages a job (pre-pow hash, timestamp,
target, nonce base) one register write at a time, fires `core.start` once
the last word lands, and collects winning nonces into a small FIFO the host
polls. It only speaks a plain `addr/wdata/rdata/we/re` register bus, so
swapping transports means zero changes here. See
[work_controller.md](docs/work_controller.md).

`uart_if` is the first transport adapter — a fixed 8-byte framed protocol
(SOF/CMD/ADDR/DATA×4/CHK) over 3-wire UART, moving one 32-bit register per
frame. Simple and fully Verilator-simulatable without a real PHY, so it's
the bring-up path before PCIe. See [uart_if.md](docs/io/uart_if.md).

`kaspa_miner` wires `uart_if`, `work_controller`, and `core` together into
the first complete, flashable single-core miner — the top-level module
that's actually buildable today, verified end to end (host UART bytes in,
a real found nonce back out) in [kaspa_miner.md](docs/kaspa_miner.md).

```
Host (PC) ── UART ──► uart_if ── reg bus ──► work_controller ──► core ──► found FIFO
                       └──────────────────── kaspa_miner (today) ────────────────────┘
```

Multi-core (`core × N` sharing one `work_controller`) is Phase 3, not yet built.

A **PCIe accelerator** is the intended production interface, added later as
a second register-bus adapter (hard block + AXI-Lite) with no changes to
`work_controller` or `core`:

```
PCIe → AXI Bridge → work_controller → [kHeavyHash Core × N] → Result FIFO → PCIe Return
```

Goals: memory-mapped control registers, nonce base + range configuration, interrupt or polling-based result reporting, minimal host overhead.

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
below) is driven by a Python reference model — test vectors are generated
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

## Roadmap

Progress and planned work — updated as phases complete.

### Phase 1 — Single Core
- [x] Keccak-f[1600] RTL + verification
- [x] cSHAKE256 core + verification
- [x] xoshiro256++ PRNG
- [x] Matrix generator (PRNG + rank check)
- [x] Matrix-vector multiply unit
- [x] Pipeline optimisation — feed-forward cSHAKE256 + 1-vector/cycle matmul (parametric `NUM_STAGES`)
- [x] Streaming `core` — 1 nonce/cycle pipeline (cSHAKE1 → matmul → XOR → cSHAKE2) + reference-checked TB
- [x] Standard cSHAKE256 message encoding fix
- [x] Parametric cSHAKE/matmul pipeline depth + optional `CSHAKE_FOLDED` area/throughput tradeoff, with generic per-IP admission pacing (`N_MAX`) in `core`
- [x] Analytical flip-flop usage estimate per IP (printed on `runtest`)
- [x] Difficulty/target compare + winning-nonce output
- [x] Confirm hash byte-order for the 256-bit target compare against kaspad (little-endian, matches)
- [x] Synthesis: real LUT / DSP / BRAM usage per core (yosys / Vivado)
- [ ] Confirm fit within XC7K70T resources
- [ ] Achieve ≥180 MHz timing on XC7K70T

### Phase 2 — Host Interface *(current)*
- [x] `work_controller` — register map (work in, found FIFO out), transport-agnostic
- [x] `uart_if` — UART transport adapter (framed register-bus bridge), verified without a real PHY
- [x] Register-bus testbench (verify `work_controller` without a PHY, against a real `core`)
- [x] Wire `uart_if` + `work_controller` + `core` into a single `kaspa_miner` top level
- [ ] PCIe adapter drop-in (hard block + AXI-Lite register map)
- [ ] Host driver / software interface
- [ ] End-to-end hashing from PC (single core)

### Phase 3 — Multi-Core (XC7K70T)
- [ ] Controller nonce-space split + result arbitration across N cores
- [ ] 4-core stable build on XC7K70T
- [ ] Determine routing ceiling on XC7K70T
- [ ] Measure GH/s scaling vs core count

### Phase 3b — Scale to XC7K325T
- [ ] Port and re-close timing on XC7K325T
- [ ] 8-core stable build on XC7K325T
- [ ] Confirm GH/s improvement vs 70T

### Phase 4 — Optimisation
- [ ] Fmax improvement pass
- [ ] Power-per-hash reduction
- [ ] Placement constraints and floorplanning
- [ ] Long-duration stability testing

---

## Goals

- Correct, fully verified KHeavyHash implementation in RTL
- Flashable on common, resource-constrained FPGAs by default (`CSHAKE_FOLDED`), not just large/expensive boards
- Validated on XC7K70T, scaled to XC7K325T for those chasing full throughput
- Scalable multi-core FPGA accelerator targeting ~1–2 GH/s (160T) → 2–4 GH/s (325T) for large-board deployments
- PCIe-connected high-throughput compute engine
- Maximise hashes/sec per watt through pipelining and parallelism
- Clean, modular design with full documentation (education-focused)
- Strong open-source FPGA portfolio project

---

## License

MIT License — see `LICENSE`.
