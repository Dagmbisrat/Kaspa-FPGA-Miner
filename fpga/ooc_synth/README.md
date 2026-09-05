# Per-IP out-of-context (OOC) synthesis

Real LUT/FF/BRAM/DSP + Fmax numbers per IP, and for the full pipeline, via
Vivado non-project batch mode. No board needed — just Vivado + a part.

## Setup

Set your exact part (package + speed grade) in `common_synth.tcl`:
```tcl
if {![info exists PART]}     { set PART   xc7k70tfbg676-1 }
```

## Running

From inside this directory (reports write to `reports/` relative to cwd):
```sh
cd fpga/ooc_synth
cmd.exe /c 'G:\...\vivado.bat -mode batch -source keccak_f1600.tcl'
```
(`cmd.exe /c` is needed on WSL since a `.bat` isn't directly executable —
skip it on native Windows and call `vivado.bat` directly.)

`cshake256_core.tcl`, `matmul_pipelined_unit.tcl`, and `core.tcl` take
params + clock via `-tclargs` (see each script's header comment for order):
```sh
cmd.exe /c 'G:\...\vivado.bat -mode batch -source core.tcl -tclargs 4.0 24 16'
```

## Output

- **`reports/<module>/<module>_summary.txt`** — read this first: fits?
  (any resource >100%), the raw Slice Logic table, meets clock? (WNS + real
  Fmax). Also printed to console.
- `*_utilization.rpt` / `*_timing_summary.rpt` / `*_timing_max.rpt` — full
  detail, only needed once the summary flags something.
- `reports/summary.csv` — one row per run, for comparing runs.

## Modules

| Script                        | Top module                 | Params |
|--------------------------------|-----------------------------|-------|
| `keccak_f1600.tcl`             | `keccak_f1600`              | none |
| `cshake256_core.tcl`           | `cshake256_pipelined_core`  | `CLK_NS NUM_STAGES S_VALUE DATA_80BYTE` |
| `xoshiro256pp.tcl`             | `xoshiro256pp`              | none (combinational) |
| `matrix_generator.tcl`         | `matrix_generator`          | none |
| `matmul_pipelined_unit.tcl`    | `matmul_pipelined_unit`     | `CLK_NS NUM_STAGES INTERNAL_MATRIX` |
| `core.tcl`                     | `core`                      | `CLK_NS CSHAKE_STAGES MATMUL_STAGES` |

Not covered: `hw/miner/` (still a placeholder).

Clock defaults to 5.0 ns everywhere; pass a different value as the first
`-tclargs` arg to probe another target or bisect toward real Fmax.
