// board_clk_rst: 50 MHz -> MMCM (1000 MHz VCO / CLK_DIV) -> clk; sync reset.
module board_clk_rst #(
    parameter int CLK_DIV = 10   // 100 MHz
) (
    input  logic clk_50m,
    input  logic rst_n,

    output logic clk,
    output logic rst
);

    logic clkfb, clk_mmcm, locked;

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

    // Reset while K2 pressed or MMCM unlocked.
    logic       arst_n;
    logic [3:0] rst_sync;

    assign arst_n = rst_n & locked;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) rst_sync <= '1;
        else         rst_sync <= {rst_sync[2:0], 1'b0};
    end
    assign rst = rst_sync[3];

endmodule
