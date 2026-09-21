`timescale 1ns / 1ps

module xoshiro256pp_tb;

parameter NUM_ITERS = 10;

logic [63:0] s0, s1, s2, s3;
logic [63:0] out, new_s0, new_s1, new_s2, new_s3;

xoshiro256pp uut (
    .s0(s0), .s1(s1), .s2(s2), .s3(s3),
    .out(out),
    .new_s0(new_s0), .new_s1(new_s1), .new_s2(new_s2), .new_s3(new_s3)
);

// File-loaded vectors: row 0 = seed, rows 1..NUM_ITERS = expected
// Each row: [4]=out [3]=s0 [2]=s1 [1]=s2 [0]=s3  (5 x 64-bit packed into 320-bit words)
logic [319:0] vectors [0:NUM_ITERS];

// Helpers to unpack a row
`define VEC_OUT(r) vectors[r][319:256]
`define VEC_S0(r)  vectors[r][255:192]
`define VEC_S1(r)  vectors[r][191:128]
`define VEC_S2(r)  vectors[r][127:64]
`define VEC_S3(r)  vectors[r][63:0]

integer i;
integer pass_count;
integer fail_count;

initial begin
    $dumpfile("sim/xoshiro256pp_tb.vcd");
    $dumpvars(0, xoshiro256pp_tb);

    $readmemh("sim/expected_vectors.mem", vectors);

    pass_count = 0;
    fail_count = 0;

    // Load seed from vectors[0]
    s0 = `VEC_S0(0);
    s1 = `VEC_S1(0);
    s2 = `VEC_S2(0);
    s3 = `VEC_S3(0);

    // Run iterations, compare against expected
    for (i = 0; i < NUM_ITERS; i = i + 1) begin
        #10;

        if (out !== `VEC_OUT(i+1) ||
            new_s0 !== `VEC_S0(i+1) || new_s1 !== `VEC_S1(i+1) ||
            new_s2 !== `VEC_S2(i+1) || new_s3 !== `VEC_S3(i+1)) begin
            $display("FAIL iter %0d", i);
            $display("  out:  got=%h exp=%h %s", out, `VEC_OUT(i+1), (out !== `VEC_OUT(i+1)) ? "<-- MISMATCH" : "");
            $display("  s0:   got=%h exp=%h %s", new_s0, `VEC_S0(i+1), (new_s0 !== `VEC_S0(i+1)) ? "<-- MISMATCH" : "");
            $display("  s1:   got=%h exp=%h %s", new_s1, `VEC_S1(i+1), (new_s1 !== `VEC_S1(i+1)) ? "<-- MISMATCH" : "");
            $display("  s2:   got=%h exp=%h %s", new_s2, `VEC_S2(i+1), (new_s2 !== `VEC_S2(i+1)) ? "<-- MISMATCH" : "");
            $display("  s3:   got=%h exp=%h %s", new_s3, `VEC_S3(i+1), (new_s3 !== `VEC_S3(i+1)) ? "<-- MISMATCH" : "");
            fail_count = fail_count + 1;
        end else begin
            $display("PASS iter %0d  out=%h", i, out);
            pass_count = pass_count + 1;
        end

        // Feed next state back
        s0 = new_s0;
        s1 = new_s1;
        s2 = new_s2;
        s3 = new_s3;
    end

    $display("");
    $display("=============================");
    $display(" Results: %0d PASS, %0d FAIL", pass_count, fail_count);
    $display("=============================");

    if (fail_count > 0)
        $fatal(1, "FAIL: %0d test(s) failed", fail_count);
    else
        $finish;
end

endmodule
