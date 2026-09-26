// blinky_top -- first bring-up bitstream for the XC7K325T-FFG900 board.
// No miner logic: just proves the toolchain, the pinout, and JTAG
// programming all work before anything bigger goes on.
//
//   led_n[3:0]  : a 4-bit binary counter, so each LED blinks at its own
//                 rate and you can tell which physical LED is on which pin
//                 (the board's silkscreen doesn't match the schematic):
//                   A11 (sch. V2) ~3 Hz   fastest
//                   A12 (sch. V1) ~1.5 Hz
//                   V19 (sch. V4) ~0.75 Hz
//                   W19 (sch. V5) ~0.37 Hz slowest
//   hold K2     : every LED lights solid -> the button input works
//   uart_tx     : echoes uart_rx straight back -> type in a serial
//                 terminal and see it echoed to check adapter wiring
//                 before the miner needs it (any baud rate works)
module blinky_top (
    input  logic       clk_50m,
    input  logic       rst_n,

    output logic [3:0] led_n,

    input  logic       uart_rx,
    output logic       uart_tx
);

    // Top 4 bits of a 27-bit counter at 50 MHz: bit 23 toggles every
    // 2^23 / 50 MHz = 0.17 s (~3 Hz blink), each bit above it half as fast.
    // No reset: the bitstream's power-up INIT value is enough for a
    // free-running counter, and it keeps rst_n free to drive the LEDs.
    /* verilator lint_off PROCASSINIT */
    logic [26:0] cnt = '0;
    /* verilator lint_on PROCASSINIT */

    always_ff @(posedge clk_50m) cnt <= cnt + 1'b1;

    // Active-low LEDs; K2 pressed (rst_n=0) forces them all on.
    assign led_n   = rst_n ? ~cnt[26:23] : 4'b0000;
    assign uart_tx = uart_rx;

endmodule
