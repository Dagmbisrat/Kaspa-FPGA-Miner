# Pin constraints for the unbranded XC7K325T-1FFG900C PCIe core board
# (Alibaba "XC7K325T-900 PCIe" board). Pins come from the seller's
# schematic (XC7K325T-FFG900.pdf) and their test project's PCIe.xdc - see
# README.md in this folder for the full table and where each came from.
#
# Shared by every top in this folder (blinky_top, kaspa_miner_top), which
# all expose the same port list.

# ---------------------------------------------------------------------------
# Configuration: Master SPI x4 from the on-board N25Q128 (M[2:0]=001 is
# strapped on the board). Same settings the seller's test project uses.
# ---------------------------------------------------------------------------
set_property CFGBVS VCCO                     [current_design]
set_property CONFIG_VOLTAGE 3.3              [current_design]
set_property CONFIG_MODE SPIx4               [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]

# ---------------------------------------------------------------------------
# 50 MHz single-ended oscillator Y1 -> GCLK2 -> D12 (bank 18, 3.3 V, MRCC)
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN D12 IOSTANDARD LVCMOS33} [get_ports clk_50m]
create_clock -name clk_50m -period 20.000 [get_ports clk_50m]

# ---------------------------------------------------------------------------
# Button K2 -> A15, 10k pull-up to 3.3 V: reads 0 while pressed (active-low)
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33} [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# ---------------------------------------------------------------------------
# User LEDs: pin -> 3.3k -> LED -> 3.3 V, so drive 0 to light (active-low).
# Designators are the schematic's; the physical board's silkscreen may
# differ (one board seen labelled V1/V7), so blinky gives each a distinct
# blink rate to tell them apart.
#   led_n[0] = V2 on A11 (bank 18)   led_n[2] = V4 on V19 (bank 14)
#   led_n[1] = V1 on A12 (bank 18)   led_n[3] = V5 on W19 (bank 14, the
#                                              seller's test-design LED)
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33} [get_ports {led_n[0]}]
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS33} [get_ports {led_n[1]}]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33} [get_ports {led_n[2]}]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports {led_n[3]}]
set_false_path -to [get_ports {led_n[*]}]

# ---------------------------------------------------------------------------
# UART to an external 3.3 V USB-serial adapter on header J10 (fixed 3.3 V
# banks 14/15, NOT the adjustable-VDDIO bank 16 on J10 pins 5-36):
#   J10 pin 37 = J29 = uart_rx  <- adapter TXD
#   J10 pin 38 = J28 = uart_tx  -> adapter RXD
#   J10 pin 1/4/65/66 = GND     -- adapter GND
# uart_if double-flops rx internally, so both ends are async to clk.
# ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN J29 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports uart_rx]
set_property -dict {PACKAGE_PIN J28 IOSTANDARD LVCMOS33}             [get_ports uart_tx]
set_false_path -from [get_ports uart_rx]
set_false_path -to   [get_ports uart_tx]
