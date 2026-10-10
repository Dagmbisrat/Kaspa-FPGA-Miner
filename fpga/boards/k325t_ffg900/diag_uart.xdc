# Diag UART (miner only): J10 pin 40 -> USB-serial adapter RXD
set_property -dict {PACKAGE_PIN K29 IOSTANDARD LVCMOS33} [get_ports diag_tx]
set_false_path -to [get_ports diag_tx]
