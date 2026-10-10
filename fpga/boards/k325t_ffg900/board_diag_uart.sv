// board_diag_uart: TX-only, one line per second, e.g.
//   up 0003602s  temp 048.3C (max 051.0C)  VCCINT 1.002V  VCCAUX 1.798V  VCCBRAM 1.001V
// Tables below are generated from that line; each '0' is a digit slot.
module board_diag_uart #(
    parameter int CLK_FREQ_HZ = 100_000_000,
    parameter int BAUD_RATE   = 115_200
) (
    input  logic        clk,
    input  logic        rst,

    input  logic [15:0] temp,       // raw XADC codes
    input  logic [15:0] temp_max,
    input  logic [15:0] vccint,
    input  logic [15:0] vccaux,
    input  logic [15:0] vccbram,

    output logic        tx
);

    localparam int MSG_LEN  = 85;
    localparam int N_DIGITS = 27;
    localparam int N_FIELDS = 6;
    localparam int BIT_CLKS = (CLK_FREQ_HZ + BAUD_RATE/2) / BAUD_RATE;
    localparam int SEC_BITS = $clog2(CLK_FREQ_HZ);

    // Template characters
    function automatic logic [7:0] tmpl(input logic [6:0] i);
        case (i)
              0: return 8'h75;  // u
              1: return 8'h70;  // p
              2: return 8'h20;  //  
             10: return 8'h73;  // s
             11: return 8'h20;  //  
             12: return 8'h20;  //  
             13: return 8'h74;  // t
             14: return 8'h65;  // e
             15: return 8'h6D;  // m
             16: return 8'h70;  // p
             17: return 8'h20;  //  
             21: return 8'h2E;  // .
             23: return 8'h43;  // C
             24: return 8'h20;  //  
             25: return 8'h28;  // (
             26: return 8'h6D;  // m
             27: return 8'h61;  // a
             28: return 8'h78;  // x
             29: return 8'h20;  //  
             33: return 8'h2E;  // .
             35: return 8'h43;  // C
             36: return 8'h29;  // )
             37: return 8'h20;  //  
             38: return 8'h20;  //  
             39: return 8'h56;  // V
             40: return 8'h43;  // C
             41: return 8'h43;  // C
             42: return 8'h49;  // I
             43: return 8'h4E;  // N
             44: return 8'h54;  // T
             45: return 8'h20;  //  
             47: return 8'h2E;  // .
             51: return 8'h56;  // V
             52: return 8'h20;  //  
             53: return 8'h20;  //  
             54: return 8'h56;  // V
             55: return 8'h43;  // C
             56: return 8'h43;  // C
             57: return 8'h41;  // A
             58: return 8'h55;  // U
             59: return 8'h58;  // X
             60: return 8'h20;  //  
             62: return 8'h2E;  // .
             66: return 8'h56;  // V
             67: return 8'h20;  //  
             68: return 8'h20;  //  
             69: return 8'h56;  // V
             70: return 8'h43;  // C
             71: return 8'h43;  // C
             72: return 8'h42;  // B
             73: return 8'h52;  // R
             74: return 8'h41;  // A
             75: return 8'h4D;  // M
             76: return 8'h20;  //  
             78: return 8'h2E;  // .
             82: return 8'h56;  // V
             83: return 8'h0D;  // \r
             84: return 8'h0A;  // \n
            default: return 8'h30;  // '0' digit slot
        endcase
    endfunction

    // Position -> digit index (31 = not a digit)
    function automatic logic [4:0] slot(input logic [6:0] i);
        case (i)
              3: return 5'd0;
              4: return 5'd1;
              5: return 5'd2;
              6: return 5'd3;
              7: return 5'd4;
              8: return 5'd5;
              9: return 5'd6;
             18: return 5'd7;
             19: return 5'd8;
             20: return 5'd9;
             22: return 5'd10;
             30: return 5'd11;
             31: return 5'd12;
             32: return 5'd13;
             34: return 5'd14;
             46: return 5'd15;
             48: return 5'd16;
             49: return 5'd17;
             50: return 5'd18;
             61: return 5'd19;
             63: return 5'd20;
             64: return 5'd21;
             65: return 5'd22;
             77: return 5'd23;
             79: return 5'd24;
             80: return 5'd25;
             81: return 5'd26;
            default: return 5'd31;
        endcase
    endfunction

    // Field start and width
    function automatic logic [4:0] fbase(input logic [2:0] f);
        case (f)
            3'd0: return 5'd0;
            3'd1: return 5'd7;
            3'd2: return 5'd11;
            3'd3: return 5'd15;
            3'd4: return 5'd19;
            3'd5: return 5'd23;
            default: return 5'd0;
        endcase
    endfunction
    function automatic logic [3:0] fwidth(input logic [2:0] f);
        case (f)
            3'd0: return 4'd7;
            3'd1: return 4'd4;
            3'd2: return 4'd4;
            3'd3: return 4'd4;
            3'd4: return 4'd4;
            3'd5: return 4'd4;
            default: return 4'd1;
        endcase
    endfunction

    // XADC code -> tenths of C / millivolts
    /* verilator lint_off UNUSEDSIGNAL */  // raw[3:0]: below the XADC's 12-bit result
    function automatic logic [31:0] temp_tenths(input logic [15:0] raw);
        logic [31:0] t;
        t = (32'(raw[15:4]) * 32'd80636 + 32'd32768) >> 16;
        return (t > 32'd2732) ? t - 32'd2732 : 32'd0;     // clamp below 0 C
    endfunction
    function automatic logic [31:0] millivolts(input logic [15:0] raw);
        return (32'(raw[15:4]) * 32'd750 + 32'd512) >> 10;
    endfunction

    /* verilator lint_on UNUSEDSIGNAL */

    // 1 s tick + uptime
    logic [SEC_BITS-1:0] sec_cnt;
    logic [31:0]         uptime;
    logic                tick;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            sec_cnt <= '0;
            uptime  <= '0;
            tick    <= 1'b0;
        end else begin
            tick <= 1'b0;
            if (sec_cnt == SEC_BITS'(CLK_FREQ_HZ - 1)) begin
                sec_cnt <= '0;
                uptime  <= uptime + 1'b1;
                tick    <= 1'b1;
            end else begin
                sec_cnt <= sec_cnt + 1'b1;
            end
        end
    end

    // Snapshot -> decimal digits -> send
    typedef enum logic [1:0] {S_IDLE, S_CONV, S_SEND} state_t;
    state_t state;

    logic [31:0] field [N_FIELDS];
    logic [3:0]  digits [N_DIGITS];
    logic [2:0]  f;           // field being converted
    logic [3:0]  k;           // digits done in this field
    logic [31:0] val;         // remaining value of this field

    logic [6:0]  byte_idx;
    logic [3:0]  bit_idx;     // 0 start, 1-8 data, 9 stop
    logic [$clog2(BIT_CLKS)-1:0] baud_cnt;
    logic [7:0]  cur_byte;
    logic [4:0]  cur_slot;

    assign cur_slot = slot(byte_idx);
    assign cur_byte = (cur_slot != 5'd31) ? 8'h30 + 8'(digits[cur_slot]) : tmpl(byte_idx);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state    <= S_IDLE;
            f        <= '0;
            k        <= '0;
            val      <= '0;
            byte_idx <= '0;
            bit_idx  <= '0;
            baud_cnt <= '0;
            tx       <= 1'b1;
            for (int i = 0; i < N_FIELDS; i++) field[i]  <= '0;
            for (int i = 0; i < N_DIGITS; i++) digits[i] <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx <= 1'b1;
                    if (tick) begin
                        field[0] <= uptime;
                        field[1] <= temp_tenths(temp);
                        field[2] <= temp_tenths(temp_max);
                        field[3] <= millivolts(vccint);
                        field[4] <= millivolts(vccaux);
                        field[5] <= millivolts(vccbram);
                        val      <= uptime;
                        f        <= '0;
                        k        <= '0;
                        state    <= S_CONV;
                    end
                end

                S_CONV: begin
                    digits[fbase(f) + 5'(fwidth(f)) - 5'd1 - 5'(k)] <= 4'(val % 32'd10);
                    if (k == fwidth(f) - 4'd1) begin
                        if (f == 3'(N_FIELDS - 1)) begin
                            byte_idx <= '0;
                            bit_idx  <= '0;
                            baud_cnt <= '0;
                            state    <= S_SEND;
                        end else begin
                            f   <= f + 1'b1;
                            k   <= '0;
                            val <= field[f + 1'b1];
                        end
                    end else begin
                        k   <= k + 1'b1;
                        val <= val / 32'd10;
                    end
                end

                S_SEND: begin
                    case (bit_idx)
                        4'd0:    tx <= 1'b0;                          // start
                        4'd9:    tx <= 1'b1;                          // stop
                        default: tx <= cur_byte[3'(bit_idx - 4'd1)];  // data, LSB first
                    endcase
                    if (baud_cnt == $bits(baud_cnt)'(BIT_CLKS - 1)) begin
                        baud_cnt <= '0;
                        if (bit_idx == 4'd9) begin
                            bit_idx <= '0;
                            if (byte_idx == 7'(MSG_LEN - 1)) state    <= S_IDLE;
                            else                             byte_idx <= byte_idx + 1'b1;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
