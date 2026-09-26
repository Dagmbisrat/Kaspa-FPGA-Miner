# XC7K325T-FFG900 PCIe core board

Board support for the unbranded Alibaba "XC7K325T-900 PCIe" board
(**XC7K325T-1FFG900C**, Vivado part `xc7k325tffg900-1`). Pins below come
from the seller's schematic (`XC7K325T-FFG900.pdf`) and cross-check against
their test project's `PCIe.xdc`.

## Pinout used

| Signal     | FPGA pin | Board                  | Notes |
|------------|----------|------------------------|-------|
| `clk_50m`  | D12      | Y1 osc -> GCLK2        | 50 MHz, single-ended LVCMOS33 (MRCC) |
| `rst_n`    | A15      | button K2              | 10k pull-up, **0 while pressed** |
| `led_n[0]` | A11      | LED V2 (schematic)     | active-low (pin -> 3.3k -> LED -> 3.3 V) |
| `led_n[1]` | A12      | LED V1 (schematic)     | active-low |
| `led_n[2]` | V19      | LED V4 (schematic)     | active-low |
| `led_n[3]` | W19      | LED V5 (schematic)     | active-low, the seller's test-design LED |
| `uart_rx`  | J29      | header J10 pin 37      | wire to adapter **TXD** |
| `uart_tx`  | J28      | header J10 pin 38      | wire to adapter **RXD** |
| GND        | -        | J10 pin 1/4/65/66      | wire to adapter **GND** |

The LED designators are the schematic's. At least one board's silkscreen
differs (it shows V1 and V7), so run blinky to see which physical LED is on
which pin.

Other useful facts:
- **K1 is PROGRAM_B.** Pressing it reloads the FPGA from flash, the same as
  a power cycle.
- Boot mode is strapped to Master SPI (M[2:0]=001) from an N25Q128
  (128 Mbit, 16 MB) flash.
- J10 pins 37-64 are banks 14/15 at a **fixed 3.3 V**. J10 pins 5-36 are
  bank 16 on the adjustable `VDDIO` rail, which is best avoided for the
  UART unless you've checked its voltage.
- There is no on-board USB-UART. Use a 3.3 V USB-serial adapter such as an
  FT232R, CP2102N or CH340. The TX/RX lines must be 3.3 V, never 5 V.

## Bring-up, in order

Run each command on the machine with Vivado. The build can run anywhere,
but programming needs the JTAG cable plugged into that machine. Run them
from this folder.

1. **Back up the factory flash** (read-only, safe):
   ```sh
   vivado -mode batch -source backup_flash.tcl -tclargs ~/k325t_flash_backup.bin
   ```
2. **Blinky test.** This proves the tools, pinout and JTAG all work:
   ```sh
   vivado -mode batch -source build.tcl   -tclargs blinky
   vivado -mode batch -source program.tcl -tclargs blinky
   ```
   The four LED pins count in binary, so each LED blinks at its own rate:
   A11 about 3 Hz, A12 about 1.5 Hz, V19 about 0.75 Hz, W19 about 0.37 Hz.
   Note which physical LED blinks at which speed. Holding K2 lights them
   all solid. With the USB-serial adapter wired up, typing in a serial terminal
   echoes back at any baud rate. Power-cycle to get the factory design back.
3. **Miner over JTAG** (100 MHz, folded cSHAKE, 115200 baud):
   ```sh
   vivado -mode batch -source build.tcl   -tclargs miner
   vivado -mode batch -source program.tcl -tclargs miner
   ```
   The LEDs on A11 and W19 blink as a heartbeat, and the ones on A12 and
   V19 flicker on UART traffic. The build
   prints post-route WNS. If it's negative, rebuild with a slower clock,
   for example `-tclargs miner 12` for 83 MHz.
4. **Make it permanent** (overwrites the factory design, so do step 1 first):
   ```sh
   vivado -mode batch -source program.tcl -tclargs miner flash
   ```

Outputs land in `build/<blinky|miner>/`, which is gitignored.

## Clock / baud

`kaspa_miner_top` multiplies the 50 MHz oscillator up to a 1000 MHz VCO
and divides it by `CLK_DIV` (10 = 100 MHz). `CLK_FREQ_HZ` is derived from
that, so the UART divider always matches the real clock. `uart_if` rounds
`CLK_FREQ_HZ / (16 * BAUD_RATE)` down, so keep that ratio close to a whole
number. 115200 at 100 MHz gives 54.25, only 0.46% off. 921600 or 1M at
100 MHz is 5-13% off and won't work reliably.
