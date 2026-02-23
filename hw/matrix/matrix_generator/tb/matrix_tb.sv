`timescale 1ns / 1ps

module matrix_tb;

  // ── Parameters ──
  parameter NUM_TESTS = 49;        // max test cases in vector file
  parameter TIMEOUT   = 8000;      // max cycles per test (allows ~13 regen attempts)

  // ── DUT signals ──
  logic          clk;
  logic          rst;
  logic          start;
  logic [255:0]  PrePowHash;
  logic          done;

  // ── Cache bus signals ──
  logic          wr_matrix_en;
  logic          wr_PrePowHash_en;
  logic [7:0]    n16th_value;
  logic [63:0]   wr_matrix_data;
  logic          rd_en;
  logic [5:0]    rd_row;
  logic [255:0]  rd_row_data;
  logic [255:0]  rd_PrePowHash;

  matrix_generator uut (
    .clk              (clk),
    .rst              (rst),
    .start            (start),
    .PrePowHash       (PrePowHash),
    .done             (done),
    .wr_matrix_en     (wr_matrix_en),
    .wr_PrePowHash_en (wr_PrePowHash_en),
    .n16th_value      (n16th_value),
    .wr_matrix_data   (wr_matrix_data),
    .rd_en            (rd_en),
    .rd_row           (rd_row),
    .rd_row_data      (rd_row_data),
    .rd_PrePowHash    (rd_PrePowHash)
  );

  matrix_cache cache (
    .clk              (clk),
    .rst              (rst),
    .wr_matrix_en     (wr_matrix_en),
    .wr_PrePowHash_en (wr_PrePowHash_en),
    .n16th_value      (n16th_value),
    .wr_matrix_data   (wr_matrix_data),
    .wr_PrePowHash    (PrePowHash),
    .rd_en            (rd_en),
    .rd_row           (rd_row),
    .rd_row_data      (rd_row_data),
    .rd_PrePowHash    (rd_PrePowHash)
  );

  // ── Clock: 10 ns period ──
  always #5 clk = ~clk;

  // ── Vector storage ──
  // Each test: 1 seed line + 64 matrix row lines = 65 lines
  logic [255:0] vectors [0:NUM_TESTS*65-1];

  // ── Helpers ──
  integer test_idx;
  integer pass_count, fail_count;
  integer cycle_count;
  integer base;
  integer mismatch;
  logic [3:0] expected_nibble;
  logic [3:0] actual_nibble;

  initial begin
    $dumpfile("sim/matrix_tb.vcd");
    $dumpvars(0, matrix_tb);

    $readmemh("sim/expected_matrix.mem", vectors);

    clk        = 0;
    rst        = 1;
    start      = 0;
    PrePowHash = '0;
    pass_count = 0;
    fail_count = 0;

    // Reset
    @(posedge clk); @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    // ── Run each test case ──
    for (test_idx = 0; test_idx < NUM_TESTS; test_idx = test_idx + 1) begin
      base = test_idx * 65;

      // Skip if seed is X (fewer tests in file than NUM_TESTS)
      if (vectors[base] === 256'bx) begin
        $display("Test %0d: no vector data, skipping", test_idx);
        continue;
      end

      PrePowHash = vectors[base];
      $display("─────────────────────────────────────────────────");
      $display("Test %0d: PrePowHash = %h", test_idx, PrePowHash);

      // ── First run: cache miss → full generation + rank check ──
      @(posedge clk);
      #1 start = 1;
      @(posedge clk);
      #1 start = 0;

      cycle_count = 0;
      while (!done && cycle_count < TIMEOUT) begin
        @(posedge clk);
        cycle_count = cycle_count + 1;
      end

      if (cycle_count >= TIMEOUT) begin
        $display("  FAIL: timed out after %0d cycles", TIMEOUT);
        fail_count = fail_count + 1;
        continue;
      end

      $display("  Generation completed in %0d cycles", cycle_count);

      // ── Verify matrix content against expected vectors ──
      // Access cache internals directly via hierarchical reference.
      // vectors[base+1..base+64]: row r packed as 256 bits, nibble c at [c*4 +: 4].
      mismatch = 0;
      for (int r = 0; r < 64; r++) begin
        for (int c = 0; c < 64; c++) begin
          expected_nibble = vectors[base + 1 + r][c*4 +: 4];
          actual_nibble   = cache.matrix[r][c];
          if (actual_nibble !== expected_nibble)
            mismatch = mismatch + 1;
        end
      end

      if (mismatch > 0) begin
        $display("  FAIL: matrix content mismatch (%0d nibbles wrong)", mismatch);
        fail_count = fail_count + 1;
        continue;
      end

      $display("  PASS: matrix verified (%0d nibbles correct)", 64*64);
      pass_count = pass_count + 1;

      // ── Second run (same PrePowHash): cache hit → fast path ──
      @(posedge clk); @(posedge clk);
      #1 start = 1;
      @(posedge clk);
      #1 start = 0;

      cycle_count = 0;
      while (!done && cycle_count < TIMEOUT) begin
        @(posedge clk);
        cycle_count = cycle_count + 1;
      end

      if (cycle_count >= TIMEOUT) begin
        $display("  FAIL: cache-hit path timed out");
        fail_count = fail_count + 1;
      end else if (cycle_count > 5) begin
        // Cache hit: IDLE→IDLE_CHECK→DONE = ~3 cycles
        $display("  WARN: cache hit took %0d cycles (expected ≤5)", cycle_count);
      end else begin
        $display("  PASS: cache hit in %0d cycles", cycle_count);
        pass_count = pass_count + 1;
      end
    end

    // ── Summary ──
    $display("");
    $display("═════════════════════════════════════════════════");
    $display(" Results: %0d PASS, %0d FAIL", pass_count, fail_count);
    $display("═════════════════════════════════════════════════");

    if (fail_count > 0)
      $display(" *** FAILURES DETECTED ***");
    else
      $display(" All tests passed!");

    $finish;
  end

endmodule
