# Build a bitstream for the board.
#   vivado -mode batch -source build.tcl -tclargs <target> [KEY=VALUE ...]
# Targets: blinky, pinfinder, uart, miner. Output: build/<target>/

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set REPO_ROOT  [file normalize "$SCRIPT_DIR/../../.."]
set PART       xc7k325tffg900-1

set TARGET [expr {[llength $argv] >= 1 ? [lindex $argv 0] : "blinky"}]

# Targets
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
set BOARD_SRCS [list "$SCRIPT_DIR/board_clk_rst.sv" "$SCRIPT_DIR/board_status_leds.sv"]
set XDCS       [list "$SCRIPT_DIR/k325t_ffg900.xdc"]

switch -- $TARGET {
    pinfinder {
        set TOP      pinfinder_top
        set SRCS     [list "$SCRIPT_DIR/pinfinder_top.sv"]
        set XDCS     [list "$SCRIPT_DIR/pinfinder.xdc"]
        set DEFAULTS {}
    }
    blinky {
        set TOP      blinky_top
        set SRCS     [list "$SCRIPT_DIR/blinky_top.sv"]
        set DEFAULTS {}
    }
    uart {
        set TOP      uart_test_top
        set SRCS     [concat [list "$REPO_ROOT/hw/io/uart/rtl/uart_if.sv" \
                                   "$REPO_ROOT/hw/work_controller/rtl/work_controller.sv"] \
                             $BOARD_SRCS \
                             [list "$SCRIPT_DIR/board_xadc.sv" "$SCRIPT_DIR/fake_core.sv" \
                                   "$SCRIPT_DIR/uart_test_top.sv"]]
        set DEFAULTS [list CLK_DIV 10 BAUD_RATE 115200 FIND_DELAY 1000000]
    }
    miner {
        set TOP      kaspa_miner_top
        set SRCS     [concat $MINER_SRCS $BOARD_SRCS \
                             [list "$SCRIPT_DIR/board_xadc.sv" "$SCRIPT_DIR/board_diag_uart.sv" \
                                   "$SCRIPT_DIR/kaspa_miner_top.sv"]]
        lappend XDCS "$SCRIPT_DIR/diag_uart.xdc"
        set DEFAULTS [list CLK_DIV 10 BAUD_RATE 115200 \
                           CSHAKE_STAGES 4 MATMUL_STAGES 8 CSHAKE_FOLDED 1]
    }
    default { error "build.tcl: unknown target '$TARGET' (expected blinky, pinfinder, uart or miner)" }
}

# Parameters
array set P $DEFAULTS
set positional {CLK_DIV BAUD_RATE}
foreach arg [lrange $argv 1 end] {
    if {[regexp {^([A-Za-z_]+)=(.+)$} $arg -> key val]} {
        set key [string toupper $key]
    } elseif {[llength $positional] > 0} {
        set key [lindex $positional 0]
        set positional [lrange $positional 1 end]
        set val $arg
    } else {
        error "build.tcl: don't understand argument '$arg' (use KEY=VALUE)"
    }
    if {![info exists P($key)]} {
        set known [expr {[llength $DEFAULTS] ? [join [dict keys $DEFAULTS] {, }] : "none"}]
        error "build.tcl: '$TARGET' has no parameter $key (it takes: $known)"
    }
    if {![string is integer -strict $val]} {
        error "build.tcl: $key=$val is not an integer"
    }
    set P($key) $val
}

