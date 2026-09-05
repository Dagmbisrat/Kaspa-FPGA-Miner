# OOC synthesis for matrix_generator (pulls in matrix_rankcheck, which it
# instantiates internally).
# Usage: vivado -mode batch -source fpga/ooc_synth/matrix_generator.tcl

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize "$SCRIPT_DIR/../.."]

set TOP       matrix_generator
set SRC_FILES [list \
    "$REPO_ROOT/hw/matrix/matrix_generator/rtl/matrix_generator.sv" \
    "$REPO_ROOT/hw/matrix/matrix_generator/rtl/matrix_rankcheck.sv" \
]
set CLK_NS    5.0

source "$SCRIPT_DIR/common_synth.tcl"
