`timescale 1ns / 1ps

module matrix_tb;

  // ── Parameters ──
  parameter NUM_TESTS = 3;         // max test cases in vector file
  parameter TIMEOUT   = 1000;      // max cycles per test before fail

  // ── DUT signals ──
  logic          clk;
  logic          rst;
  logic          start;
  logic [255:0]  PrePowHash;
  logic          done;

  matrix_generator uut (
    .clk(clk),
    .rst(rst),
    .start(start),
    .PrePowHash(PrePowHash),
    .done(done)
  );

  // ── Clock: 10 ns period ──
  always #5 clk = ~clk;

  // ── Vector storage ──
  // Each test: 1 seed line + 64 matrix row lines = 65 lines
  // Max storage: NUM_TESTS * 65
  logic [255:0] vectors [0:NUM_TESTS*65-1];

  // ── Helpers ──
  integer test_idx, row, col;
  integer pass_count, fail_count;
  integer cycle_count;
  integer base;
  logic [255:0] expected_row;
  logic [3:0]   got_val, exp_val;
  logic         row_mismatch;

  initial begin
    $dumpfile("matrix_tb.vcd");
    $dumpvars(0, matrix_tb);

    $readmemh("expected_matrix.mem", vectors);

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

      // Skip if seed is X/0 (fewer tests in file than NUM_TESTS)
      if (vectors[base] === 256'bx) begin
        $display("Test %0d: no vector data, skipping", test_idx);
        continue;
      end

      PrePowHash = vectors[base];
      $display("─────────────────────────────────────────────────");
      $display("Test %0d: PrePowHash = %h", test_idx, PrePowHash);

      // ── First run: cache miss → full generation ──
      @(posedge clk);
      #1 start = 1;
      @(posedge clk);
      #1 start = 0;

      // Wait for done
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

      // ── Verify matrix contents via hierarchical access ──
      row_mismatch = 0;
      for (row = 0; row < 64; row = row + 1) begin
        expected_row = vectors[base + 1 + row];
        for (col = 0; col < 64; col = col + 1) begin
          got_val = uut.cached.matrix[row][col];
          exp_val = expected_row[col*4 +: 4];
          if (got_val !== exp_val) begin
            if (!row_mismatch)
              $display("  FAIL: matrix mismatch detected");
            $display("    [%0d][%0d]: got=%h exp=%h", row, col, got_val, exp_val);
            row_mismatch = 1;
          end
        end
      end

      if (row_mismatch) begin
        fail_count = fail_count + 1;
      end else begin
        $display("  PASS: matrix matches reference");
        pass_count = pass_count + 1;
      end

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
        // Cache hit should complete in ~3-4 cycles (IDLE→IDLE_CHECK→DONE→done reg)
        $display("  WARN: cache hit took %0d cycles (expected ~3-4)", cycle_count);
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
