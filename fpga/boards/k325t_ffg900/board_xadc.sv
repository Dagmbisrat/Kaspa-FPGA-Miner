// board_xadc: on-die temp/voltage sensors, raw codes (12-bit in [15:4]).
//   temp C = code12*503.975/4096 - 273.15, volts = code12/4096*3
module board_xadc #(
    parameter int DCLK_HZ = 100_000_000
) (
    input  logic        clk,        // DRP clock
    input  logic        rst,

    output logic [15:0] temp,
    output logic [15:0] temp_max,
    output logic [15:0] temp_min,
    output logic [15:0] vccint,
    output logic [15:0] vccaux,
    output logic [15:0] vccbram
);

    // ADCCLK <= 26 MHz
    localparam int          CD      = (DCLK_HZ + 26_000_000 - 1) / 26_000_000;
    localparam logic [15:0] INIT_42 = 16'(CD < 2 ? 2 : CD) << 8;

    logic [6:0]  daddr;
    logic        den, drdy;
    logic [15:0] dout;

    XADC #(
        .INIT_40(16'h0000),   // no averaging, default settling
        .INIT_41(16'h2FFF),   // continuous sequence; alarms/OT off; calibration on
        .INIT_42(INIT_42),    // ADCCLK divider
        .INIT_48(16'h4701),   // sequence: calibration, temp, VCCINT, VCCAUX, VCCBRAM
        .INIT_49(16'h0000)    // no external aux channels
    ) u_xadc (
        .DCLK        (clk),
        .RESET       (rst),
        .DADDR       (daddr),
        .DEN         (den),
        .DWE         (1'b0),
        .DI          (16'h0000),
        .DO          (dout),
        .DRDY        (drdy),
        .VP          (1'b0),
        .VN          (1'b0),
        .VAUXP       (16'h0000),
        .VAUXN       (16'h0000),
        .CONVST      (1'b0),
        .CONVSTCLK   (1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .ALM         (),
        .OT          (),
        .BUSY        (),
        .CHANNEL     (),
        .EOC         (),
        .EOS         (),
        .JTAGBUSY    (),
        .JTAGLOCKED  (),
        .JTAGMODIFIED(),
        .MUXADDR     ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // Round-robin DRP reads
    localparam int N = 6;
    function automatic logic [6:0] reg_addr(input logic [2:0] i);
        case (i)
            3'd0:    return 7'h00;   // temperature
            3'd1:    return 7'h01;   // VCCINT
            3'd2:    return 7'h02;   // VCCAUX
            3'd3:    return 7'h06;   // VCCBRAM
            3'd4:    return 7'h20;   // max temperature
            default: return 7'h24;   // min temperature
        endcase
    endfunction

    logic [2:0] idx;
    logic       busy;

    assign daddr = reg_addr(idx);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            idx      <= '0;
            busy     <= 1'b0;
            den      <= 1'b0;
            temp     <= '0;
            temp_max <= '0;
            temp_min <= '0;
            vccint   <= '0;
            vccaux   <= '0;
            vccbram  <= '0;
        end else begin
            den <= 1'b0;
            if (!busy) begin
                den  <= 1'b1;
                busy <= 1'b1;
            end else if (drdy) begin
                case (idx)
                    3'd0:    temp     <= dout;
                    3'd1:    vccint   <= dout;
                    3'd2:    vccaux   <= dout;
                    3'd3:    vccbram  <= dout;
                    3'd4:    temp_max <= dout;
                    default: temp_min <= dout;
                endcase
                idx  <= (idx == 3'(N - 1)) ? '0 : idx + 1'b1;
                busy <= 1'b0;
            end
        end
    end

endmodule
