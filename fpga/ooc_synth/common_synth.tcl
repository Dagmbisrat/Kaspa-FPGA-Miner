# common_synth.tcl
#
# Generic out-of-context (OOC) synthesis + reporting for a single IP block.
# Sourced by the per-module scripts in this directory (keccak_f1600.tcl,
# cshake256_core.tcl, ...), which set the variables below before sourcing.
#
# Required variables:
#   TOP        - top-level module name for this run
#   SRC_FILES  - Tcl list of absolute .sv source file paths
#
# Optional variables (defaults shown):
#   PART       xc7k70tfbg676-1   ; # EDIT to match the exact package/speed
#                                 ; # grade of your board before trusting
#                                 ; # timing numbers.
#   CLK_NS     5.0               ; # clock period constraint, in ns
#   CLK_PORT   clk               ; # name of the clock input port
#   HAS_CLK    1                 ; # set 0 for purely combinational IP
#                                 ; # (skips create_clock/timing reports)
#   OUT_DIR    reports/$TOP
#   GENERICS   {}                ; # Tcl list of "PARAM=VALUE" strings passed
#                                 ; # to synth_design as -generic overrides,
#                                 ; # e.g. {CSHAKE_STAGES=24 MATMUL_STAGES=8}
#
# After synthesis this also prints a plain-language summary (LUT/FF/BRAM/DSP
# used + %, WNS, and the real max frequency implied by that WNS at the
# constrained CLK_NS) and appends one row per run to reports/summary.csv, so
# a clock sweep across several runs becomes one table instead of five report
# files you have to cross-reference by hand.

if {![info exists TOP]} {
    error "common_synth.tcl: TOP must be set before sourcing"
}
if {![info exists SRC_FILES]} {
    error "common_synth.tcl: SRC_FILES must be set before sourcing"
}
if {![info exists PART]}     { set PART   xc7k70tfbg676-1 }
if {![info exists CLK_NS]}   { set CLK_NS 5.0 }
if {![info exists CLK_PORT]} { set CLK_PORT clk }
if {![info exists HAS_CLK]}  { set HAS_CLK 1 }
if {![info exists OUT_DIR]}  { set OUT_DIR "reports/$TOP" }
if {![info exists GENERICS]} { set GENERICS {} }

file mkdir $OUT_DIR
file mkdir "reports"

puts "==== Synthesizing $TOP (OOC) for part $PART ===="
foreach f $SRC_FILES { puts "  src: $f" }
if {[llength $GENERICS] > 0} {
    puts "  generics: $GENERICS"
}

read_verilog -sv $SRC_FILES

set synth_args [list -top $TOP -part $PART -mode out_of_context]
foreach g $GENERICS { lappend synth_args -generic $g }
synth_design {*}$synth_args

# ---------------------------------------------------------------------------
# Timing
# ---------------------------------------------------------------------------
set wns        "n/a"
set min_period "n/a"
set fmax_mhz   "n/a"

if {$HAS_CLK} {
    create_clock -name clk -period $CLK_NS [get_ports $CLK_PORT]
    report_timing_summary -file "$OUT_DIR/${TOP}_timing_summary.rpt"
    report_timing -delay_type max -max_paths 10 -file "$OUT_DIR/${TOP}_timing_max.rpt"

    set worst [get_timing_paths -max_paths 1 -nworst 1 -delay_type max]
    if {[llength $worst] > 0} {
        set wns [get_property SLACK $worst]
        set min_period [expr {$CLK_NS - $wns}]
        if {$min_period > 0} {
            set fmax_mhz [expr {1000.0 / $min_period}]
        }
    }
} else {
    puts "==== $TOP has no clock (HAS_CLK=0) - skipping timing reports ===="
}

# ---------------------------------------------------------------------------
# Utilization
# ---------------------------------------------------------------------------
report_utilization -file "$OUT_DIR/${TOP}_utilization.rpt"
write_checkpoint -force "$OUT_DIR/${TOP}_synth.dcp"

