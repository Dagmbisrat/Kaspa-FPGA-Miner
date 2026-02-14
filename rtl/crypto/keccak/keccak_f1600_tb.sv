`timescale 1ns / 1ps

module keccak_f1600_tb;

parameter NUM_TESTS = 3;

logic        clk;
logic        rst;
logic        start;
logic [63:0] state_in  [0:4][0:4];
logic [63:0] state_out [0:4][0:4];
logic        done;

keccak_f1600 uut (
    .clk(clk),
    .rst(rst),
    .start(start),
    .state_in(state_in),
    .state_out(state_out),
    .done(done)
);

// Clock generation
always #5 clk = ~clk;

// Flat vector storage: 25 input lanes + 25 output lanes per test
// $readmemh skips comment lines, reads 64-bit hex values sequentially
logic [63:0] vectors [0:NUM_TESTS*50-1];

integer t, x, y, idx;
integer pass_count, fail_count;
logic mismatch;

initial begin
    $dumpfile("keccak_f1600_tb.vcd");
    $dumpvars(0, keccak_f1600_tb);

    $readmemh("expected_vectors.mem", vectors);

    clk = 0;
    rst = 1;
    start = 0;
    pass_count = 0;
    fail_count = 0;

    @(posedge clk);
    #1 rst = 0;

    for (t = 0; t < NUM_TESTS; t = t + 1) begin
        // Load input state from vectors
        for (x = 0; x < 5; x = x + 1)
            for (y = 0; y < 5; y = y + 1)
                state_in[x][y] = vectors[t*50 + x*5 + y];

        // Pulse start
        @(posedge clk);
        #1 start = 1;
        @(posedge clk);
        #1 start = 0;

        // Wait for done
        wait (done === 1'b1);
        @(posedge clk);
        #1;

        // Compare output
        mismatch = 0;
        for (x = 0; x < 5; x = x + 1) begin
            for (y = 0; y < 5; y = y + 1) begin
                idx = t*50 + 25 + x*5 + y;
                if (state_out[x][y] !== vectors[idx]) begin
                    $display("FAIL test %0d lane [%0d][%0d]: got=%h exp=%h",
                             t, x, y, state_out[x][y], vectors[idx]);
                    mismatch = 1;
                end
            end
        end

        if (mismatch)
            fail_count = fail_count + 1;
        else begin
            $display("PASS test %0d", t);
            pass_count = pass_count + 1;
        end
    end

    $display("");
    $display("=============================");
    $display(" Results: %0d PASS, %0d FAIL", pass_count, fail_count);
    $display("=============================");

    $finish;
end

endmodule
