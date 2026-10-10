// uart_test_top: miner host path with fake_core instead of hashing.
// Diag regs at 0x80+ (read by `uart diag`).
module uart_test_top #(
    parameter int CLK_DIV    = 10,        // 100 MHz
    parameter int BAUD_RATE  = 115_200,
    parameter int FIND_DELAY = 1_000_000  // cycles between fake finds
) (
    input  logic       clk_50m,
    input  logic       rst_n,

    output logic [3:0] led_n,

    input  logic       uart_rx,
    output logic       uart_tx
);

    localparam int CLK_FREQ_HZ = 1_000_000_000 / CLK_DIV;

    logic clk, rst;

    board_clk_rst #(.CLK_DIV(CLK_DIV)) u_clk_rst (
        .clk_50m(clk_50m),
        .rst_n  (rst_n),
        .clk    (clk),
        .rst    (rst)
    );

    logic [7:0]   reg_addr;
    logic [31:0]  reg_wdata;
    logic         reg_we;
    logic         reg_re;
    logic [31:0]  reg_rdata;
    logic [31:0]  wc_rdata;

    logic         job_start;
    logic [63:0]  job_nonce;
    logic         job_found;
    logic [63:0]  job_found_nonce;
    logic [7:0]   job_found_work_id;

    uart_if #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_uart_if (
        .clk  (clk),
        .rst  (rst),
        .rx   (uart_rx),
        .tx   (uart_tx),
        .addr (reg_addr),
        .wdata(reg_wdata),
        .we   (reg_we),
        .re   (reg_re),
        .rdata(reg_rdata)
    );

    work_controller u_work_controller (
        .clk (clk),
        .rst (rst),

        .addr (reg_addr),
        .wdata(reg_wdata),
        .we   (reg_we),
        .re   (reg_re),
        .rdata(wc_rdata),

        .start        (job_start),
        /* verilator lint_off PINCONNECTEMPTY */
        .pre_pow_hash (),
        .timestamp    (),
        .target       (),
        /* verilator lint_on PINCONNECTEMPTY */
        .nonce        (job_nonce),

        .found         (job_found),
        .found_nonce   (job_found_nonce),
        .found_work_id (job_found_work_id)
    );

    fake_core #(.FIND_DELAY(FIND_DELAY)) u_fake_core (
        .clk          (clk),
        .rst          (rst),
        .start        (job_start),
        .nonce        (job_nonce),
        .found        (job_found),
        .found_nonce  (job_found_nonce),
        .found_work_id(job_found_work_id)
    );

    // Diagnostics
    logic [15:0] x_temp, x_temp_max, x_temp_min, x_vccint, x_vccaux, x_vccbram;

    board_xadc #(.DCLK_HZ(CLK_FREQ_HZ)) u_xadc (
        .clk     (clk),
        .rst     (rst),
        .temp    (x_temp),
        .temp_max(x_temp_max),
        .temp_min(x_temp_min),
        .vccint  (x_vccint),
        .vccaux  (x_vccaux),
        .vccbram (x_vccbram)
    );

    localparam int SEC_BITS = $clog2(CLK_FREQ_HZ);

    logic [SEC_BITS-1:0] sec_cnt;
    logic [31:0] uptime, jobs, finds, requests, cycles;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            sec_cnt  <= '0;
            uptime   <= '0;
            jobs     <= '0;
            finds    <= '0;
            requests <= '0;
            cycles   <= '0;
        end else begin
            cycles <= cycles + 1'b1;
            if (sec_cnt == SEC_BITS'(CLK_FREQ_HZ - 1)) begin
                sec_cnt <= '0;
                uptime  <= uptime + 1'b1;
            end else begin
                sec_cnt <= sec_cnt + 1'b1;
            end
            if (job_start)       jobs     <= jobs + 1'b1;
            if (job_found)       finds    <= finds + 1'b1;
            if (reg_we || reg_re) requests <= requests + 1'b1;
        end
    end

    // Registered like work_controller: rdata is sampled the cycle after re.
    logic [31:0] diag_rdata;
    logic        diag_sel;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            diag_rdata <= '0;
            diag_sel   <= 1'b0;
        end else if (reg_re) begin
            diag_sel <= reg_addr[7];
            case (reg_addr)
                8'h80:   diag_rdata <= 32'h4449_4147;   // "DIAG"
                8'h84:   diag_rdata <= uptime;
                8'h88:   diag_rdata <= {16'b0, x_temp};
                8'h8C:   diag_rdata <= {16'b0, x_temp_max};
                8'h90:   diag_rdata <= {16'b0, x_temp_min};
                8'h94:   diag_rdata <= {16'b0, x_vccint};
                8'h9C:   diag_rdata <= {16'b0, x_vccaux};
                8'hA0:   diag_rdata <= {16'b0, x_vccbram};
                8'hA4:   diag_rdata <= jobs;
                8'hA8:   diag_rdata <= finds;
                8'hAC:   diag_rdata <= requests;
                8'hB0:   diag_rdata <= CLK_FREQ_HZ;
                8'hB4:   diag_rdata <= cycles;
                default: diag_rdata <= '0;
            endcase
        end
    end

    assign reg_rdata = diag_sel ? diag_rdata : wc_rdata;

    board_status_leds #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_leds (
        .clk    (clk),
        .rst    (rst),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .led_n  (led_n)
    );

endmodule
