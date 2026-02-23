`timescale 1ns / 1ps

// matrix_rank_tb.sv
//
// Tests matrix_rankcheck against three matrix types:
//   1. Full-rank diagonal  → full_rank = 1
//   2. Duplicate rows      → full_rank = 0
//   3. All-zero rows       → full_rank = 0
//   4. Reset mid-operation → recovers and returns correct result
//   5. Back-to-back runs   → DUT re-loads from cache each time

module matrix_rank_tb;

  // ── Parameters ─────────────────────────────────────────────────────────────
  parameter TIMEOUT = 400;    // max ELIM cycles before test declared failed

  // ── Clock / reset ──────────────────────────────────────────────────────────
  logic clk = 0;
  logic rst;
  always #5 clk = ~clk;

  // ── DUT signals ────────────────────────────────────────────────────────────
  logic         start;
  logic         done;
  logic         full_rank;

  // ── Cache write signals (driven by TB) ────────────────────────────────────
  logic         wr_matrix_en;
  logic [7:0]   n16th_value;
  logic [63:0]  wr_matrix_data;

  // ── Cache read signals (shared between DUT and cache) ─────────────────────
  logic         rd_en;
  logic [5:0]   rd_row;
  logic [255:0] rd_row_data;

  // ── Cache ──────────────────────────────────────────────────────────────────
  matrix_cache cache (
    .clk              (clk),
    .rst              (rst),
    .wr_matrix_en     (wr_matrix_en),
    .wr_PrePowHash_en (1'b0),
    .n16th_value      (n16th_value),
    .wr_matrix_data   (wr_matrix_data),
    .wr_PrePowHash    (256'h0),
    .rd_en            (rd_en),
    .rd_row           (rd_row),
    .rd_row_data      (rd_row_data),
    .rd_PrePowHash    ()
  );

  // ── DUT ────────────────────────────────────────────────────────────────────
  matrix_rankcheck dut (
    .clk         (clk),
    .rst         (rst),
    .start       (start),
    .done        (done),
    .full_rank   (full_rank),
    .rd_en       (rd_en),
    .rd_row      (rd_row),
    .rd_row_data (rd_row_data)
  );

  // ── Helpers ────────────────────────────────────────────────────────────────
  integer pass_count, fail_count, cycle_count;

  // Write one 256-bit row into the cache.
  // The cache takes 4 writes of 64 bits to fill one row:
  //   n16th_value[7:2] = row index
  //   n16th_value[1:0] = group within row (0=elements 0-15, 1=16-31, ...)
  // Signals are set at negedge so they are stable before the following posedge.
  task automatic write_row(input logic [5:0] row, input logic [255:0] data);
    for (int g = 0; g < 4; g++) begin
      @(negedge clk);
      n16th_value    = {row, 2'(g)};
      wr_matrix_data = data[g*64 +: 64];
      wr_matrix_en   = 1'b1;
    end
    @(negedge clk);
    wr_matrix_en = 1'b0;
  endtask

  // Write all 64 rows.
  task automatic write_matrix(input logic [255:0] mat [64]);
    for (int r = 0; r < 64; r++)
      write_row(6'(r), mat[r]);
  endtask

  // Pulse start, wait for done, return cycle count and full_rank result.
  task automatic run_check(output integer cycles, output logic result);
    @(posedge clk); #1 start = 1;
    @(posedge clk); #1 start = 0;
    cycles = 0;
    while (!done && cycles < TIMEOUT) begin
      @(posedge clk);
      cycles = cycles + 1;
    end
    result = full_rank;
  endtask

  // ── Test matrices ──────────────────────────────────────────────────────────
  logic [255:0] mat_fullrank  [64];   // row i: only bit i*4 set → unique pivot per row
  logic [255:0] mat_deficient [64];   // row 1 = row 0 → rank 63
  logic [255:0] mat_allzero   [64];   // all zeros → rank 0

  // ── Main ───────────────────────────────────────────────────────────────────
  integer cycles;
  logic   result;

  initial begin
    $dumpfile("sim/matrix_rank_tb.vcd");
    $dumpvars(0, matrix_rank_tb);

    // ── Build test matrices ──────────────────────────────────────────────────
    // Full-rank: row i has bit i*4 set, so each row has its pivot at a unique
    // column. Elimination finds 64 pivots at columns 0,4,8,...,252.
    for (int i = 0; i < 64; i++) begin
      mat_fullrank[i]  = 256'h1 << (i * 4);
      mat_deficient[i] = 256'h1 << (i * 4);
      mat_allzero[i]   = 256'h0;
    end
    mat_deficient[1] = mat_deficient[0];   // row 1 = row 0 → rank drops to 63

    // ── Init ────────────────────────────────────────────────────────────────
    rst            = 1;
    start          = 0;
    wr_matrix_en   = 0;
    n16th_value    = 0;
    wr_matrix_data = 0;
    pass_count     = 0;
    fail_count     = 0;

    @(posedge clk); @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    // ════════════════════════════════════════════════════════════════════════
    // Test 1: full-rank matrix → expect full_rank = 1
    // ════════════════════════════════════════════════════════════════════════
    $display("─────────────────────────────────────────────────");
    $display("Test 1: full-rank matrix (diagonal nibbles)");
    write_matrix(mat_fullrank);
    run_check(cycles, result);

    if (cycles >= TIMEOUT) begin
      $display("  FAIL: timed out after %0d cycles", TIMEOUT);
      fail_count++;
    end else if (result !== 1'b1) begin
      $display("  FAIL: expected full_rank=1, got %0b (cycles=%0d)", result, cycles);
      fail_count++;
    end else begin
      $display("  PASS: full_rank=1 in %0d cycles", cycles);
      pass_count++;
    end

    // ════════════════════════════════════════════════════════════════════════
    // Test 2: rank-deficient matrix (row 1 == row 0) → expect full_rank = 0
    // After elimination row 1 XORs to all-zero → rank stays at 63
    // ════════════════════════════════════════════════════════════════════════
    @(posedge clk); @(posedge clk);
    $display("─────────────────────────────────────────────────");
    $display("Test 2: rank-deficient matrix (row 1 = row 0)");
    write_matrix(mat_deficient);
    run_check(cycles, result);

    if (cycles >= TIMEOUT) begin
      $display("  FAIL: timed out after %0d cycles", TIMEOUT);
      fail_count++;
    end else if (result !== 1'b0) begin
      $display("  FAIL: expected full_rank=0, got %0b (cycles=%0d)", result, cycles);
      fail_count++;
    end else begin
      $display("  PASS: full_rank=0 in %0d cycles", cycles);
      pass_count++;
    end

    // ════════════════════════════════════════════════════════════════════════
    // Test 3: all-zero matrix → expect full_rank = 0
    // No pivot is ever found; all 256 columns are exhausted
    // ════════════════════════════════════════════════════════════════════════
    @(posedge clk); @(posedge clk);
    $display("─────────────────────────────────────────────────");
    $display("Test 3: all-zero matrix");
    write_matrix(mat_allzero);
    run_check(cycles, result);

    if (cycles >= TIMEOUT) begin
      $display("  FAIL: timed out after %0d cycles", TIMEOUT);
      fail_count++;
    end else if (result !== 1'b0) begin
      $display("  FAIL: expected full_rank=0, got %0b (cycles=%0d)", result, cycles);
      fail_count++;
    end else begin
      $display("  PASS: full_rank=0 in %0d cycles", cycles);
      pass_count++;
    end

    // ════════════════════════════════════════════════════════════════════════
    // Test 4: reset mid-operation, then complete run
    // Verifies the DUT clears internal state on rst and can restart cleanly.
    // Cache is also cleared by rst, so matrix must be re-written afterwards.
    // ════════════════════════════════════════════════════════════════════════
    @(posedge clk); @(posedge clk);
    $display("─────────────────────────────────────────────────");
    $display("Test 4: reset mid-operation then re-run");
    write_matrix(mat_fullrank);

    // Start a run, interrupt it after 10 cycles
    @(posedge clk); #1 start = 1;
    @(posedge clk); #1 start = 0;
    repeat (10) @(posedge clk);
    #1 rst = 1;
    @(posedge clk); @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    // Cache was cleared by rst — re-write before running
    write_matrix(mat_fullrank);
    run_check(cycles, result);

    if (cycles >= TIMEOUT) begin
      $display("  FAIL: timed out after reset");
      fail_count++;
    end else if (result !== 1'b1) begin
      $display("  FAIL: expected full_rank=1 after reset, got %0b", result);
      fail_count++;
    end else begin
      $display("  PASS: recovered after reset, full_rank=1 in %0d cycles", cycles);
      pass_count++;
    end

    // ════════════════════════════════════════════════════════════════════════
    // Test 5: back-to-back runs on the same cache content
    // DUT must re-read from cache on each start (M[] is re-loaded, not reused)
    // ════════════════════════════════════════════════════════════════════════
    @(posedge clk); @(posedge clk);
    $display("─────────────────────────────────────────────────");
    $display("Test 5: back-to-back runs, same cache (full-rank)");
    write_matrix(mat_fullrank);

    run_check(cycles, result);   // first run
    run_check(cycles, result);   // second run immediately after done

    if (cycles >= TIMEOUT) begin
      $display("  FAIL: second run timed out");
      fail_count++;
    end else if (result !== 1'b1) begin
      $display("  FAIL: expected full_rank=1 on second run, got %0b", result);
      fail_count++;
    end else begin
      $display("  PASS: second run full_rank=1 in %0d cycles", cycles);
      pass_count++;
    end

    // ════════════════════════════════════════════════════════════════════════
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
