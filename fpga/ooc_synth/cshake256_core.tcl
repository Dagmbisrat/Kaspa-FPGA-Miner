# OOC synthesis for the cSHAKE256 pipelined core.
#
# Usage (all args optional, defaults match cshake256_pipelined_core's own
# parameter defaults):
#   vivado -mode batch -source cshake256_core.tcl -tclargs <CLK_NS> <NUM_STAGES> <S_VALUE> <DATA_80BYTE>
#
# Examples:
#   vivado -mode batch -source cshake256_core.tcl                    ; # CLK_NS=5.0, NUM_STAGES=24, S_VALUE=0, DATA_80BYTE=1
#   vivado -mode batch -source cshake256_core.tcl -tclargs 5.0 8     ; # fewer pipeline stages -> less area, more latency
#
# NOTE: core.sv actually instantiates this twice with different S_VALUE /
# DATA_80BYTE (Cshake1: S_VALUE=0,DATA_80BYTE=1 - "ProofOfWorkHash", 80-byte;
# Cshake2: S_VALUE=1,DATA_80BYTE=0 - "HeavyHash", 32-byte). This script's
# defaults match Cshake1; pass S_VALUE=1 DATA_80BYTE=0 to check Cshake2's
# config instead - they can differ in area since DATA_80BYTE changes the
# absorb-path width.

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize "$SCRIPT_DIR/../.."]

set CLK_NS       [expr {[llength $argv] >= 1 ? [lindex $argv 0] : 5.0}]
set NUM_STAGES   [expr {[llength $argv] >= 2 ? [lindex $argv 1] : 24}]
set S_VALUE      [expr {[llength $argv] >= 3 ? [lindex $argv 2] : 0}]
set DATA_80BYTE  [expr {[llength $argv] >= 4 ? [lindex $argv 3] : 1}]

# NOTE: the module inside cshake256_core.sv is named cshake256_pipelined_core.
set TOP       cshake256_pipelined_core
set SRC_FILES [list \
    "$REPO_ROOT/hw/crypto/keccak/rtl/keccak_round.sv" \
    "$REPO_ROOT/hw/crypto/cshake256/rtl/cshake256_core.sv" \
]
set GENERICS [list "NUM_STAGES=$NUM_STAGES" "S_VALUE=$S_VALUE" "DATA_80BYTE=$DATA_80BYTE"]

source "$SCRIPT_DIR/common_synth.tcl"
