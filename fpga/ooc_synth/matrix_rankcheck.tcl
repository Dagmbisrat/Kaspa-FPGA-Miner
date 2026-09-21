# OOC synthesis for matrix_rankcheck in isolation (no matrix_generator or
# xoshiro256pp - the module is fully self-contained: clk/rst/start/done/
# full_rank plus a cache-read bus, no sub-instance dependencies).
# Usage: vivado -mode batch -source fpga/ooc_synth/matrix_rankcheck.tcl

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize "$SCRIPT_DIR/../.."]

set TOP       matrix_rankcheck
set SRC_FILES [list \
    "$REPO_ROOT/hw/core/matrix/matrix_generator/rtl/matrix_rankcheck.sv" \
]
set CLK_NS    5.0
;# PART/PART left at common_synth.tcl default - edit there once for all modules.

source "$SCRIPT_DIR/common_synth.tcl"
