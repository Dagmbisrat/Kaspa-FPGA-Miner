# OOC synthesis for xoshiro256pp.
# This module is purely combinational (no clk port) - it's one round of the
# generator's state-update logic - so we skip clock/timing reports and just
# get an LUT/area number for it.
# Usage: vivado -mode batch -source fpga/ooc_synth/xoshiro256pp.tcl

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize "$SCRIPT_DIR/../.."]

set TOP       xoshiro256pp
set SRC_FILES [list "$REPO_ROOT/hw/utils/xoshiro256pp/rtl/xoshiro256pp.sv"]
set HAS_CLK   0

source "$SCRIPT_DIR/common_synth.tcl"
