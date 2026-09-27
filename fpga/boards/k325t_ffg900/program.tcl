# Program the board over JTAG.
#   vivado -mode batch -source program.tcl -tclargs blinky          ; # volatile
#   vivado -mode batch -source program.tcl -tclargs miner flash     ; # write SPI flash

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set TARGET [expr {[llength $argv] >= 1 ? [lindex $argv 0] : "blinky"}]
set MODE   [expr {[llength $argv] >= 2 ? [lindex $argv 1] : "jtag"}]
# N25Q128 flash (MT25QL128 in newer Vivado)
set CFGMEM_CANDIDATES {n25q128-3.3v-spi-x1_x2_x4 mt25ql128-spi-x1_x2_x4}

if {[file isdirectory $TARGET]} {
    set DIR [file normalize $TARGET]
} else {
    set DIR "$SCRIPT_DIR/build/$TARGET"
}
set bits [glob -nocomplain -directory $DIR *.bit]
if {[llength $bits] != 1} {
    set have [lsort [glob -nocomplain -tails -directory "$SCRIPT_DIR/build" *]]
    error "program.tcl: no single .bit in $DIR - run build.tcl first (built so far: $have)"
}
set BIT [lindex $bits 0]
set MCS "[file rootname $BIT].mcs"
if {[file exists "$DIR/build_info.txt"]} {
    set fh [open "$DIR/build_info.txt"]; puts [read $fh]; close $fh
}

open_hw
# HW_SERVER=<host>:3121 for a remote hw_server
if {[info exists ::env(HW_SERVER)] && $::env(HW_SERVER) ne ""} {
    connect_hw_server -url $::env(HW_SERVER)
} else {
    connect_hw_server
}
open_hw_target
set dev [lindex [get_hw_devices xc7k325t*] 0]
if {$dev eq ""} { error "program.tcl: no xc7k325t on the JTAG chain (found: [get_hw_devices])" }
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

if {$MODE eq "flash"} {
    if {![file exists $MCS]} { error "program.tcl: $MCS not found" }
    set part ""
    foreach c $CFGMEM_CANDIDATES {
        set found [get_cfgmem_parts -quiet $c]
        if {[llength $found] > 0} { set part [lindex $found 0]; break }
    }
    if {$part eq ""} {
        error "program.tcl: none of {$CFGMEM_CANDIDATES} known to this Vivado; candidates: [get_cfgmem_parts -quiet *25q*128*]"
    }
    puts "==== Flash part: $part ===="
    create_hw_cfgmem -hw_device $dev $part
    set cfg [get_property PROGRAM.HW_CFGMEM $dev]
    set_property PROGRAM.FILES          [list $MCS] $cfg
    set_property PROGRAM.ADDRESS_RANGE  {use_file}  $cfg
    set_property PROGRAM.BLANK_CHECK    0 $cfg
    set_property PROGRAM.ERASE          1 $cfg
    set_property PROGRAM.CFG_PROGRAM    1 $cfg
    set_property PROGRAM.VERIFY         1 $cfg
    create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
    program_hw_devices $dev
    refresh_hw_device $dev
    program_hw_cfgmem -hw_cfgmem $cfg
    boot_hw_device $dev
    puts "==== Flash written with $MCS and FPGA rebooted from it ===="
} else {
    set_property PROGRAM.FILE $BIT $dev
    program_hw_devices $dev
    refresh_hw_device $dev
    puts "==== Programmed $BIT over JTAG (volatile - power-cycle or K1 restores flash) ===="
}

close_hw_target
disconnect_hw_server
