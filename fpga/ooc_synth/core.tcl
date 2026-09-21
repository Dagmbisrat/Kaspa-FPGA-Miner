# OOC synthesis for the full kHeavyHash mining core (hw/core/rtl/core.sv).
#
# Usage (all args optional, defaults match core.sv's own parameter defaults):
#   vivado -mode batch -source core.tcl -tclargs <CLK_NS> <CSHAKE_STAGES> <MATMUL_STAGES> <CSHAKE_FOLDED>
#
# CSHAKE_STAGES is dual-meaning depending on CSHAKE_FOLDED (see core.sv /
# cshake256_core.sv):
#   CSHAKE_FOLDED=0 (default): CSHAKE_STAGES = pipeline register-layer count (Fmax knob).
#   CSHAKE_FOLDED=1:            CSHAKE_STAGES = physical keccak_round instance count
#                                (area knob); loops 24/CSHAKE_STAGES times per hash.
#
# Examples:
#   vivado -mode batch -source core.tcl                        ; # CLK_NS=5.0, CSHAKE_STAGES=24, MATMUL_STAGES=8, CSHAKE_FOLDED=0 (unfolded)
#   vivado -mode batch -source core.tcl -tclargs 4.0            ; # tighten the clock, same pipeline depth
#   vivado -mode batch -source core.tcl -tclargs 3.0 24 16      ; # tighter clock + deeper matmul pipeline
#   vivado -mode batch -source core.tcl -tclargs 5.0 4 8 1      ; # folded cSHAKE: 4 physical rounds/pass -> far fewer LUTs
#
# Each run appends one row to reports/summary.csv - run it a few times with
# different CLK_NS to bisect toward the real Fmax (see README.md).

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize "$SCRIPT_DIR/../.."]

set CLK_NS        [expr {[llength $argv] >= 1 ? [lindex $argv 0] : 5.0}]
set CSHAKE_STAGES [expr {[llength $argv] >= 2 ? [lindex $argv 1] : 24}]
set MATMUL_STAGES [expr {[llength $argv] >= 3 ? [lindex $argv 2] : 8}]
set CSHAKE_FOLDED [expr {[llength $argv] >= 4 ? [lindex $argv 3] : 0}]

set TOP       core
set SRC_FILES [list \
    "$REPO_ROOT/hw/core/crypto/keccak/rtl/keccak_round.sv" \
    "$REPO_ROOT/hw/core/crypto/cshake256/rtl/cshake256_core.sv" \
    "$REPO_ROOT/hw/core/utils/xoshiro256pp/rtl/xoshiro256pp.sv" \
    "$REPO_ROOT/hw/core/matrix/matrix_generator/rtl/matrix_rankcheck.sv" \
    "$REPO_ROOT/hw/core/matrix/matrix_generator/rtl/matrix_generator.sv" \
    "$REPO_ROOT/hw/core/matrix/matmul_unit/rtl/matmul_pipelined_unit.sv" \
    "$REPO_ROOT/hw/core/rtl/matrix_cache.sv" \
    "$REPO_ROOT/hw/core/rtl/core.sv" \
]
set GENERICS [list "CSHAKE_STAGES=$CSHAKE_STAGES" "MATMUL_STAGES=$MATMUL_STAGES" "CSHAKE_FOLDED=$CSHAKE_FOLDED"]

source "$SCRIPT_DIR/common_synth.tcl"
