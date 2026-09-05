# OOC synthesis for the full kHeavyHash mining core (hw/core/rtl/core.sv).
#
# Usage (all args optional, defaults match core.sv's own parameter defaults):
#   vivado -mode batch -source core.tcl -tclargs <CLK_NS> <CSHAKE_STAGES> <MATMUL_STAGES>
#
# Examples:
#   vivado -mode batch -source core.tcl                     ; # CLK_NS=5.0, CSHAKE_STAGES=24, MATMUL_STAGES=8
#   vivado -mode batch -source core.tcl -tclargs 4.0         ; # tighten the clock, same pipeline depth
#   vivado -mode batch -source core.tcl -tclargs 3.0 24 16   ; # tighter clock + deeper matmul pipeline
#
# Each run appends one row to reports/summary.csv - run it a few times with
# different CLK_NS to bisect toward the real Fmax (see README.md).

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize "$SCRIPT_DIR/../.."]

set CLK_NS        [expr {[llength $argv] >= 1 ? [lindex $argv 0] : 5.0}]
set CSHAKE_STAGES [expr {[llength $argv] >= 2 ? [lindex $argv 1] : 24}]
set MATMUL_STAGES [expr {[llength $argv] >= 3 ? [lindex $argv 2] : 8}]

set TOP       core
set SRC_FILES [list \
    "$REPO_ROOT/hw/crypto/keccak/rtl/keccak_round.sv" \
    "$REPO_ROOT/hw/crypto/cshake256/rtl/cshake256_core.sv" \
    "$REPO_ROOT/hw/utils/xoshiro256pp/rtl/xoshiro256pp.sv" \
    "$REPO_ROOT/hw/matrix/matrix_generator/rtl/matrix_rankcheck.sv" \
    "$REPO_ROOT/hw/matrix/matrix_generator/rtl/matrix_generator.sv" \
    "$REPO_ROOT/hw/matrix/matmul_unit/rtl/matmul_pipelined_unit.sv" \
    "$REPO_ROOT/hw/core/rtl/matrix_cache.sv" \
    "$REPO_ROOT/hw/core/rtl/core.sv" \
]
set GENERICS [list "CSHAKE_STAGES=$CSHAKE_STAGES" "MATMUL_STAGES=$MATMUL_STAGES"]

source "$SCRIPT_DIR/common_synth.tcl"
