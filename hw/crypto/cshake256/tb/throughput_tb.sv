`timescale 1ns / 1ps
//
// throughput_tb.sv — Throughput benchmark for cshake256_pipelined_core
//
// The hash mode is fixed at BUILD TIME via the S_VALUE / DATA_80BYTE params.
// Throughput is mode-independent (feed-forward, ideal 1.0 H/cycle), so this
// benchmark builds the HeavyHash configuration by default.  Override the mode
// at compile time with -GS_VALUE=<0|1> -GDATA_80BYTE=<0|1>.
//
// Unfolded (FOLDED=0): feed-forward pipeline, one input accepted per cycle,
// one hash produced per cycle after the LATENCY = STAGES + 2 cycle fill.
// Folded (FOLDED=1): only one hash resident at a time (busy-gated), so
// throughput is capped at 1 / LATENCY regardless of batch size -- no
// fill-overhead curve, every batch runs at that same steady-state rate.
// Each batch drives valid_in whenever the DUT can accept it (gated by busy)
// and counts edges from the first sampled input to the n-th valid_out.
//
// For every batch reports:
//   - total cycles (first sampling edge → n-th valid_out edge)
//   - measured hashes/cycle
//   - MH/s at the assumed clock frequency
//
// Plusarg overrides:
//   +clk_mhz=N   assumed clock for MH/s display  (default 500)
// Compile-time:
//   -GFOLDED=<0|1>      0 = unfolded (default), 1 = folded
//   -GSTAGES=<n>        pipeline depth / fold width of the DUT (default 24; must divide 24)
//   -GS_VALUE=<0|1>     hash mode (default 1 = HeavyHash)
//   -GDATA_80BYTE=<0|1> input size (default 0 = 32-byte)

module throughput_tb;

  // ── Parameters ─────────────────────────────────────────────────────────────
  parameter bit FOLDED        = 1'b0;   // override with -GFOLDED=<0|1>
  parameter int STAGES        = 24;     // override with -GSTAGES=<n>
  parameter bit S_VALUE       = 1'b1;   // 1 = HeavyHash, 0 = ProofOfWorkHash
  parameter bit DATA_80BYTE   = 1'b0;   // 0 = 32-byte, 1 = 80-byte
  parameter int CLK_PERIOD_NS = 10;
  localparam int LATENCY          = FOLDED ? (24 / STAGES + 2) : (STAGES + 2);
  // Critical path in Keccak rounds: unfolded chains 24/STAGES rounds per
  // register layer; folded chains STAGES rounds per fold pass.
  localparam int CRIT_PATH_ROUNDS = FOLDED ? STAGES : (24 / STAGES);

  // Batch sizes to sweep (number of back-to-back hashes per run)
  localparam int NUM_BATCHES = 7;
  int batch_sizes [NUM_BATCHES] = '{32, 128, 512, 2048, 8192, 32768, 131072};

  // ── DUT signals ────────────────────────────────────────────────────────────
  logic         clk;
  logic         rst;
  logic [639:0] data_in;
  logic         valid_in;
  logic [255:0] hash_out;
  logic         valid_out;
  logic         busy;

  // ── DUT (mode fixed at build time) ─────────────────────────────────────────
  cshake256_pipelined_core #(
    .FOLDED     (FOLDED),
    .STAGES     (STAGES),
    .S_VALUE    (S_VALUE),
    .DATA_80BYTE(DATA_80BYTE)
  ) uut (
    .clk       (clk),
    .rst       (rst),
    .data_in   (data_in),
    .valid_in  (valid_in),
    .hash_out  (hash_out),
    .valid_out (valid_out),
    .busy      (busy)
  );

  always #(CLK_PERIOD_NS / 2) clk = ~clk;

  // ── Plusarg knobs ──────────────────────────────────────────────────────────
  integer clk_mhz = 500;

  // ── Statistics ─────────────────────────────────────────────────────────────
  real    min_tp, max_tp, sum_tp;
  real    min_cph, max_cph, sum_cph;  // cycles/hash = 1/throughput
  integer bi;
  real    throughput, cyc_per_hash;

  // ── Main ───────────────────────────────────────────────────────────────────
  initial begin
    // No VCD — trace files for large batches would be enormous

    void'($value$plusargs("clk_mhz=%d", clk_mhz));

    clk = 0; rst = 1; valid_in = 0;
    data_in = '0;

    min_tp  = 1e30; max_tp  = 0.0; sum_tp  = 0.0;
    min_cph = 1e30; max_cph = 0.0; sum_cph = 0.0;

    repeat (3) @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    $display("");
    $display("═══════════════════════════════════════════════════════════════");
    $display(" cshake256_pipelined_core  —  Throughput Benchmark");
    $display("───────────────────────────────────────────────────────────────");
    $display("  Mode     : %s (S_VALUE=%0b)",
             S_VALUE ? "HeavyHash" : "ProofOfWorkHash", S_VALUE);
    $display("  Clock    : %0d MHz (assumed for MH/s)", clk_mhz);
    $display("  Pipeline : FOLDED=%0d STAGES=%0d  (fill latency %0d cycles)", FOLDED, STAGES, LATENCY);
    $display("  Timing   : %0d Keccak round(s) on the critical path (Fmax knob)", CRIT_PATH_ROUNDS);
    $display("───────────────────────────────────────────────────────────────");
    $display("  %8s  %8s  %12s  %12s  %10s", "Batch", "Cycles", "H/cycle", "cycles/hash", "MH/s");
    $display("───────────────────────────────────────────────────────────────");

    for (bi = 0; bi < NUM_BATCHES; bi++) begin
      automatic int n           = batch_sizes[bi];
      automatic int sent        = 0;
      automatic int out_count   = 0;
      automatic int cycle_count = 0;

      // Drive a new input whenever the DUT can accept one (sent < n and not
      // busy -- busy is tied low when unfolded, so this reduces to "every
      // cycle" there). admit_now is latched before the edge so the post-edge
      // sent++ reflects exactly what the DUT actually admitted this cycle,
      // not a stale/future busy reading.
      forever begin
        automatic bit admit_now = (sent < n) && !busy;
        if (admit_now) begin
          valid_in      = 1;
          data_in[63:0] = 64'(sent);
        end else begin
          valid_in = 0;
          data_in  = '0;
        end

        @(posedge clk);
        cycle_count++;
        if (admit_now) sent++;

        if (valid_out) begin
          out_count++;
          if (out_count == n) break;
        end
      end

      valid_in = 0;
      data_in  = '0;

      throughput   = real'(n) / real'(cycle_count);
      cyc_per_hash = real'(cycle_count) / real'(n);

      $display("  %8d  %8d  %12.6f  %12.4f  %10.2f",
               n, cycle_count, throughput, cyc_per_hash, throughput * real'(clk_mhz));

      if (throughput < min_tp) min_tp = throughput;
      if (throughput > max_tp) max_tp = throughput;
      sum_tp += throughput;
      if (cyc_per_hash < min_cph) min_cph = cyc_per_hash;
      if (cyc_per_hash > max_cph) max_cph = cyc_per_hash;
      sum_cph += cyc_per_hash;

      // drain the pipeline before the next batch
      repeat (LATENCY + 4) @(posedge clk);
    end

    // ── Summary ──────────────────────────────────────────────────────────────
    $display("───────────────────────────────────────────────────────────────");
    $display("  Min throughput : %.6f H/cycle  (%.4f cycles/hash, %.2f MH/s)",
             min_tp, max_cph, min_tp * real'(clk_mhz));
    $display("  Max throughput : %.6f H/cycle  (%.4f cycles/hash, %.2f MH/s)",
             max_tp, min_cph, max_tp * real'(clk_mhz));
    $display("  Avg throughput : %.6f H/cycle  (%.4f cycles/hash, %.2f MH/s)",
             sum_tp / real'(NUM_BATCHES), sum_cph / real'(NUM_BATCHES),
             sum_tp / real'(NUM_BATCHES) * real'(clk_mhz));
    if (!FOLDED) begin
      $display("  Throughput is design-fixed at 1.000000 H/cycle (feed-forward);");
      $display("  the batch numbers above only show fill-overhead approaching that.");
      $display("  Fill latency  : %0d cycles  (STAGES + 2)", LATENCY);
    end else begin
      $display("  Throughput is design-fixed at 1/%0d = %.6f H/cycle (%0d cycles/hash) --", LATENCY, 1.0/real'(LATENCY), LATENCY);
      $display("  only one hash resident at a time (busy-gated), so every batch runs");
      $display("  at this same steady-state rate with no fill-overhead curve.");
      $display("  Fill latency  : %0d cycles  (24/STAGES + 2)", LATENCY);
    end
    $display("  Timing lever  : critical path = %0d Keccak round(s)", CRIT_PATH_ROUNDS);
    if (!FOLDED)
      $display("  Real MH/s     = Fmax x 1 H/cycle  ->  measure Fmax via synthesis");
    else
      $display("  Real MH/s     = Fmax x %.6f H/cycle  ->  measure Fmax via synthesis", 1.0/real'(LATENCY));
    $display("═══════════════════════════════════════════════════════════════");

    $finish;
  end

endmodule
