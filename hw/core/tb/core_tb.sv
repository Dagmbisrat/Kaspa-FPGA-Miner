`timescale 1ns / 1ps

module core_tb;

parameter NUM_TESTS      = 7;
parameter WORDS_PER_TEST = 10;  // 4 pre_pow_hash + 1 timestamp + 1 nonce + 4 hash_out

logic         clk;
logic         rst;
logic         start;
logic [255:0] pre_pow_hash;
logic [63:0]  timestamp;
logic [63:0]  nonce;
logic [255:0] hash_out;
logic         done;

core uut (
    .clk         (clk),
    .rst         (rst),
    .start       (start),
    .pre_pow_hash(pre_pow_hash),
    .timestamp   (timestamp),
    .nonce       (nonce),
    .hash_out    (hash_out),
    .done        (done)
);

// Clock: 10ns period
always #5 clk = ~clk;

// Flat 64-bit word array loaded by $readmemh
logic [63:0] vectors [0:NUM_TESTS * WORDS_PER_TEST - 1];

integer       t, base;
integer       pass_count, fail_count;
logic [255:0] expected_hash;

initial begin
    $dumpfile("sim/core_tb.vcd");
    $dumpvars(0, core_tb);

    $readmemh("sim/expected_vectors.mem", vectors);

    clk          = 0;
    rst          = 1;
    start        = 0;
    pre_pow_hash = '0;
    timestamp    = '0;
    nonce        = '0;
    pass_count   = 0;
    fail_count   = 0;

    @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    for (t = 0; t < NUM_TESTS; t = t + 1) begin
        base = t * WORDS_PER_TEST;

        // Words 0-3: pre_pow_hash (4 x 64-bit lanes, little-endian)
        // Lane 0 -> [63:0], Lane 3 -> [255:192]
        pre_pow_hash = {vectors[base + 3], vectors[base + 2],
                        vectors[base + 1], vectors[base + 0]};

        // Word 4: timestamp
        timestamp = vectors[base + 4];

        // Word 5: nonce
        nonce = vectors[base + 5];

        // Words 6-9: expected hash_out (4 x 64-bit lanes, little-endian)
        expected_hash = {vectors[base + 9], vectors[base + 8],
                         vectors[base + 7], vectors[base + 6]};

        $display("--- Test %0d ---", t);
        $display("  pre_pow_hash : %h", pre_pow_hash);
        $display("  timestamp    : %0d", timestamp);
        $display("  nonce        : %0d", nonce);
        $display("  expected     : %h", expected_hash);

        // Pulse start for one cycle
        @(posedge clk);
        #1 start = 1;
        @(posedge clk);
        #1 start = 0;

        // Wait for done pulse
        wait (done === 1'b1);
        #1;

        // Compare
        if (hash_out !== expected_hash) begin
            $display("FAIL test %0d", t);
            $display("  got: %h", hash_out);
            $display("  exp: %h", expected_hash);
            fail_count = fail_count + 1;
        end else begin
            $display("PASS test %0d: hash=%h", t, hash_out);
            pass_count = pass_count + 1;
        end

        // Reset between tests to clear all internal state
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
