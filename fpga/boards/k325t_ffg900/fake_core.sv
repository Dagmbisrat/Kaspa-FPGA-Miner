// fake_core: test stand-in for core. Per job: finds nonce+42, then nonce+1337.
module fake_core #(
    parameter int FIND_DELAY = 1_000_000   // cycles
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          start,
    input  logic [63:0]   nonce,

    output logic          found,
    output logic [63:0]   found_nonce,
    output logic [7:0]    found_work_id
);

    localparam int CNT_BITS = $clog2(2*FIND_DELAY + 1);

    logic [7:0]          work_id;
    logic [63:0]         nonce_base;
    logic [CNT_BITS-1:0] cnt;
    logic                running;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            work_id       <= '0;
            nonce_base    <= '0;
            cnt           <= '0;
            running       <= 1'b0;
            found         <= 1'b0;
            found_nonce   <= '0;
            found_work_id <= '0;
        end else begin
            found <= 1'b0;
            if (start) begin
                work_id    <= work_id + 1'b1;
                nonce_base <= nonce;
                cnt        <= '0;
                running    <= 1'b1;
            end else if (running) begin
                cnt <= cnt + 1'b1;
                if (cnt == CNT_BITS'(FIND_DELAY)) begin
                    found         <= 1'b1;
                    found_nonce   <= nonce_base + 64'd42;
                    found_work_id <= work_id;
                end else if (cnt == CNT_BITS'(2*FIND_DELAY)) begin
                    found         <= 1'b1;
                    found_nonce   <= nonce_base + 64'd1337;
                    found_work_id <= work_id;
                    running       <= 1'b0;
                end
            end
        end
    end

endmodule
