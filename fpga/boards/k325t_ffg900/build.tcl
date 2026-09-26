# Full synth -> place -> route -> bitstream for the XC7K325T-FFG900 board,
# Vivado non-project batch mode (no .xpr needed, works on 2018.3+).
#
# Usage (run from anywhere; outputs land in build/<TOP>/ next to this script):
#   vivado -mode batch -source build.tcl -tclargs blinky
#   vivado -mode batch -source build.tcl -tclargs miner [CLK_DIV] [BAUD_RATE]
#
#   blinky  -> blinky_top: LED blink + UART echo, first bring-up test
#   miner   -> kaspa_miner_top: the real miner (folded cSHAKE, 4 stages)
#   CLK_DIV   MMCM divider from the 1000 MHz VCO (default 10 = 100 MHz;
#             9 = 111 MHz, 8 = 125 MHz if timing allows)
#   BAUD_RATE default 115200
#
# Produces <top>.bit (JTAG, volatile) and <top>.mcs (SPI flash image, what
# the board boots from on power-up - see program.tcl).

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize "$SCRIPT_DIR/../../.."]
set PART       xc7k325tffg900-1

set TARGET    [expr {[llength $argv] >= 1 ? [lindex $argv 0] : "blinky"}]
set CLK_DIV   [expr {[llength $argv] >= 2 ? [lindex $argv 1] : 10}]
set BAUD_RATE [expr {[llength $argv] >= 3 ? [lindex $argv 2] : 115200}]

set MINER_SRCS [list \
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

switch -- $TARGET {
    blinky {
        set TOP      blinky_top
        set SRCS     [list "$SCRIPT_DIR/blinky_top.sv"]
        set GENERICS {}
    }
    miner {
        set TOP      kaspa_miner_top
        set SRCS     [concat $MINER_SRCS [list "$SCRIPT_DIR/kaspa_miner_top.sv"]]
        set GENERICS [list "CLK_DIV=$CLK_DIV" "BAUD_RATE=$BAUD_RATE"]
    }
    default { error "build.tcl: unknown target '$TARGET' (expected blinky or miner)" }
}

set OUT_DIR "$SCRIPT_DIR/build/$TARGET"
file mkdir $OUT_DIR
set_param general.maxThreads 8

puts "==== Building $TOP for $PART -> $OUT_DIR ===="
if {[llength $GENERICS] > 0} { puts "  generics: $GENERICS" }

read_verilog -sv $SRCS
read_xdc "$SCRIPT_DIR/k325t_ffg900.xdc"

set synth_args [list -top $TOP -part $PART]
foreach g $GENERICS { lappend synth_args -generic $g }
synth_design {*}$synth_args
write_checkpoint -force "$OUT_DIR/${TOP}_synth.dcp"

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force "$OUT_DIR/${TOP}_routed.dcp"

report_utilization    -file "$OUT_DIR/${TOP}_utilization.rpt"
report_timing_summary -file "$OUT_DIR/${TOP}_timing_summary.rpt"
report_io             -file "$OUT_DIR/${TOP}_io.rpt"
report_drc            -file "$OUT_DIR/${TOP}_drc.rpt"

# Post-route timing is the real verdict (the OOC synth numbers are estimates).
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]

write_bitstream -force "$OUT_DIR/${TOP}.bit"
write_cfgmem -force -format mcs -size 16 -interface SPIx4 \
    -loadbit "up 0x0 $OUT_DIR/${TOP}.bit" "$OUT_DIR/${TOP}.mcs"

puts "===================================================="
puts " $TOP built: $OUT_DIR/${TOP}.bit (+ .mcs for flash)"
puts " Post-route WNS $wns ns, WHS $whs ns"
if {$wns < 0 || $whs < 0} {
    puts " TIMING FAILED - the bitstream may misbehave. For the miner, retry"
    puts " with a larger CLK_DIV (e.g. -tclargs miner 12 for 83 MHz)."
} else {
    puts " Timing met."
}
puts "===================================================="
