# KasMiner — Kaspa FPGA Miner (KHeavyHash)

An open-source FPGA implementation of the **Kaspa KHeavyHash proof-of-work algorithm**, targeting Xilinx Kintex-7 FPGAs — starting on the **XC7K160T** for development and scaling to the **XC7K325T** for full throughput.

> ⚠️ **Status:** Work in progress — single core verified in simulation, moving toward throughput-optimised multi-core architecture and host interface integration.

---

## Design Philosophy

This project is built as a **throughput-first FPGA accelerator**, not just a miner.

Primary objective:
> Maximise hashes per second per watt on Kintex-7 through deep pipelining and parallel core replication — validated on the XC7K160T, then scaled to the XC7K325T.

Development order:
1. Optimise **one core** for maximum Fmax and clean timing
2. Measure resource usage per core
3. Replicate cores for parallel throughput
4. Integrate a high-performance host interface (PCIe preferred)
5. Close timing and optimise routing

Compute first. Interface later.

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

Each `core` instance runs a four-stage FSM:

```
IDLE → STAGE1 (MatrixGen ∥ cSHAKE1) → STAGE2 (Matmul) → STAGE3 (cSHAKE2) → DONE
```

STAGE1 runs matrix generation and the first cSHAKE hash in parallel. The matrix is cached per `PrePowHash` and reused across all nonce attempts for the same block, so only STAGE2 and STAGE3 need to repeat per nonce once the cache is warm.

### Core Optimisation (Next)

The current core is functional but not yet pipelined for maximum Fmax. Planned work:

- Pipeline Keccak-f[1600] rounds
- Pipeline the matmul accumulator
- Register stage boundaries aggressively to remove long combinational paths
- Target: **180–220 MHz** on XC7K160T (baseline), then XC7K325T

At full pipeline depth, throughput per core approaches:

```
Throughput_per_core ≈ Fmax   (e.g. 200 MHz → ~200 MH/s per core)
```

### Multi-Core Scaling (Planned)

After single-core optimisation, multiple cores will be replicated via generate loops, each assigned a non-overlapping nonce range. A lightweight result FIFO collects valid nonce outputs. Expected scaling:

```
Total_Throughput = Fmax × Core_Count
```

Target range on XC7K160T: **~1–2 GH/s** (resource-constrained). Scaling to **2–4 GH/s** on XC7K325T once validated.

### Host Interface (Planned)

Primary target is a **PCIe accelerator** architecture:

```
PCIe → AXI Bridge → Work Distributor → [kHeavyHash Core × N] → Result FIFO → PCIe Return
```

Goals: memory-mapped control registers, nonce base + range configuration, interrupt or polling-based result reporting, minimal host overhead.

An Ethernet-based interface may be used for early development testing if needed, but PCIe is the intended production interface.

---

## Repository Structure

```
hw/
├── core/               # Top-level kHeavyHash core (FSM + glue)
│   ├── rtl/            #   core.sv, matrix_cache.sv
│   ├── tb/             #   core_tb.sv
│   └── sim/            #   gen_vectors.py, expected_vectors.mem
├── crypto/
│   ├── cshake256/      # cSHAKE256 engine (absorb + Keccak-f[1600])
│   └── keccak/         # Keccak-f[1600] permutation (24-round, single-cycle)
├── matrix/
│   ├── matrix_generator/ # xoshiro256++ PRNG + GF(2) rank check
│   └── matmul_unit/    # 64×64 matrix-vector multiply (66 cycles)
└── utils/
    └── xoshiro256pp/   # Combinational xoshiro256++ PRNG

software/
└── reference/          # Python reference implementation (kheavyhash_ref.py)

docs/                   # Design documentation per module
```

---

## Verification

Every module has a Verilator testbench driven by a Python reference model. Test vectors are generated from `kheavyhash_ref.py` and compared against RTL output.

```
make runtest    # generate vectors, compile, simulate
make wave       # open waveform in GTKWave
```

Run from any module directory under `hw/` (e.g. `hw/core/`, `hw/crypto/cshake256/`).

---

## Roadmap

Progress and planned work — updated as phases complete.

### Phase 1 — Single Core *(current)*
- [x] Keccak-f[1600] RTL + verification
- [x] cSHAKE256 core + verification
- [x] xoshiro256++ PRNG
- [x] Matrix generator (PRNG + rank check)
- [x] Matrix-vector multiply unit
- [x] Single `core` (full kHeavyHash pipeline) + verification
- [ ] Pipeline optimisation (Keccak rounds, matmul accumulator)
- [ ] Achieve ≥180 MHz timing on XC7K160T
- [ ] Measure LUT / DSP / BRAM usage per core
- [ ] Confirm fit within XC7K160T resources

### Phase 2 — Multi-Core (XC7K160T)
- [ ] 4-core stable build on XC7K160T
- [ ] Determine routing ceiling on XC7K160T
- [ ] Measure GH/s scaling vs core count

### Phase 2b — Scale to XC7K325T
- [ ] Port and re-close timing on XC7K325T
- [ ] 8-core stable build on XC7K325T
- [ ] Confirm GH/s improvement vs 160T

### Phase 3 — Host Interface
- [ ] PCIe IP integration
- [ ] AXI register map (work distribution + result reporting)
- [ ] Host driver / software interface
- [ ] End-to-end hashing from PC

### Phase 4 — Optimisation
- [ ] Fmax improvement pass
- [ ] Power-per-hash reduction
- [ ] Placement constraints and floorplanning
- [ ] Long-duration stability testing

---

## Goals

- Correct, fully verified KHeavyHash implementation in RTL
- Validated on XC7K160T, scaled to XC7K325T for full throughput
- Scalable multi-core FPGA accelerator targeting ~1–2 GH/s (160T) → 2–4 GH/s (325T)
- PCIe-connected high-throughput compute engine
- Maximise hashes/sec per watt through pipelining and parallelism
- Clean, modular design with full documentation (education-focused)
- Strong open-source FPGA portfolio project

---

## License

MIT License — see `LICENSE`.
