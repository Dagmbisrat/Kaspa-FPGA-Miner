// UART transport adapter -- implements the wire protocol in
// docs/io/uart_if.md: fixed 8-byte frames (SOF, CMD, ADDR, D0..D3, CHK)
// in both directions, one 32-bit register access per frame.
//
//   byte:  0     1     2     3   4   5   6     7
//         SOF   CMD   ADDR  D0  D1  D2  D3   CHK
//   CMD bit7=DIR(0=req,1=resp) bit1=NACK bit0=OP(0=read,1=write)
//   CHK = CMD^ADDR^D0^D1^D2^D3
module uart_if #(
    parameter int CLK_FREQ_HZ = 200_000_000,
    parameter int BAUD_RATE   = 3_000_000
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        rx,
    output logic        tx,

    output logic [7:0]  addr,
    output logic [31:0] wdata,
    output logic        we,
    output logic        re,
    input  logic [31:0] rdata   // valid the cycle after `re` pulses
);

    // 16x-oversample tick shared by RX and TX. Integer division: pick
    // CLK_FREQ_HZ/BAUD_RATE ratios that divide evenly to avoid baud drift.
    localparam int OVERSAMPLE = 16;
    localparam int TICK_DIV   = CLK_FREQ_HZ / (BAUD_RATE * OVERSAMPLE);
    localparam int TICK_BITS  = (TICK_DIV > 1) ? $clog2(TICK_DIV) : 1;

    logic [TICK_BITS-1:0] tick_cnt;
    logic                 baud_tick16;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            tick_cnt    <= '0;
            baud_tick16 <= 1'b0;
        end else if (tick_cnt == TICK_DIV-1) begin
            tick_cnt    <= '0;
            baud_tick16 <= 1'b1;
        end else begin
            tick_cnt    <= tick_cnt + 1'b1;
            baud_tick16 <= 1'b0;
        end
    end

    // 2-FF synchronizer: rx is async to clk.
    logic rx_meta, rx_line;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_meta <= 1'b1;
            rx_line <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_line <= rx_meta;
        end
    end

    typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_state_t;
    rx_state_t   rx_state;
    logic [3:0]  rx_os_cnt;
    logic [2:0]  rx_bit_idx;
    logic [7:0]  rx_shift;      // LSB-first: rx_shift[bit_idx] holds the final byte value
    logic [7:0]  rx_byte;
    logic        rx_byte_valid;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_state      <= RX_IDLE;
            rx_os_cnt     <= '0;
            rx_bit_idx    <= '0;
            rx_shift      <= '0;
            rx_byte       <= '0;
            rx_byte_valid <= 1'b0;
        end else begin
            rx_byte_valid <= 1'b0;
            case (rx_state)
                RX_IDLE: begin
                    if (!rx_line) begin
                        rx_os_cnt <= '0;
                        rx_state  <= RX_START;
                    end
                end

                RX_START: if (baud_tick16) begin
                    if (rx_os_cnt == OVERSAMPLE/2 - 1) begin
                        if (!rx_line) begin
                            rx_os_cnt  <= '0;
                            rx_bit_idx <= '0;
                            rx_state   <= RX_DATA;
                        end else begin
                            rx_state <= RX_IDLE;
                        end
                    end else begin
                        rx_os_cnt <= rx_os_cnt + 1'b1;
                    end
                end

                RX_DATA: if (baud_tick16) begin
                    if (rx_os_cnt == OVERSAMPLE-1) begin
                        rx_os_cnt            <= '0;
                        rx_shift[rx_bit_idx] <= rx_line;
                        if (rx_bit_idx == 3'd7) rx_state   <= RX_STOP;
                        else                     rx_bit_idx <= rx_bit_idx + 1'b1;
                    end else begin
                        rx_os_cnt <= rx_os_cnt + 1'b1;
                    end
                end

                RX_STOP: if (baud_tick16) begin
                    if (rx_os_cnt == OVERSAMPLE-1) begin
                        rx_os_cnt     <= '0;
                        rx_byte       <= rx_shift;
                        rx_byte_valid <= 1'b1;
                        rx_state      <= RX_IDLE;
                    end else begin
                        rx_os_cnt <= rx_os_cnt + 1'b1;
                    end
                end
            endcase
        end
    end

    logic [7:0] tx_byte_in;
    logic       tx_start;
    logic       tx_done;

    typedef enum logic {TX_IDLE, TX_BIT} tx_state_t;
    tx_state_t   tx_state;
    logic [9:0]  tx_frame;      // {stop, data[7:0], start} loaded once per byte
    logic [3:0]  tx_bit_idx;
    logic [3:0]  tx_os_cnt;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_state   <= TX_IDLE;
            tx         <= 1'b1;
            tx_done    <= 1'b0;
            tx_frame   <= '1;
            tx_bit_idx <= '0;
            tx_os_cnt  <= '0;
        end else begin
            tx_done <= 1'b0;
            case (tx_state)
                TX_IDLE: begin
                    tx <= 1'b1;
                    if (tx_start) begin
                        tx_frame   <= {1'b1, tx_byte_in, 1'b0};
                        tx         <= 1'b0;
                        tx_bit_idx <= 4'd0;
                        tx_os_cnt  <= '0;
                        tx_state   <= TX_BIT;
                    end
                end

                TX_BIT: if (baud_tick16) begin
                    if (tx_os_cnt == OVERSAMPLE-1) begin
                        tx_os_cnt <= '0;
                        if (tx_bit_idx == 4'd9) begin
                            tx      <= 1'b1;
                            tx_done <= 1'b1;
                            tx_state<= TX_IDLE;
                        end else begin
                            tx_bit_idx <= tx_bit_idx + 1'b1;
                            tx         <= tx_frame[tx_bit_idx + 1'b1];
                        end
                    end else begin
                        tx_os_cnt <= tx_os_cnt + 1'b1;
                    end
                end
            endcase
        end
    end

    localparam logic [7:0] SOF           = 8'hAA;
    localparam logic [7:0] CMD_READ_RESP = 8'h80;
    localparam logic [7:0] CMD_WRITE_ACK = 8'h81;
    localparam logic [7:0] CMD_NACK      = 8'h82;

    typedef enum logic [3:0] {
        F_WAIT_SOF, F_CMD, F_ADDR, F_D0, F_D1, F_D2, F_D3, F_CHK,
        F_WR, F_RD, F_RD_WAIT, F_SEND
    } frame_state_t;
    frame_state_t frame_state;

    logic [7:0]  cmd_reg, addr_reg, d0_reg, d1_reg, d2_reg, d3_reg;
    logic [31:0] data_reg;
    assign data_reg = {d3_reg, d2_reg, d1_reg, d0_reg};
    logic [7:0]  expected_chk;
    assign expected_chk = cmd_reg ^ addr_reg ^ d0_reg ^ d1_reg ^ d2_reg ^ d3_reg;

    logic [7:0]  resp_cmd, resp_addr;
    logic [31:0] resp_data;
    logic [7:0]  resp_chk;
    assign resp_chk = resp_cmd ^ resp_addr ^ resp_data[7:0] ^ resp_data[15:8]
                                ^ resp_data[23:16] ^ resp_data[31:24];

    logic [2:0] send_idx;
    logic [7:0] send_byte;
    always_comb begin
        unique case (send_idx)
            3'd0: send_byte = SOF;
            3'd1: send_byte = resp_cmd;
            3'd2: send_byte = resp_addr;
            3'd3: send_byte = resp_data[7:0];
            3'd4: send_byte = resp_data[15:8];
            3'd5: send_byte = resp_data[23:16];
            3'd6: send_byte = resp_data[31:24];
            default: send_byte = resp_chk;
        endcase
    end
    assign tx_byte_in = send_byte;

    assign addr  = addr_reg;
    assign wdata = data_reg;
    assign we    = (frame_state == F_WR);
    assign re    = (frame_state == F_RD);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            frame_state <= F_WAIT_SOF;
            cmd_reg  <= '0; addr_reg <= '0;
            d0_reg   <= '0; d1_reg   <= '0; d2_reg <= '0; d3_reg <= '0;
            resp_cmd <= '0; resp_addr <= '0; resp_data <= '0;
            send_idx <= '0;
            tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            case (frame_state)
                F_WAIT_SOF: if (rx_byte_valid && rx_byte == SOF) frame_state <= F_CMD;

                F_CMD:  if (rx_byte_valid) begin cmd_reg  <= rx_byte; frame_state <= F_ADDR; end
                F_ADDR: if (rx_byte_valid) begin addr_reg <= rx_byte; frame_state <= F_D0;   end
                F_D0:   if (rx_byte_valid) begin d0_reg   <= rx_byte; frame_state <= F_D1;   end
                F_D1:   if (rx_byte_valid) begin d1_reg   <= rx_byte; frame_state <= F_D2;   end
                F_D2:   if (rx_byte_valid) begin d2_reg   <= rx_byte; frame_state <= F_D3;   end
                F_D3:   if (rx_byte_valid) begin d3_reg   <= rx_byte; frame_state <= F_CHK;  end

                F_CHK: if (rx_byte_valid) begin
                    if (rx_byte == expected_chk) begin
                        frame_state <= cmd_reg[0] ? F_WR : F_RD;
                    end else begin
                        resp_cmd  <= CMD_NACK;
                        resp_addr <= addr_reg;
                        resp_data <= 32'b0;
                        send_idx  <= '0;
                        tx_start  <= 1'b1;
                        frame_state <= F_SEND;
                    end
                end

                F_WR: begin
                    resp_cmd  <= CMD_WRITE_ACK;
                    resp_addr <= addr_reg;
                    resp_data <= data_reg;
                    send_idx  <= '0;
                    tx_start  <= 1'b1;
                    frame_state <= F_SEND;
                end

                // re pulsed during F_RD; rdata sampled here once work_controller
                // has decoded addr (and, for FOUND_NONCE, popped its FIFO).
                F_RD: frame_state <= F_RD_WAIT;

                F_RD_WAIT: begin
                    resp_cmd  <= CMD_READ_RESP;
                    resp_addr <= addr_reg;
                    resp_data <= rdata;
                    send_idx  <= '0;
                    tx_start  <= 1'b1;
                    frame_state <= F_SEND;
                end

                F_SEND: if (tx_done) begin
                    if (send_idx == 3'd7) begin
                        frame_state <= F_WAIT_SOF;
                    end else begin
                        send_idx <= send_idx + 1'b1;
                        tx_start <= 1'b1;
                    end
                end

                default: frame_state <= F_WAIT_SOF;
            endcase
        end
    end

endmodule
