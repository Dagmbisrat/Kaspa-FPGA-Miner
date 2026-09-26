// kaspa_miner_top -- board wrapper that puts kaspa_miner on the
// XC7K325T-FFG900 board. Only the board-specific bits live here:
//
//   50 MHz osc --> MMCM (VCO 1000 MHz / CLK_DIV) --> BUFG --> clk
//   rst_n (K2) & locked --> async-assert / sync-deassert --> rst
//
// Everything else is kaspa_miner as-is. CLK_FREQ_HZ is derived from
// CLK_DIV, so uart_if's baud divider always matches the real clock.
//
//   led_n[0] (V2) : ~1 Hz heartbeat once the MMCM locks and reset releases
//   led_n[1] (V1) : flickers on UART traffic in either direction
module kaspa_miner_top #(
    parameter int CLK_DIV       = 10,         // 1000 MHz VCO / 10 = 100 MHz
    parameter int CSHAKE_STAGES = 4,
    parameter int MATMUL_STAGES = 8,
    parameter bit CSHAKE_FOLDED = 1'b1,
    parameter int BAUD_RATE     = 115_200
) (
    input  logic       clk_50m,
    input  logic       rst_n,

    output logic [1:0] led_n,

    input  logic       uart_rx,
    output logic       uart_tx
);

    localparam int CLK_FREQ_HZ = 1_000_000_000 / CLK_DIV;

    // -----------------------------------------------------------------------
    // Clocking: 50 MHz x20 = 1000 MHz VCO (inside -1's 600-1200 MHz range)
    // -----------------------------------------------------------------------
    logic clkfb, clk_mmcm, clk, locked;

    // clk_50m is on an MRCC pin (D12), which routes straight to its bank's
    // MMCM - no input BUFG needed.
    MMCME2_BASE #(
        .CLKIN1_PERIOD   (20.0),
        .DIVCLK_DIVIDE   (1),
        .CLKFBOUT_MULT_F (20.0),
        .CLKOUT0_DIVIDE_F(CLK_DIV)
    ) u_mmcm (
        .CLKIN1   (clk_50m),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk_mmcm),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(),
        .CLKOUT2B (), .CLKOUT3(),  .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(),
        .CLKOUT6  ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    BUFG u_bufg_out (.I(clk_mmcm), .O(clk));

    // -----------------------------------------------------------------------
    // Reset: held while K2 is pressed or the MMCM is unlocked; released
    // synchronously so every flop in kaspa_miner leaves reset on the same edge.
    // -----------------------------------------------------------------------
    logic       arst_n;
    logic [3:0] rst_sync;
    logic       rst;

    assign arst_n = rst_n & locked;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) rst_sync <= '1;
        else         rst_sync <= {rst_sync[2:0], 1'b0};
    end
    assign rst = rst_sync[3];

    // -----------------------------------------------------------------------
    // Miner
    // -----------------------------------------------------------------------
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

    // -----------------------------------------------------------------------
    // Status LEDs
    // -----------------------------------------------------------------------
    localparam int HB_BITS  = $clog2(CLK_FREQ_HZ / 2);  // ~1 Hz blink period
    localparam int ACT_BITS = $clog2(CLK_FREQ_HZ / 20); // ~50 ms activity stretch

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
            // Either line going low (a start bit / data 0) restarts the stretch.
            if (!rx_meta[1] || !uart_tx) act_cnt <= '1;
            else if (act_cnt != '0)      act_cnt <= act_cnt - 1'b1;
        end
    end

    assign led_n[0] = ~hb_cnt[HB_BITS-1];
    assign led_n[1] = (act_cnt == '0);

endmodule
