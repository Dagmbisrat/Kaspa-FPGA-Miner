# XC7K325T-1FFG900C core board pinout.

# Config: SPI x4 flash
set_property CFGBVS VCCO                     [current_design]
set_property CONFIG_VOLTAGE 3.3              [current_design]
set_property CONFIG_MODE SPIx4               [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]

# 50 MHz clock
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33} [get_ports clk_50m]
create_clock -name clk_50m -period 20.000 [get_ports clk_50m]

# Button K2, active-low
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33} [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# LEDs, active-low: [0] by J5, [1] by J6, [2] by U1, [3] by U7
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33} [get_ports {led_n[0]}]
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS33} [get_ports {led_n[1]}]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33} [get_ports {led_n[2]}]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports {led_n[3]}]
set_false_path -to [get_ports {led_n[*]}]

# UART on J10: pin 37 = rx, pin 38 = tx, pin 1 = GND
set_property -dict {PACKAGE_PIN J29 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports uart_rx]
set_property -dict {PACKAGE_PIN J28 IOSTANDARD LVCMOS33}             [get_ports uart_tx]
set_false_path -from [get_ports uart_rx]
set_false_path -to   [get_ports uart_tx]
