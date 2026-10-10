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
| `led_n[0]` | A11      | LED by J5 (SFP 1)      | active-low (pin -> 3.3k -> LED -> 3.3 V) |
| `led_n[1]` | A12      | LED by J6 (SFP 2)      | active-low |
| `led_n[2]` | V19      | LED by U1 (DDR3)       | active-low |
| `led_n[3]` | W19      | LED by U7 (DDR3)       | active-low, the seller's test-design LED |
| `uart_rx`  | J29      | header J10 pin 37      | wire to adapter **TXD** |
| `uart_tx`  | J28      | header J10 pin 38      | wire to adapter **RXD** |
| GND        | -        | J10 pin 1/4/65/66      | wire to adapter **GND** |
| `diag_tx`  | K29      | header J10 pin 40      | miner only: diagnostics stream -> Teensy **pin 7** (RX2) |

The LED mapping above is confirmed on hardware with blinky. On the board,
the LEDs are easiest to find by the part printed next to them.

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

From bash (including WSL with a Windows-only Vivado), `source board.sh` gives
a `board` shortcut for each command below; set `VIVADO_BIN` or `VIVADO_BAT`
first, as described in `fpga/vivado.sh`:
```sh
board build uart        # vivado -mode batch -source build.tcl   -tclargs uart
board program uart      # vivado -mode batch -source program.tcl -tclargs uart
board backup ~/k325t_flash_backup.bin
board help
```

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
   J5 about 3 Hz, J6 about 1.5 Hz, U1 about 0.75 Hz, U7 about 0.37 Hz. Holding K2 lights them
   all solid. With the USB-serial adapter wired up, typing in a serial terminal
   echoes back at any baud rate. Power-cycle to get the factory design back.
3. **UART test.** `uart_test_top` is the miner with the hashing core swapped
   for `fake_core`. It has the same clock, baud rate, `uart_if` and
   `work_controller` register map, so every command gets a real miner-style
   reply. For each job it reports two known finds: `nonce_base+42` and then
   `nonce_base+1337`, 10 ms apart, tagged with a work_id that goes up by
   one per job. It needs this folder inside a repo checkout, because it
   pulls in `hw/`:
   ```sh
   vivado -mode batch -source build.tcl   -tclargs uart
   vivado -mode batch -source program.tcl -tclargs uart
   ```
   Then talk to it with the `uart` CLI in this folder
   (`pip install pyserial` first). Every command prints the bytes sent
   (`>>`) and received (`<<`), then the decoded reply:
   ```sh
   export UART_PORT=COM5          # Windows cmd: set UART_PORT=COM5 (./uart ports lists them)
   ./uart selftest                # full check, ends with ALL PASSED
   ./uart read STATUS             # read one register (./uart regs lists them)
   ./uart write NONCE0 0x1000     # write one register, prints the ack
   ./uart job --nonce 0x100       # load a job (all 20 words) and start it
   ./uart found --all             # pop found nonces: 0x12a, then 0x639
   ./uart status                  # STATUS + FOUND_COUNT
   ./uart dump                    # every readable register
   ./uart badchk                  # bad checksum, expect a NACK
   ./uart raw aa 00 04 00 00 00 00 04   # hand-built frame
   ./uart diag                    # FPGA temp, VCCINT/VCCAUX/VCCBRAM, uptime, counters
   ./uart monitor                 # the same, as a live log once a second (Ctrl-C stops)
   ```
   `diag` and `monitor` read a diagnostics block at 0x80+ that exists only
   in this debug bitstream. It uses the chip's built-in XADC sensor, so no
   extra hardware is needed. `monitor` also measures the real clock
   (expect ~100 MHz).
   On Windows, run it as `python uart <cmd>`. All commands except
   `selftest` work unchanged on the real miner bitstream. If you get no
   reply at all, TX and RX are usually swapped, or the port or baud rate is
   wrong.
4. **Miner over JTAG** (defaults: 100 MHz, folded cSHAKE, 4 cSHAKE / 8
   matmul stages, 115200 baud). Change any of these with `KEY=VALUE`, and
   each combination builds into its own folder, e.g. `build/miner_CLK_DIV12/`:
   ```sh
   vivado -mode batch -source build.tcl   -tclargs miner CLK_DIV=12 CSHAKE_STAGES=6 MATMUL_STAGES=16
   vivado -mode batch -source program.tcl -tclargs miner_CLK_DIV12_CSHAKE_STAGES6_MATMUL_STAGES16
   ```
   `CSHAKE_STAGES` must divide 24, `MATMUL_STAGES` must divide 64, and
   `CSHAKE_FOLDED=0` (unfolded) probably won't fit the 325T. Clock =
   1000 MHz / `CLK_DIV`. Each folder's `build_info.txt` records the
   parameters, timing and utilization. With default settings:
   ```sh
   vivado -mode batch -source build.tcl   -tclargs miner
   vivado -mode batch -source program.tcl -tclargs miner
   ```
   The LEDs by J5 and U7 blink as a heartbeat, and the ones by J6 and U1
   flicker on UART traffic.

   The miner also has a **second, transmit-only UART** on J10 pin 40
   (FPGA K29). Once a second it sends one line of FPGA temperature, supply
   voltages and uptime, from the on-die XADC:
   ```
   up 0003602s  temp 048.3C (max 051.0C)  VCCINT 1.002V  VCCAUX 1.798V  VCCBRAM 1.001V
   ```
   Wire J10 pin 40 to Teensy pin 7, flash the Teensy bridge in Dual Serial
   mode (`fpga/teensy/flash.sh` does this), and read the second USB port:
   ```sh
   ./uart ports                              # two Teensy ports now
   ./uart --port <second port> listen        # live diagnostics, Ctrl-C to stop
   ```
   It never touches the command UART, so `./uart job/found/...` keep working
   on the first port at the same time. The build
   prints post-route WNS. If it's negative, rebuild with a slower clock,
   for example `-tclargs miner 12` for 83 MHz.
5. **Make it permanent** (overwrites the factory design, so do step 1 first):
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

## Programming from another PC

Building needs a licensed Vivado. Programming doesn't: the free **Vivado Lab
Edition** is enough on the PC the JTAG cable is plugged into. You have two
options.

**A. Copy the files over (simplest).** Copy `build/<target>/*.bit`/`*.mcs`
and this folder's `.tcl` files to the board PC, and run `program.tcl` there
with Lab Edition.

**B. Remote hw_server.** On the board PC, run Xilinx's `hw_server` (it comes
with Lab Edition). It listens on TCP **3121**:
```sh
hw_server                                   # Linux: <install>/bin/hw_server
C:\Xilinx\Vivado_Lab\<ver>\bin\hw_server.bat  # Windows
```
Allow the port through the firewall (Windows, admin shell):
```
netsh advfirewall firewall add rule name="Xilinx hw_server" dir=in action=allow protocol=TCP localport=3121
```
Then, on the Vivado PC:
```sh
HW_SERVER=<board-pc-ip>:3121 vivado -mode batch -source program.tcl -tclargs blinky
```
In the GUI, use Open Target -> Open New Target -> Remote server instead.

hw_server has **no authentication**, so only expose it on a trusted LAN.
If the Vivado PC is somewhere else (for example a university lab machine),
don't open the port to the internet. Tunnel it over SSH from the board PC
instead:
```sh
ssh -R 3121:localhost:3121 you@lab-machine   # then HW_SERVER=localhost:3121 there
```
Keep hw_server on the same Vivado version as the machine connecting to it.
Mismatched versions often refuse to connect.
