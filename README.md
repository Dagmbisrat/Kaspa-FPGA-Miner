# KasMiner — Kaspa FPGA Miner (KHeavyHash)

An open-source FPGA implementation of the **Kaspa KHeavyHash proof-of-work algorithm**, targeting the **Xilinx XC7K325T** (Kintex-7) FPGA.

> ⚠️ **Status:** Work in progress — single core verified in simulation, multi-core and top-level integration pending.

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

### Multi-Core (Planned)

The final design will instantiate multiple `core` units in parallel, each assigned a non-overlapping nonce range. A top-level controller will distribute work and collect results.

### Pipelining (Planned)

Once multi-core is working, the critical path will be profiled and the design pipelined — starting with the Keccak-f[1600] round and the matmul accumulator — to push clock frequency and maximise hashes per second on the XC7K325T.

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
└── referance/          # Python reference implementation (kheavyhash_ref.py)

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

- [x] Keccak-f[1600] RTL + verification
- [x] cSHAKE256 core + verification
- [x] xoshiro256++ PRNG
- [x] Matrix generator (PRNG + rank check)
- [x] Matrix-vector multiply unit
- [x] Single `core` (full kHeavyHash pipeline) + verification
- [ ] Multi-core instantiation with nonce distribution
- [ ] Top-level with host interface
- [ ] Timing closure and pipeline optimisation on XC7K325T
- [ ] Synthesis and place-and-route on target device

---

## Goals

- Correct, fully verified KHeavyHash implementation in RTL
- Maximise hashes/sec on the XC7K325T through parallelism and pipelining
- Clean, modular design with full documentation (education-focused)
- Strong open-source FPGA portfolio project

---

## License

MIT License — see `LICENSE`.
