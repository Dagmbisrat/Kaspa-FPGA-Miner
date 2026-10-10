// kaspa_miner_top: kaspa_miner on this board. diag_tx = 1 Hz temp/voltage text.
module kaspa_miner_top #(
    parameter int CLK_DIV       = 10,         // 100 MHz
    parameter int CSHAKE_STAGES = 4,
    parameter int MATMUL_STAGES = 8,
    parameter bit CSHAKE_FOLDED = 1'b1,
    parameter int BAUD_RATE     = 115_200
) (
    input  logic       clk_50m,
    input  logic       rst_n,

    output logic [3:0] led_n,

    input  logic       uart_rx,
    output logic       uart_tx,

    output logic       diag_tx
);

    localparam int CLK_FREQ_HZ = 1_000_000_000 / CLK_DIV;

    logic clk, rst;

    board_clk_rst #(.CLK_DIV(CLK_DIV)) u_clk_rst (
        .clk_50m(clk_50m),
        .rst_n  (rst_n),
        .clk    (clk),
        .rst    (rst)
    );

    kaspa_miner #(
        .CSHAKE_STAGES(CSHAKE_STAGES),
        .MATMUL_STAGES(MATMUL_STAGES),
        .CSHAKE_FOLDED(CSHAKE_FOLDED),
        .CLK_FREQ_HZ  (CLK_FREQ_HZ),
        .BAUD_RATE    (BAUD_RATE)
    ) u_miner (
        .clk(clk),
        .rst(rst),
        .rx (uart_rx),
        .tx (uart_tx)
    );

    logic [15:0] x_temp, x_temp_max, x_vccint, x_vccaux, x_vccbram;

    board_xadc #(.DCLK_HZ(CLK_FREQ_HZ)) u_xadc (
        .clk     (clk),
        .rst     (rst),
        .temp    (x_temp),
        .temp_max(x_temp_max),
        /* verilator lint_off PINCONNECTEMPTY */
        .temp_min(),
        /* verilator lint_on PINCONNECTEMPTY */
        .vccint  (x_vccint),
        .vccaux  (x_vccaux),
        .vccbram (x_vccbram)
    );

    board_diag_uart #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_diag (
        .clk     (clk),
        .rst     (rst),
        .temp    (x_temp),
        .temp_max(x_temp_max),
        .vccint  (x_vccint),
        .vccaux  (x_vccaux),
        .vccbram (x_vccbram),
        .tx      (diag_tx)
    );

    board_status_leds #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_leds (
        .clk    (clk),
        .rst    (rst),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .led_n  (led_n)
    );

endmodule
