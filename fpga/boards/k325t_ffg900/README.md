# XC7K325T-FFG900 board

Build and program scripts for the "XC7K325T-900 PCIe" core board
(`xc7k325tffg900-1`). Set `VIVADO_BIN` or `VIVADO_BAT` (see `../../vivado.sh`),
then from this folder:

```sh
source board.sh
board build  <blinky|uart|miner> [KEY=VALUE ...]
board program <target|build dir> [flash]
board backup  [OUT_FILE]           # save the factory flash first
board help                         # all options
```

## Targets

- **blinky**: the LEDs count in binary. Checks the tools, pins and JTAG.
- **uart**: the miner's UART and register map with a fake core. Check it with `./uart selftest`.
- **miner**: the real miner. Defaults: 55.56 MHz (`CLK_DIV=18`), folded
  cSHAKE with 4 stages, 32 matmul stages, 115200 baud. This config meets timing
  and runs at ~6.5 MH/s. Check it with `./uart verify`.

The miner design is congested, so it needs `miner_floorplan.xdc` (loaded
automatically) and these directives:
```sh
PLACE_DIRECTIVE=AltSpreadLogic_high ROUTE_DIRECTIVE=AlternateCLBRouting board build miner
```

## Pins

| Signal    | FPGA | Board             |
|-----------|------|-------------------|
| `clk_50m` | D12  | 50 MHz oscillator |
| `rst_n`   | A15  | button K2 (reset) |
| `led_n`   | A11, A12, V19, W19 | LEDs by J5, J6, U1, U7 (active-low) |
| `uart_rx` | J29  | J10 pin 37 -> adapter TXD |
| `uart_tx` | J28  | J10 pin 38 -> adapter RXD |
| `diag_tx` | K29  | J10 pin 40 -> second adapter RXD (miner only) |

Use 3.3 V USB-serial adapters, with GND on J10 pin 1. K1 reloads the design
from flash.

`diag_tx` sends one line per second with temperature, voltages and uptime.
Read it with `./uart --port <port> listen`.
