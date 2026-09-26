# Program the XC7K325T-FFG900 board over JTAG.
#
# Usage (on the machine the JTAG cable is plugged into):
#   vivado -mode batch -source program.tcl -tclargs blinky          ; # volatile
#   vivado -mode batch -source program.tcl -tclargs miner           ; # volatile
#   vivado -mode batch -source program.tcl -tclargs miner flash     ; # permanent
#
# Without "flash": loads build/<target>/<top>.bit into the FPGA only. Lost on
# power-off, and pressing K1 (PROGRAM_B) reloads whatever is in flash, so the
# board's original design comes back. Safe to repeat as often as you like.
#
# With "flash": erases and rewrites the SPI flash with <top>.mcs, so the board
# boots it on every power-up. This OVERWRITES the factory design - run
# backup_flash.tcl first.

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set TARGET [expr {[llength $argv] >= 1 ? [lindex $argv 0] : "blinky"}]
set MODE   [expr {[llength $argv] >= 2 ? [lindex $argv 1] : "jtag"}]
set CFGMEM_PART n25q128-3.3v-spi-x1_x2_x4

switch -- $TARGET {
    blinky  { set TOP blinky_top }
    miner   { set TOP kaspa_miner_top }
    default { error "program.tcl: unknown target '$TARGET' (expected blinky or miner)" }
}
set BIT "$SCRIPT_DIR/build/$TARGET/${TOP}.bit"
set MCS "$SCRIPT_DIR/build/$TARGET/${TOP}.mcs"
if {![file exists $BIT]} { error "program.tcl: $BIT not found - run build.tcl -tclargs $TARGET first" }

open_hw
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7k325t*] 0]
if {$dev eq ""} { error "program.tcl: no xc7k325t on the JTAG chain (found: [get_hw_devices])" }
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

if {$MODE eq "flash"} {
    if {![file exists $MCS]} { error "program.tcl: $MCS not found" }
    create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts $CFGMEM_PART] 0]
    set cfg [get_property PROGRAM.HW_CFGMEM $dev]
    set_property PROGRAM.FILES          [list $MCS] $cfg
    set_property PROGRAM.ADDRESS_RANGE  {use_file}  $cfg
    set_property PROGRAM.BLANK_CHECK    0 $cfg
    set_property PROGRAM.ERASE          1 $cfg
    set_property PROGRAM.CFG_PROGRAM    1 $cfg
    set_property PROGRAM.VERIFY         1 $cfg
    # Vivado reaches the flash through a small helper bitstream in the FPGA.
    create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
    program_hw_devices $dev
    refresh_hw_device $dev
    program_hw_cfgmem -hw_cfgmem $cfg
    # Pulse PROGRAM_B so the FPGA boots the freshly written image right away.
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
