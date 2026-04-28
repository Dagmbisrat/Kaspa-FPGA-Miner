`timescale 1ns / 1ps
//
// cshake256_tb — Testbench for cshake256_pipelined_core
//
// Three phases
//   1. Latency   — single valid_in pulse (s_value=1), count edges until valid_out.
//                  Must equal PIPE_DEPTH = 26.
//
//   2. HeavyHash correctness — 8 inputs sent back-to-back (s_value=1 constant
//                  throughout), 8 outputs compared to Python reference.
//
//   3. ProofOfWorkHash correctness — 8 inputs (s_value=0), compared to reference.
//
// For throughput benchmarking use: make throughput
//

module cshake256_tb;

// ── Sizing parameters ─────────────────────────────────────────────────────────
// Must match gen_vectors.py
parameter int NUM_HH_TESTS   = 8;
parameter int NUM_POW_TESTS  = 8;
parameter int NUM_TESTS      = NUM_HH_TESTS + NUM_POW_TESTS;
parameter int WORDS_PER_TEST = 15;   // 1 control + 10 data_in + 4 hash
parameter int PIPE_DEPTH     = 26;   // pipeline stages → valid_out latency
parameter int CLK_PERIOD_NS  = 10;   // 100 MHz simulation clock

// ── DUT signals ───────────────────────────────────────────────────────────────
logic        clk;
logic        rst;
logic [639:0] data_in;
logic         data_80byte;
logic         s_value;
logic         valid_in;
logic [255:0] hash_out;
logic         valid_out;

// ── DUT ──────────────────────────────────────────────────────────────────────
cshake256_pipelined_core uut (
    .clk         (clk),
    .rst         (rst),       // note: rst is unimplemented in RTL; driven for completeness
    .data_in     (data_in),
    .data_80byte (data_80byte),
    .s_value     (s_value),
    .valid_in    (valid_in),
    .hash_out    (hash_out),
    .valid_out   (valid_out)
);

// ── Clock ────────────────────────────────────────────────────────────────────
always #(CLK_PERIOD_NS / 2) clk = ~clk;

// ── Test vector storage ───────────────────────────────────────────────────────
logic [63:0]  vectors  [0 : NUM_TESTS * WORDS_PER_TEST - 1];
logic [255:0] exp_hash [0 : NUM_TESTS - 1];  // pre-filled by send_batch

// ── Shared counters / timing ──────────────────────────────────────────────────
integer pass_count  = 0;
integer fail_count  = 0;
integer lat_cycles;

// ─────────────────────────────────────────────────────────────────────────────
// send_batch
//   Sends 'count' test vectors (starting at index start_idx in the vectors[]
//   array) as back-to-back valid_in pulses.  All entries in the batch MUST
//   share the same s_value.  exp_hash[0..count-1] is filled with expected
//   values so collect_batch can compare without re-reading vectors[].
// ─────────────────────────────────────────────────────────────────────────────
task automatic send_batch(input int start_idx, input int count);
    int ti, b;
    for (ti = start_idx; ti < start_idx + count; ti++) begin
        b           = ti * WORDS_PER_TEST;
        s_value     = vectors[b][0];
        data_80byte = vectors[b][1];
        data_in     = {vectors[b+10], vectors[b+9], vectors[b+8],
                       vectors[b+7],  vectors[b+6], vectors[b+5],
                       vectors[b+4],  vectors[b+3], vectors[b+2],
                       vectors[b+1]};
        exp_hash[ti - start_idx] = {vectors[b+14], vectors[b+13],
                                     vectors[b+12], vectors[b+11]};
        $display("  TX[%0d]  s=%0b  80B=%0b  data=%h",
                 ti, s_value, data_80byte, data_in[255:0]); // show first 256 bits
        #1 valid_in = 1;
        @(posedge clk);
        #1;  // hold dat
    end
    #1 valid_in = 0;
    data_in = '0;
endtask

// ─────────────────────────────────────────────────────────────────────────────
// collect_batch
//   Waits for valid_out then reads 'count' consecutive outputs, comparing
//   each to exp_hash[0..count-1].  Two extra clock edges at the end let
//   valid_out return to 0 before the next phase starts.
// ─────────────────────────────────────────────────────────────────────────────
task automatic collect_batch(input int count, input string label);
    int ci;
    wait (valid_out === 1'b1);
    for (ci = 0; ci < count; ci++) begin
        #1; // settle past the clock edge
        if (hash_out !== exp_hash[ci]) begin
            $display("  FAIL [%s] test %0d", label, ci);
            $display("       exp: %h", exp_hash[ci]);
            $display("       got: %h", hash_out);
            fail_count++;
        end else begin
            $display("  PASS [%s] test %0d  →  %h", label, ci, hash_out);
            pass_count++;
        end
        if (ci < count - 1) @(posedge clk);
    end
    repeat (2) @(posedge clk); // drain: let valid_out fall before next phase
endtask

// ─────────────────────────────────────────────────────────────────────────────

initial begin
    $dumpfile("sim/cshake256_tb.vcd");
    $dumpvars(0, cshake256_tb);
    $readmemh("sim/expected_vectors.mem", vectors);

    // Initialise
    clk = 0; rst = 1; valid_in = 0;
    data_in = '0; data_80byte = 0; s_value = 0;

    // Hold reset (note: RTL has no reset logic, held here for convention)
    repeat (3) @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    // ── Phase 1: Latency ─────────────────────────────────────────────────────
    $display("");
    $display("=== Phase 1: Latency Measurement ===");

    // Single valid_in pulse (use HeavyHash mode: s_value=1)
    s_value = 1; data_80byte = 1; data_in = '0;
    #1 valid_in = 1;
    @(posedge clk);     // <<< this is the edge that captures valid_in=1
    #1 valid_in = 0;

    // Count edges from capture until valid_out asserts
    lat_cycles = 0;
    while (!valid_out) begin
        @(posedge clk);
        lat_cycles++;
    end

    $display("  Latency  : %0d cycles  (expected PIPE_DEPTH = %0d)  %s",
             lat_cycles, PIPE_DEPTH,
             (lat_cycles == PIPE_DEPTH) ? "PASS" : "*** FAIL: MISMATCH ***");

    if (lat_cycles !== PIPE_DEPTH)
        $fatal(1, "Pipeline latency mismatch — check valid_sr width in cshake256_core.sv");

    repeat (3) @(posedge clk); // drain before next phase

    // ── Phase 2: HeavyHash correctness ───────────────────────────────────────
    $display("");
    $display("=== Phase 2: HeavyHash Correctness (%0d back-to-back, s_value=1) ===",
             NUM_HH_TESTS);
    send_batch(0, NUM_HH_TESTS);
    collect_batch(NUM_HH_TESTS, "HeavyHash");

    // ── Phase 3: ProofOfWorkHash correctness ─────────────────────────────────
    $display("");
    $display("=== Phase 3: ProofOfWorkHash Correctness (%0d back-to-back, s_value=0) ===",
             NUM_POW_TESTS);
    send_batch(NUM_HH_TESTS, NUM_POW_TESTS);
    collect_batch(NUM_POW_TESTS, "ProofOfWorkHash");

    // ── Summary ───────────────────────────────────────────────────────────────
    $display("");
    $display("==========================================");
    $display("  Latency     : %0d cycles", lat_cycles);
    $display("  Correctness : %0d PASS  %0d FAIL", pass_count, fail_count);
    $display("==========================================");

    if (fail_count > 0)
        $fatal(1, "FAIL: %0d test(s) failed", fail_count);
    else
        $finish;
end

endmodule
