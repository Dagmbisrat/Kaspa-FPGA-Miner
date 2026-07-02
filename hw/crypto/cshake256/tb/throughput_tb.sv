`timescale 1ns / 1ps
//
// throughput_tb.sv — Throughput benchmark for cshake256_pipelined_core
//
// Feed-forward pipeline: one input accepted per cycle, one hash produced per
// cycle after the LATENCY = NUM_STAGES + 2 cycle fill.  Each batch drives
// valid_in every cycle and counts edges from the first sampled input to the
// n-th valid_out, so measured throughput approaches the ideal 1.0 H/cycle.
//
// For every batch reports:
//   - total cycles (first sampling edge → n-th valid_out edge)
//   - measured hashes/cycle
//   - MH/s at the assumed clock frequency
//
// Plusarg overrides:
//   +clk_mhz=N   assumed clock for MH/s display  (default 500)
//   +s_value=N   hash mode: 1=HeavyHash, 0=POW   (default 1)
// Compile-time:
//   -GNUM_STAGES=<n>   pipeline depth of the DUT (default 24; must divide 24)

module throughput_tb;

  // ── Parameters ───────────────────────────────────────────────────────────────
  parameter int NUM_STAGES    = 24;   // override with -GNUM_STAGES=<n>
  parameter int CLK_PERIOD_NS = 10;
  localparam int LATENCY      = NUM_STAGES + 2;

  // Batch sizes to sweep (number of back-to-back hashes per run)
  localparam int NUM_BATCHES = 7;
  int batch_sizes [NUM_BATCHES] = '{32, 128, 512, 2048, 8192, 32768, 131072};

  // ── DUT signals ────────────────────────────────────────────────────────────
  logic         clk;
  logic         rst;
  logic [639:0] data_in;
  logic         data_80byte;
  logic         s_value;
  logic         valid_in;
  logic [255:0] hash_out;
  logic         valid_out;

  // ── DUT ──────────────────────────────────────────────────────────────────────
  cshake256_pipelined_core #(.NUM_STAGES(NUM_STAGES)) uut (
    .clk         (clk),
    .rst         (rst),
    .data_in     (data_in),
    .data_80byte (data_80byte),
    .s_value     (s_value),
    .valid_in    (valid_in),
    .hash_out    (hash_out),
    .valid_out   (valid_out)
  );

  always #(CLK_PERIOD_NS / 2) clk = ~clk;

  // ── Plusarg knobs ────────────────────────────────────────────────────────────
  integer clk_mhz = 500;
  integer s_val   = 1;

  // ── Statistics ────────────────────────────────────────────────────────────────
  real    min_tp, max_tp, sum_tp;
  integer bi;
  real    throughput;

  // ── Main ─────────────────────────────────────────────────────────────────────
  initial begin
    // No VCD — trace files for large batches would be enormous

    void'($value$plusargs("clk_mhz=%d", clk_mhz));
    void'($value$plusargs("s_value=%d", s_val));

    clk = 0; rst = 1; valid_in = 0;
    data_in = '0; data_80byte = 1;
    s_value = logic'(s_val[0]);

    min_tp = 1e30; max_tp = 0.0; sum_tp = 0.0;

    repeat (3) @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    $display("");
    $display("═══════════════════════════════════════════════════════════════");
    $display(" cshake256_pipelined_core  —  Throughput Benchmark");
    $display("───────────────────────────────────────────────────────────────");
    $display("  Mode     : %s (s_value=%0b)",
             s_val ? "HeavyHash" : "ProofOfWorkHash", s_val[0]);
    $display("  Clock    : %0d MHz (assumed for MH/s)", clk_mhz);
    $display("  Pipeline : NUM_STAGES=%0d  (fill latency %0d cycles)", NUM_STAGES, LATENCY);
    $display("───────────────────────────────────────────────────────────────");
    $display("  %8s  %8s  %12s  %10s", "Batch", "Cycles", "H/cycle", "MH/s");
    $display("───────────────────────────────────────────────────────────────");

    for (bi = 0; bi < NUM_BATCHES; bi++) begin
      automatic int n           = batch_sizes[bi];
      automatic int sent        = 0;
      automatic int out_count   = 0;
      automatic int cycle_count = 0;

      // Drive one new input every cycle until all n are sent; count edges from
      // the first sampled input until the n-th output is observed.
      forever begin
        if (sent < n) begin
          valid_in      = 1;
          data_in[63:0] = 64'(sent);
        end else begin
          valid_in = 0;
          data_in  = '0;
        end

        @(posedge clk);
        cycle_count++;
        if (sent < n) sent++;

        if (valid_out) begin
          out_count++;
          if (out_count == n) break;
        end
      end

      valid_in = 0;
      data_in  = '0;

      throughput = real'(n) / real'(cycle_count);

      $display("  %8d  %8d  %12.6f  %10.2f",
               n, cycle_count, throughput, throughput * real'(clk_mhz));

      if (throughput < min_tp) min_tp = throughput;
      if (throughput > max_tp) max_tp = throughput;
      sum_tp += throughput;

      // drain the pipeline before the next batch
      repeat (LATENCY + 4) @(posedge clk);
    end

    // ── Summary ────────────────────────────────────────────────────────────────
    $display("───────────────────────────────────────────────────────────────");
    $display("  Min throughput : %.6f H/cycle  (%.2f MH/s)",
             min_tp, min_tp * real'(clk_mhz));
    $display("  Max throughput : %.6f H/cycle  (%.2f MH/s)",
             max_tp, max_tp * real'(clk_mhz));
    $display("  Avg throughput : %.6f H/cycle  (%.2f MH/s)",
             sum_tp / real'(NUM_BATCHES), sum_tp / real'(NUM_BATCHES) * real'(clk_mhz));
    $display("  Ideal (pipelined): %.6f H/cycle  (%.2f MH/s)",
             1.0, real'(clk_mhz));
    $display("  Fill latency     : %0d cycles  (NUM_STAGES + 2)", LATENCY);
    $display("═══════════════════════════════════════════════════════════════");

    $finish;
  end

endmodule
