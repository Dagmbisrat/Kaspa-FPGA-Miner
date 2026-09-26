// blinky_top -- first bring-up bitstream for the XC7K325T-FFG900 board.
// No miner logic: just proves the toolchain, the pinout, and JTAG
// programming all work before anything bigger goes on.
//
//   led_n[0] (V2) : blinks at ~1 Hz off the 50 MHz oscillator -> clock,
//                   pinout, and programming are all good
//   led_n[1] (V1) : lights while button K2 is held -> input pin works
//   uart_tx       : echoes uart_rx straight back -> type in a serial
//                   terminal and see it echoed to check adapter wiring
//                   before the miner needs it (any baud rate works)
module blinky_top (
    input  logic       clk_50m,
    input  logic       rst_n,

    output logic [1:0] led_n,

    input  logic       uart_rx,
    output logic       uart_tx
);

    // 2^25 / 50 MHz = 0.67 s per half period, ~0.75 Hz blink. No reset:
    // the bitstream's power-up INIT values are enough for a free-running
    // counter, and it keeps rst_n free to drive the LED directly.
    /* verilator lint_off PROCASSINIT */
    logic [24:0] div_cnt = '0;
    logic        blink   = 1'b0;
    /* verilator lint_on PROCASSINIT */

    always_ff @(posedge clk_50m) begin
        div_cnt <= div_cnt + 1'b1;
        if (div_cnt == '1) blink <= ~blink;
    end

    assign led_n[0] = ~blink;
    assign led_n[1] = rst_n;    // pressed = 0 = LED on (both active-low)
    assign uart_tx  = uart_rx;

endmodule
