// kaspa_miner -- top-level single-core miner. Pure structural glue: wires
// uart_if's register bus straight into work_controller, and
// work_controller's job/found ports straight into core. No logic of its
// own -- see docs/kaspa_miner.md for the block/sequence diagrams.
module kaspa_miner #(
    parameter int CSHAKE_STAGES = 24,
    parameter int MATMUL_STAGES = 8,
    parameter bit CSHAKE_FOLDED = 1'b0,
    parameter int CLK_FREQ_HZ   = 200_000_000,
    parameter int BAUD_RATE     = 3_000_000
) (
    input  logic clk,
    input  logic rst,

    input  logic rx,
    output logic tx
);

    logic [7:0]   reg_addr;
    logic [31:0]  reg_wdata;
    logic         reg_we;
    logic         reg_re;
    logic [31:0]  reg_rdata;

    logic         job_start;
    logic [255:0] job_pph;
    logic [63:0]  job_ts;
    logic [63:0]  job_nonce;
    logic [255:0] job_target;
    logic         job_found;
    logic [63:0]  job_found_nonce;
    logic [7:0]   job_found_work_id;

    uart_if #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) u_uart_if (
        .clk  (clk),
        .rst  (rst),
        .rx   (rx),
        .tx   (tx),
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
        .rdata(reg_rdata),

        .start        (job_start),
        .pre_pow_hash (job_pph),
        .timestamp    (job_ts),
        .nonce        (job_nonce),
        .target       (job_target),

        .found         (job_found),
        .found_nonce   (job_found_nonce),
        .found_work_id (job_found_work_id)
    );

    core #(
        .CSHAKE_STAGES(CSHAKE_STAGES),
        .MATMUL_STAGES(MATMUL_STAGES),
        .CSHAKE_FOLDED(CSHAKE_FOLDED)
    ) u_core (
        .clk (clk),
        .rst (rst),

        .start        (job_start),
        .pre_pow_hash (job_pph),
        .timestamp    (job_ts),
        .nonce        (job_nonce),
        .target       (job_target),

        // Raw streamed hash isn't consumed at this level -- only found/
        // found_nonce/found_work_id are, same as work_controller.md's diagram.
        /* verilator lint_off PINCONNECTEMPTY */
        .hash_out  (),
        .nonce_out (),
        .valid_out (),
        /* verilator lint_on PINCONNECTEMPTY */

        .found         (job_found),
        .found_nonce   (job_found_nonce),
        .found_work_id (job_found_work_id)
    );

endmodule
