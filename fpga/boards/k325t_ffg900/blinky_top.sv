// blinky_top: bring-up test. LEDs count, K2 lights all, UART echoes rx->tx.
module blinky_top (
    input  logic       clk_50m,
    input  logic       rst_n,

    output logic [3:0] led_n,

    input  logic       uart_rx,
    output logic       uart_tx
);

    /* verilator lint_off PROCASSINIT */
    logic [26:0] cnt = '0;
    /* verilator lint_on PROCASSINIT */

    always_ff @(posedge clk_50m) cnt <= cnt + 1'b1;

    // Active-low LEDs; K2 pressed forces all on.
    assign led_n   = rst_n ? ~cnt[26:23] : 4'b0000;
    assign uart_tx = uart_rx;

endmodule