proc divides {d n} { expr {$d >= 1 && $n % $d == 0} }
set warnings {}
if {[info exists P(CLK_DIV)]} {
    if {$P(CLK_DIV) < 5 || $P(CLK_DIV) > 128} {
        error "build.tcl: CLK_DIV=$P(CLK_DIV) out of range (5..128; 1000 MHz / CLK_DIV)"
    }
    set CLK_HZ [expr {1000000000 / $P(CLK_DIV)}]
    set ideal [expr {double($CLK_HZ) / (16.0 * $P(BAUD_RATE))}]
    set div   [expr {int($ideal)}]
    if {$div < 1} { error "build.tcl: BAUD_RATE=$P(BAUD_RATE) too fast for a [expr {$CLK_HZ/1e6}] MHz clock" }
    set baud_err [expr {abs($ideal - $div) / $ideal * 100.0}]
    if {$baud_err > 2.0} {
        lappend warnings [format "BAUD_RATE=%d at %.2f MHz is %.1f%% off - the link will likely fail (keep it under ~2%%)" \
            $P(BAUD_RATE) [expr {$CLK_HZ/1e6}] $baud_err]
    }
}
if {[info exists P(CSHAKE_STAGES)] && ![divides $P(CSHAKE_STAGES) 24]} {
    error "build.tcl: CSHAKE_STAGES=$P(CSHAKE_STAGES) must divide 24 (1 2 3 4 6 8 12 24)"
}
if {[info exists P(MATMUL_STAGES)] && ![divides $P(MATMUL_STAGES) 64]} {
    error "build.tcl: MATMUL_STAGES=$P(MATMUL_STAGES) must divide 64 (1 2 4 8 16 32 64)"
}
if {[info exists P(CSHAKE_FOLDED)]} {
    if {$P(CSHAKE_FOLDED) ni {0 1}} { error "build.tcl: CSHAKE_FOLDED must be 0 or 1" }
    if {$P(CSHAKE_FOLDED) == 0} {
        lappend warnings "CSHAKE_FOLDED=0 (unfolded) is far larger than folded and may not fit the XC7K325T"
    }
}

set tag ""
set GENERICS {}
foreach {key def} $DEFAULTS {
    lappend GENERICS "$key=$P($key)"
    if {$P($key) != $def} { append tag "_$key$P($key)" }
}
set OUT_DIR "$SCRIPT_DIR/build/$TARGET$tag"

foreach f $SRCS {
    if {![file exists $f]} {
        error "build.tcl: missing $f - '$TARGET' needs this folder inside a repo checkout at fpga/boards/k325t_ffg900"
    }
}

file mkdir $OUT_DIR
set_param general.maxThreads 8

puts "==== Building $TOP for $PART -> $OUT_DIR ===="
if {[llength $GENERICS] > 0} { puts "  parameters: $GENERICS" }
if {[info exists CLK_HZ]}   { puts [format "  fabric clock: %.2f MHz" [expr {$CLK_HZ/1e6}]] }
foreach w $warnings { puts "  WARNING: $w" }

# Build
read_verilog -sv $SRCS
foreach x $XDCS { read_xdc $x }

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

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]

write_bitstream -force "$OUT_DIR/${TOP}.bit"
write_cfgmem -force -format mcs -size 16 -interface SPIx4 \
    -loadbit "up 0x0 $OUT_DIR/${TOP}.bit" "$OUT_DIR/${TOP}.mcs"

proc util_pct {rpt label} {
    set fh [open $rpt r]; set data [read $fh]; close $fh
    if {[regexp "\\|\\s*$label\\*?\\s*\\|\\s*(\\d+)\\s*\\|\[^\\n\]*?\\|\\s*(\[0-9.\]+)\\s*\\|\\s*\\n" $data -> used pct]} {
        return "$used ($pct%)"
    }
    return "?"
}
set rpt "$OUT_DIR/${TOP}_utilization.rpt"
set timing_ok [expr {$wns >= 0 && $whs >= 0}]

set summary {}
lappend summary "target      $TARGET ($TOP) on $PART"
lappend summary "parameters  $GENERICS"
if {[info exists CLK_HZ]} { lappend summary [format "clock       %.2f MHz" [expr {$CLK_HZ/1e6}]] }
lappend summary "timing      WNS $wns ns, WHS $whs ns -> [expr {$timing_ok ? {MET} : {FAILED}}]"
lappend summary "LUTs        [util_pct $rpt {Slice LUTs}]"
lappend summary "FFs         [util_pct $rpt {Slice Registers}]"
lappend summary "BRAM        [util_pct $rpt {Block RAM Tile}]"
lappend summary "built       [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
set fh [open "$OUT_DIR/build_info.txt" w]
foreach l $summary { puts $fh $l }
close $fh

puts "===================================================="
foreach l $summary { puts " $l" }
puts " bitstream   $OUT_DIR/${TOP}.bit (+ .mcs for flash)"
if {!$timing_ok} {
    puts " TIMING FAILED - the bitstream may misbehave. Retry with a larger"
    puts " CLK_DIV (e.g. CLK_DIV=[expr {[info exists P(CLK_DIV)] ? $P(CLK_DIV) + 2 : 12}])."
}
foreach w $warnings { puts " WARNING: $w" }
puts "===================================================="
