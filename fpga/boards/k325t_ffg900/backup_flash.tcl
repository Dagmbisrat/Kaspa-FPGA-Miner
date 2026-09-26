# Back up the board's entire 16 MB SPI flash (N25Q128) - i.e. the factory
# design it boots on power-up - before program.tcl ... flash overwrites it.
#
# Usage (on the machine the JTAG cable is plugged into):
#   vivado -mode batch -source backup_flash.tcl -tclargs [OUT_FILE]
# OUT_FILE defaults to flash_backup.bin in the current directory. Keep it
# somewhere safe outside the repo. To restore later, program it back the
# same way program.tcl writes an .mcs (PROGRAM.FILES = the .bin).
#
# This loads Vivado's flash-access helper bitstream into the FPGA, so the
# running design stops until you power-cycle or press K1 (PROGRAM_B). The
# flash itself is only read, never written.

set OUT_FILE    [expr {[llength $argv] >= 1 ? [lindex $argv 0] : "flash_backup.bin"}]
set CFGMEM_PART n25q128-3.3v-spi-x1_x2_x4

open_hw
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7k325t*] 0]
if {$dev eq ""} { error "backup_flash.tcl: no xc7k325t on the JTAG chain (found: [get_hw_devices])" }
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

# Mode pins should read 001 (Master SPI) on this board.
puts "CONFIG_STATUS:"
report_property $dev REGISTER.CONFIG_STATUS*

set parts [get_cfgmem_parts $CFGMEM_PART]
if {[llength $parts] == 0} {
    error "backup_flash.tcl: '$CFGMEM_PART' unknown to this Vivado; candidates: [get_cfgmem_parts *25q128*]"
}
create_hw_cfgmem -hw_device $dev [lindex $parts 0]
set cfg [get_property PROGRAM.HW_CFGMEM $dev]

create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev

readback_hw_cfgmem -force -format bin -all -file $OUT_FILE -hw_cfgmem $cfg
puts "==== Flash backed up to [file normalize $OUT_FILE] ([file size $OUT_FILE] bytes, expect 16777216) ===="

close_hw_target
disconnect_hw_server
