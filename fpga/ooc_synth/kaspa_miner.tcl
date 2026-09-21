# OOC synthesis for the top-level single-core miner (hw/miner/kaspa_miner).
#
# Usage (all args optional, defaults match kaspa_miner.sv's own parameter defaults):
#   vivado -mode batch -source kaspa_miner.tcl -tclargs <CLK_NS> <CSHAKE_STAGES> <MATMUL_STAGES> <CSHAKE_FOLDED> <CLK_FREQ_HZ> <BAUD_RATE>
#
# CLK_NS is the synthesis clock constraint; CLK_FREQ_HZ is uart_if's own
# baud-divider parameter. They're independent knobs, but should agree for a
# meaningful run (CLK_FREQ_HZ = 1e9 / CLK_NS) - the defaults already do
# (200MHz / 5.0ns).
#
# Examples:
#   vivado -mode batch -source kaspa_miner.tcl                     ; # CLK_NS=5.0 (200MHz), unfolded, 3Mbaud
#   vivado -mode batch -source kaspa_miner.tcl -tclargs 4.0         ; # tighten the clock to 250MHz (update CLK_FREQ_HZ too if it should match)
#   vivado -mode batch -source kaspa_miner.tcl -tclargs 5.0 4 8 1   ; # folded cSHAKE: 4 physical rounds/pass
#
# Each run appends one row to reports/summary.csv - run it a few times with
# different CLK_NS to bisect toward the real Fmax (see README.md).

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize "$SCRIPT_DIR/../.."]

set CLK_NS        [expr {[llength $argv] >= 1 ? [lindex $argv 0] : 5.0}]
set CSHAKE_STAGES [expr {[llength $argv] >= 2 ? [lindex $argv 1] : 24}]
set MATMUL_STAGES [expr {[llength $argv] >= 3 ? [lindex $argv 2] : 8}]
set CSHAKE_FOLDED [expr {[llength $argv] >= 4 ? [lindex $argv 3] : 0}]
set CLK_FREQ_HZ   [expr {[llength $argv] >= 5 ? [lindex $argv 4] : 200000000}]
set BAUD_RATE     [expr {[llength $argv] >= 6 ? [lindex $argv 5] : 3000000}]

set TOP       kaspa_miner
set SRC_FILES [list \
    "$REPO_ROOT/hw/core/crypto/keccak/rtl/keccak_round.sv" \
    "$REPO_ROOT/hw/core/crypto/cshake256/rtl/cshake256_core.sv" \
    "$REPO_ROOT/hw/core/utils/xoshiro256pp/rtl/xoshiro256pp.sv" \
    "$REPO_ROOT/hw/core/matrix/matrix_generator/rtl/matrix_rankcheck.sv" \
    "$REPO_ROOT/hw/core/matrix/matrix_generator/rtl/matrix_generator.sv" \
    "$REPO_ROOT/hw/core/matrix/matmul_unit/rtl/matmul_pipelined_unit.sv" \
    "$REPO_ROOT/hw/core/rtl/matrix_cache.sv" \
    "$REPO_ROOT/hw/core/rtl/core.sv" \
    "$REPO_ROOT/hw/work_controller/rtl/work_controller.sv" \
    "$REPO_ROOT/hw/io/uart/rtl/uart_if.sv" \
    "$REPO_ROOT/hw/miner/kaspa_miner/rtl/kaspa_miner.sv" \
]
set GENERICS [list \
    "CSHAKE_STAGES=$CSHAKE_STAGES" "MATMUL_STAGES=$MATMUL_STAGES" "CSHAKE_FOLDED=$CSHAKE_FOLDED" \
    "CLK_FREQ_HZ=$CLK_FREQ_HZ" "BAUD_RATE=$BAUD_RATE" \
]

source "$SCRIPT_DIR/common_synth.tcl"
