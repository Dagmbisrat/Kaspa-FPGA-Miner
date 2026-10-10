# Per-IP out-of-context (OOC) synthesis

Resource and Fmax numbers per IP, no board needed. Set your part in
`common_synth.tcl` and `VIVADO_BIN` or `VIVADO_BAT` (see `../vivado.sh`).

```sh
cd fpga/ooc_synth
source ooc.sh
ooc help                 # list IPs and their params
ooc core 5.0 4 8 1       # CLK_NS CSHAKE_STAGES MATMUL_STAGES CSHAKE_FOLDED
```

Results go to `reports/<module>/<params>/<module>_summary.txt` (fits? meets
clock?), with one row per run in `reports/summary.csv`.
