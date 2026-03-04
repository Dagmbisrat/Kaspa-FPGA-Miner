# kHeavyHash Reference Implementation

Python reference implementation of the [kHeavyHash](https://github.com/nicehash/NiceHashQuickMiner/tree/master/kheavyhash) proof-of-work algorithm used by Kaspa.

## Files

| File | Description |
|---|---|
| `kheavyhash_ref.py` | Core implementation |
| `tests/test_kheavyhash.py` | Unit and benchmark tests |
| `tests/kheavyhash_port.py` | CLI tool for manual hash verification |
| `tests/ref_kheavyhash_port.go` | Go reference for cross-checking |

## Algorithm Overview

```
pre_pow_hash + timestamp + nonce
        │
        ▼
  cSHAKE256("ProofOfWorkHash")  ──► pow_hash
        │                                │
        ▼                                │
  matrix (64×64, cached per block)       │
        │                                │
        ▼                                │
  matrix × vector(pow_hash)             │
        │                                │
        ▼                                │
      XOR ◄────────────────────────────┘
        │
        ▼
  cSHAKE256("HeavyHash")
        │
        ▼
   final_hash
```

The 64×64 matrix is generated from `pre_pow_hash` only and cached for the lifetime of a block, so it is computed once regardless of how many nonces are tried.

## Usage

### Single hash
```python
from kheavyhash_ref import KHeavyhash

khash = KHeavyhash()
result = khash.hash(pre_pow_hash, timestamp, nonce)
```

### Batched (CPU — multi-core, numpy BLAS)
```python
results = khash.hash_cpu_batch(pre_pow_hash, timestamp, list(range(1024)))
```

### Batched (GPU — single GEMV kernel, requires CUDA)
```python
results = khash.hash_gpu_batch(pre_pow_hash, timestamp, list(range(1024)))
```

Both batch methods return results in the same order as the input nonce list.

### CLI verification tool
```bash
cd tests
python kheavyhash_port.py <pre_pow_hash_hex> <timestamp> <nonce>
# e.g.
python kheavyhash_port.py aaff1234567890abcdef1234567890abcdef1234567890abcdef1234567890ab 1700000000 42
```

## Running Tests

```bash
cd tests
pip install pytest numpy torch pycryptodome

# All tests
pytest test_kheavyhash.py -v

# Correctness only (skip 60s benchmark)
pytest test_kheavyhash.py -v -k "not performance"

# CPU/GPU comparison only
pytest test_kheavyhash.py::TestCpuGpuBatch -v -s
```

GPU tests are automatically skipped if CUDA is not available.

## Dependencies

| Package | Purpose |
|---|---|
| `pycryptodome` | cSHAKE256 / raw Keccak primitives |
| `numpy` | Vectorized nibble ops and BLAS GEMV for CPU batch |
| `torch` | GPU tensor ops for `hash_gpu_batch` |
