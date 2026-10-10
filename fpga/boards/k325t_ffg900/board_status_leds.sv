// board_status_leds: A11/W19 = 1 Hz heartbeat, A12/V19 = UART activity.
module board_status_leds #(
    parameter int CLK_FREQ_HZ = 100_000_000
) (
    input  logic       clk,
    input  logic       rst,

    input  logic       uart_rx,   // async
    input  logic       uart_tx,

    output logic [3:0] led_n
);

    localparam int HB_BITS  = $clog2(CLK_FREQ_HZ / 2);  // ~1 Hz
    localparam int ACT_BITS = $clog2(CLK_FREQ_HZ / 20); // ~50 ms

    logic [HB_BITS-1:0]  hb_cnt;
    logic [ACT_BITS-1:0] act_cnt;
    logic [1:0]          rx_meta;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            hb_cnt  <= '0;
            act_cnt <= '0;
            rx_meta <= 2'b11;
        end else begin
            hb_cnt  <= hb_cnt + 1'b1;
            rx_meta <= {rx_meta[0], uart_rx};
            if (!rx_meta[1] || !uart_tx) act_cnt <= '1;
            else if (act_cnt != '0)      act_cnt <= act_cnt - 1'b1;
        end
    end

    logic hb_on, act_on;
    assign hb_on  = hb_cnt[HB_BITS-1];
    assign act_on = (act_cnt != '0);
    assign led_n  = ~{hb_on, act_on, act_on, hb_on};  // {W19, V19, A12, A11}

endmodule
