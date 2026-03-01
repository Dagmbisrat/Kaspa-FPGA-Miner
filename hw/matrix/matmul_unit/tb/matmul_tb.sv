`timescale 1ns / 1ps

module matmul_tb;

  parameter NUM_TESTS = 20;
  parameter TIMEOUT   = 100;   // matmul takes 66 cycles; 100 gives plenty of margin

  // ── Clock / reset ──────────────────────────────────────────────────────────
  logic clk = 0;
  logic rst;
  always #5 clk = ~clk;

  // ── DUT signals ────────────────────────────────────────────────────────────
  logic         start;
  logic         done;
  logic [255:0] vector_in;
  logic [255:0] product_out;

  // ── Cache write signals (driven by TB) ────────────────────────────────────
  logic        wr_matrix_en;
  logic [7:0]  n16th_value;
  logic [63:0] wr_matrix_data;

  // ── Cache read signals (shared: DUT drives rd_en/rd_row, cache drives rd_row_data) ──
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
  matmul_unit dut (
    .clk         (clk),
    .rst         (rst),
    .start       (start),
    .vector_in   (vector_in),
    .done        (done),
    .rd_en       (rd_en),
    .rd_row      (rd_row),
    .rd_row_data (rd_row_data),
    .product_out (product_out)
  );

  // ── Vector storage ─────────────────────────────────────────────────────────
  // Per test (66 entries):
  //   [base+0]       vector_in (256-bit)
  //   [base+1..+64]  matrix rows 0..63 (256-bit each)
  //   [base+65]      expected product_out (256-bit)
  logic [255:0] vectors [0:NUM_TESTS*66-1];

  // ── Helpers ────────────────────────────────────────────────────────────────
  integer t, base;
  integer pass_count, fail_count, cycle_count;

  // Write one 256-bit matrix row into the cache (4 x 64-bit writes).
  // n16th_value[7:2] = row, n16th_value[1:0] = group (0-3, covering 16 elements each).
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

  // ── Main ───────────────────────────────────────────────────────────────────
  initial begin
    $dumpfile("sim/matmul_tb.vcd");
    $dumpvars(0, matmul_tb);

    $readmemh("sim/expected_vectors.mem", vectors);

    rst            = 1;
    start          = 0;
    vector_in      = '0;
    wr_matrix_en   = 0;
    n16th_value    = 0;
    wr_matrix_data = 0;
    pass_count     = 0;
    fail_count     = 0;

    @(posedge clk); @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    for (t = 0; t < NUM_TESTS; t++) begin
      base = t * 66;

      if (vectors[base] === 256'bx) begin
        $display("Test %0d: no vector data, skipping", t);
        continue;
      end

      $display("─────────────────────────────────────────────────");
      $display("Test %0d", t);

      // Load matrix rows into cache
      for (int r = 0; r < 64; r++)
        write_row(6'(r), vectors[base + 1 + r]);

      // Present vector_in and start DUT
      @(negedge clk); vector_in = vectors[base];
      @(posedge clk); #1 start = 1;
      @(posedge clk); #1 start = 0;

      // Wait for done
      cycle_count = 0;
      while (!done && cycle_count < TIMEOUT) begin
        @(posedge clk);
        cycle_count++;
      end

      if (cycle_count >= TIMEOUT) begin
        $display("  FAIL: timed out after %0d cycles", TIMEOUT);
        fail_count++;
        continue;
      end

      $display("  Completed in %0d cycles", cycle_count);

      if (product_out !== vectors[base + 65]) begin
        $display("  FAIL: product mismatch");
        $display("    expected: %h", vectors[base + 65]);
        $display("    got:      %h", product_out);
        fail_count++;
      end else begin
        $display("  PASS: product_out = %h", product_out);
        pass_count++;
      end

      @(posedge clk); @(posedge clk);
    end

    $display("");
    $display("═════════════════════════════════════════════════");
    $display(" Results: %0d PASS, %0d FAIL", pass_count, fail_count);
    $display("═════════════════════════════════════════════════");
    if (fail_count > 0)
      $fatal(1, "FAIL: %0d test(s) failed", fail_count);
    else begin
      $display(" All tests passed!");
      $finish;
    end
  end

endmodule
