# OOC synthesis for keccak_f1600.
# Usage: vivado -mode batch -source fpga/ooc_synth/keccak_f1600.tcl

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize "$SCRIPT_DIR/../.."]

set TOP       keccak_f1600
set SRC_FILES [list \
    "$REPO_ROOT/hw/crypto/keccak/rtl/keccak_f1600.sv" \
    "$REPO_ROOT/hw/crypto/keccak/rtl/keccak_round.sv" \
]
set CLK_NS    5.0
;# PART/PART left at common_synth.tcl default - edit there once for all modules.

source "$SCRIPT_DIR/common_synth.tcl"
