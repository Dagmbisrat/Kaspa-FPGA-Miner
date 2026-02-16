`timescale 1ns / 1ps

module cshake256_tb;

parameter NUM_TESTS = 8;
parameter WORDS_PER_TEST = 9;  // 1 control + 4 data_in + 4 expected_hash

logic        clk;
logic        rst;
logic        start;
logic [255:0] data_in;
logic         s_value;
logic [255:0] hash_out;
logic         done;

cshake256_core uut (
    .clk      (clk),
    .rst      (rst),
    .start    (start),
    .data_in  (data_in),
    .s_value  (s_value),
    .hash_out (hash_out),
    .done     (done)
);

// Clock generation
always #5 clk = ~clk;

// Flat 64-bit word storage loaded by $readmemh
logic [63:0] vectors [0:NUM_TESTS * WORDS_PER_TEST - 1];

integer t, base;
integer pass_count, fail_count;
logic [255:0] expected_hash;

initial begin
    $dumpfile("cshake256_tb.vcd");
    $dumpvars(0, cshake256_tb);

    $readmemh("expected_vectors.mem", vectors);

    clk = 0;
    rst = 1;
    start = 0;
    data_in = '0;
    s_value = 0;
    pass_count = 0;
    fail_count = 0;

    @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    for (t = 0; t < NUM_TESTS; t = t + 1) begin
        base = t * WORDS_PER_TEST;

        // Word 0: control — bit 0 = s_value
        s_value = vectors[base][0];

        // Words 1-4: data_in (4 x 64-bit lanes, little-endian)
        data_in = {vectors[base + 4], vectors[base + 3],
                   vectors[base + 2], vectors[base + 1]};

        // Words 5-8: expected hash (4 x 64-bit lanes, little-endian)
        expected_hash = {vectors[base + 8], vectors[base + 7],
                         vectors[base + 6], vectors[base + 5]};

        $display("--- Test %0d ---", t);
        $display("  s_value : %0b", s_value);
        $display("  data_in : %h", data_in);
        $display("  expected: %h", expected_hash);

        // Pulse start
        @(posedge clk);
        #1 start = 1;
        @(posedge clk);
        #1 start = 0;

        // Wait for done
        wait (done === 1'b1);
        @(posedge clk);
        #1;

        // Compare
        if (hash_out !== expected_hash) begin
            $display("FAIL test %0d: s_value=%0b", t, s_value);
            $display("  got:  %h", hash_out);
            $display("  exp:  %h", expected_hash);
            fail_count = fail_count + 1;
        end else begin
            $display("PASS test %0d: s_value=%0b hash=%h", t, s_value, hash_out);
            pass_count = pass_count + 1;
        end

        // Reset between tests to clear internal state
        #1 rst = 1;
        @(posedge clk);
        #1 rst = 0;
        @(posedge clk);
    end

    $display("");
    $display("=============================");
    $display(" Results: %0d PASS, %0d FAIL", pass_count, fail_count);
    $display("=============================");

    $finish;
end

endmodule