# Pull the headline rows back out of the report text (for the fit verdict and
# the CSV log) and the verbatim "1. Slice Logic" table (for the summary file)
# so you don't have to open the .rpt yourself for the common case.
proc get_util_row {file label} {
    set fh [open $file r]
    set data [read $fh]
    close $fh
    # Row format is: | Site Type | Used | Fixed | Prohibited | Available | Util% |
    # Site Type may carry a trailing footnote marker, e.g. "Slice LUTs*".
    set pattern "\\|\\s*$label\\*?\\s*\\|\\s*(\[0-9\]+)\\s*\\|\\s*\[0-9\]+\\s*\\|\\s*\[0-9\]+\\s*\\|\\s*(\[0-9\]+)\\s*\\|\\s*(\[0-9.\]+)\\s*\\|"
    if {[regexp $pattern $data -> used avail pct]} {
        return [list $used $avail $pct]
    }
    return [list "-" "-" "-"]
}
proc extract_section {file start_marker end_marker} {
    # A real section title is a line matching the marker exactly, immediately
    # followed by a line of dashes (its underline) - this also appears
    # verbatim in the report's Table of Contents, which is NOT followed by
    # dashes, so checking the underline is what tells the two apart.
    set fh [open $file r]
    set lines [split [read $fh] "\n"]
    close $fh
    set n [llength $lines]
    set out {}
    set capturing 0
    for {set i 0} {$i < $n} {incr i} {
        set line [lindex $lines $i]
        set trimmed [string trim $line]
        set next [expr {$i + 1 < $n ? [string trim [lindex $lines [expr {$i + 1}]]] : ""}]
        set next_is_underline [regexp {^-+$} $next]
        if {!$capturing && $trimmed eq $start_marker && $next_is_underline} {
            set capturing 1
        }
        if {$capturing && $trimmed eq $end_marker && $next_is_underline} {
            break
        }
        if {$capturing} { lappend out $line }
    }
    return [join $out "\n"]
}
set util_rpt "$OUT_DIR/${TOP}_utilization.rpt"
lassign [get_util_row $util_rpt {Slice LUTs}]      lut_used  lut_avail  lut_pct
lassign [get_util_row $util_rpt {Slice Registers}] ff_used   ff_avail   ff_pct
lassign [get_util_row $util_rpt {Block RAM Tile}]  bram_used bram_avail bram_pct
lassign [get_util_row $util_rpt {DSPs}]            dsp_used  dsp_avail  dsp_pct
set slice_logic_table [extract_section $util_rpt {1. Slice Logic} {1.1 Summary of Registers by Type}]

# "Fit" verdict: none of the four headline resources over 100% utilized.
set overflow {}
foreach {name pct} [list LUTs $lut_pct Registers $ff_pct {Block RAM} $bram_pct DSPs $dsp_pct] {
    if {[string is double -strict $pct] && $pct > 100.0} { lappend overflow $name }
}
set fits [expr {[llength $overflow] == 0}]

# ---------------------------------------------------------------------------
# Three-part summary (console + per-module summary.txt): does it fit, the
# raw Slice Logic table, does it meet the clock. Deeper analysis stays in the
# .rpt files this leaves alone.
# ---------------------------------------------------------------------------
set summary {}
lappend summary "===================================================="
lappend summary " $TOP"
lappend summary "===================================================="
if {$fits} {
    lappend summary "DOES IT FIT?  YES"
} else {
    lappend summary "DOES IT FIT?  NO  (over 100%: [join $overflow {, }])"
}
lappend summary ""
lappend summary $slice_logic_table
lappend summary ""
if {$HAS_CLK} {
    if {[string is double -strict $wns]} {
        if {$wns >= 0} {
            lappend summary [format "DOES IT MEET THE CLOCK?  YES  (target %s ns, WNS %s ns, real Fmax ~%.1f MHz)" $CLK_NS $wns $fmax_mhz]
        } else {
            lappend summary [format "DOES IT MEET THE CLOCK?  NO   (target %s ns, WNS %s ns, real Fmax ~%.1f MHz)" $CLK_NS $wns $fmax_mhz]
        }
    } else {
        lappend summary "DOES IT MEET THE CLOCK?  n/a (no timing path found)"
    }
} else {
    lappend summary "DOES IT MEET THE CLOCK?  n/a (combinational module, no clock)"
}
lappend summary "===================================================="
lappend summary "(full detail: ${TOP}_utilization.rpt, ${TOP}_timing_summary.rpt, ${TOP}_timing_max.rpt in this folder)"

foreach line $summary { puts $line }

set sfh [open "$OUT_DIR/${TOP}_summary.txt" w]
foreach line $summary { puts $sfh $line }
close $sfh

# ---------------------------------------------------------------------------
# Append one row to reports/summary.csv so a clock/param sweep across
# multiple runs reads as a table instead of N separate report files.
# ---------------------------------------------------------------------------
set csv_path "reports/summary.csv"
set csv_is_new [expr {![file exists $csv_path]}]
set cfh [open $csv_path a]
if {$csv_is_new} {
    puts $cfh "timestamp,module,part,generics,clk_ns_target,lut_used,lut_avail,lut_pct,ff_used,ff_avail,ff_pct,bram_used,bram_avail,bram_pct,dsp_used,dsp_avail,dsp_pct,wns_ns,fmax_mhz"
}
set ts [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
set generics_str [join $GENERICS ";"]
puts $cfh "$ts,$TOP,$PART,\"$generics_str\",$CLK_NS,$lut_used,$lut_avail,$lut_pct,$ff_used,$ff_avail,$ff_pct,$bram_used,$bram_avail,$bram_pct,$dsp_used,$dsp_avail,$dsp_pct,$wns,$fmax_mhz"
close $cfh

puts "==== $TOP synthesis complete. Reports in $OUT_DIR, row appended to $csv_path ===="
