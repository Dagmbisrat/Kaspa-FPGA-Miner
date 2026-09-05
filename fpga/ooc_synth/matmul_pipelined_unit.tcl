# OOC synthesis for matmul_pipelined_unit.
#
# Usage (all args optional, defaults match matmul_pipelined_unit's own
# parameter defaults):
#   vivado -mode batch -source matmul_pipelined_unit.tcl -tclargs <CLK_NS> <NUM_STAGES> <INTERNAL_MATRIX>
#
# Examples:
#   vivado -mode batch -source matmul_pipelined_unit.tcl                  ; # CLK_NS=5.0, NUM_STAGES=8, INTERNAL_MATRIX=1 (standalone-TB config)
#   vivado -mode batch -source matmul_pipelined_unit.tcl -tclargs 5.0 16  ; # deeper pipeline -> higher Fmax, more regs
#   vivado -mode batch -source matmul_pipelined_unit.tcl -tclargs 5.0 8 0 ; # IP config: matrix wired in from matrix_flat, no internal flops/write port
#
# NOTE: once wired into core.sv this unit builds with INTERNAL_MATRIX=0 (the
# real in-core config) - dropping the internal 64x64 matrix flops changes
# both LUT and Fmax noticeably, so the INTERNAL_MATRIX=1 default here (matches
# the standalone TB) is NOT what ends up in the full core.

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize "$SCRIPT_DIR/../.."]

set CLK_NS          [expr {[llength $argv] >= 1 ? [lindex $argv 0] : 5.0}]
set NUM_STAGES      [expr {[llength $argv] >= 2 ? [lindex $argv 1] : 8}]
set INTERNAL_MATRIX [expr {[llength $argv] >= 3 ? [lindex $argv 2] : 1}]

set TOP       matmul_pipelined_unit
set SRC_FILES [list "$REPO_ROOT/hw/matrix/matmul_unit/rtl/matmul_pipelined_unit.sv"]
set GENERICS  [list "NUM_STAGES=$NUM_STAGES" "INTERNAL_MATRIX=$INTERNAL_MATRIX"]

source "$SCRIPT_DIR/common_synth.tcl"
