`timescale 1ns / 1ps
//
// throughput_tb.sv — Throughput benchmark for core (streaming kHeavyHash pipeline)
//
// core's admission is paced by a free-running counter (N_MAX cycles/admit),
// fixed once streaming starts -- unlike cshake256's unfolded batch sweep,
// there is no batch-size-dependent fill-overhead curve here: after the
// one-time block load (matrix generation + matmul table rebuild), every
// valid_out is spaced exactly N_MAX cycles apart, indefinitely. So this
// benchmark starts one block, skips the load/fill period, then measures
// steady-state spacing over NUM_SAMPLES consecutive valid_out pulses.
//
// Plusarg overrides:
//   +clk_mhz=N   assumed clock for MH/s display (default 500)
// Compile-time:
//   -GCSHAKE_STAGES=<n>   cSHAKE pipeline depth (default 24; must divide 24)
//   -GMATMUL_STAGES=<n>   matmul pipeline depth (default 8; must divide 64)
//   -GCSHAKE_FOLDED=<0|1> fold both cSHAKE cores (default 0)

module throughput_tb;

  // ── Parameters ─────────────────────────────────────────────────────────────
  parameter int CSHAKE_STAGES = 24;    // override with -GCSHAKE_STAGES=<n>
  parameter int MATMUL_STAGES = 8;     // override with -GMATMUL_STAGES=<n>
  parameter bit CSHAKE_FOLDED = 1'b0;  // override with -GCSHAKE_FOLDED=<0|1>
  parameter int CLK_PERIOD_NS = 10;

  localparam int NUM_SAMPLES = 200;    // steady-state valid_out intervals to measure

  // ── DUT signals ────────────────────────────────────────────────────────────
  logic         clk = 0;
  logic         rst;
  logic         start;
  logic [255:0] pre_pow_hash;
  logic [63:0]  timestamp;
  logic [63:0]  nonce;
  logic [255:0] target;
  logic [255:0] hash_out;
  logic [63:0]  nonce_out;
  logic         valid_out;
  logic         found;
  logic [63:0]  found_nonce;
  logic [7:0]   found_work_id;

  // ── DUT ────────────────────────────────────────────────────────────────────
  core #(
      .CSHAKE_STAGES(CSHAKE_STAGES),
      .MATMUL_STAGES(MATMUL_STAGES),
      .CSHAKE_FOLDED(CSHAKE_FOLDED)
  ) uut (
      .clk          (clk),
      .rst          (rst),
      .start        (start),
      .pre_pow_hash (pre_pow_hash),
      .timestamp    (timestamp),
      .nonce        (nonce),
      .target       (target),
      .hash_out     (hash_out),
      .nonce_out    (nonce_out),
      .valid_out    (valid_out),
      .found        (found),
      .found_nonce  (found_nonce),
      .found_work_id(found_work_id)
  );

  always #(CLK_PERIOD_NS / 2) clk = ~clk;

  // ── Plusarg knobs ──────────────────────────────────────────────────────────
  integer clk_mhz = 500;

  // Free-running edge counter, independent of any loop/iteration numbering.
  integer edge_ctr = 0;
  always @(posedge clk) edge_ctr <= edge_ctr + 1;

  // ── Statistics ─────────────────────────────────────────────────────────────
  integer sample, last_edge, spacing;
  integer min_spacing, max_spacing;
  real    sum_spacing, avg_spacing;

  // ── Main ───────────────────────────────────────────────────────────────────
  initial begin
    // No VCD — not needed for a throughput measurement.

    void'($value$plusargs("clk_mhz=%d", clk_mhz));

    clk          = 0; rst = 1; start = 0;
    // Any fixed pre_pow_hash works -- content doesn't affect timing, only
    // that matrix generation has something to chew on.
    pre_pow_hash = 256'hdeadbeefcafebabe0000000000000000000000000000000000000000000001;
    timestamp    = 64'h0;
    nonce        = 64'h0;
    target       = '0;   // never satisfied -- found/hit doesn't gate throughput

    repeat (3) @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    $display("");
    $display("═══════════════════════════════════════════════════════════════");
    $display(" core  —  Throughput Benchmark");
    $display("───────────────────────────────────────────────────────────────");
    $display("  Clock    : %0d MHz (assumed for MH/s)", clk_mhz);
    $display("  Pipeline : CSHAKE_STAGES=%0d MATMUL_STAGES=%0d CSHAKE_FOLDED=%0d",
             CSHAKE_STAGES, MATMUL_STAGES, CSHAKE_FOLDED);
    $display("  N_MAX    : %0d cycles/admit (design-fixed once streaming)", uut.N_MAX);
    $display("───────────────────────────────────────────────────────────────");

    // Wait for the one-time block load (matrix gen + matmul table rebuild)
    // to finish and the first result to appear -- don't try to predict its
    // length, just watch for it like the correctness TB does.
    while (!valid_out) @(posedge clk);
    last_edge = edge_ctr;
    @(posedge clk);

    min_spacing = 32'h7fffffff;
    max_spacing = 0;
    sum_spacing = 0.0;
    sample      = 0;

    while (sample < NUM_SAMPLES) begin
      if (valid_out) begin
        spacing   = edge_ctr - last_edge;
        last_edge = edge_ctr;
        if (spacing < min_spacing) min_spacing = spacing;
        if (spacing > max_spacing) max_spacing = spacing;
        sum_spacing += real'(spacing);
        sample++;
      end
      @(posedge clk);
    end

    avg_spacing = sum_spacing / real'(NUM_SAMPLES);

    $display("  Samples  : %0d steady-state valid_out intervals", NUM_SAMPLES);
    $display("  Spacing  : min=%0d  max=%0d  avg=%.4f cycles/hash", min_spacing, max_spacing, avg_spacing);
    if (min_spacing != max_spacing)
      $display("  WARNING: spacing is not constant -- expected exactly N_MAX every interval");
    $display("  Throughput   : %.6f H/cycle  (%.4f cycles/hash, %.2f MH/s @ %0d MHz)",
             1.0 / avg_spacing, avg_spacing, real'(clk_mhz) / avg_spacing, clk_mhz);
    $display("  Real MH/s    = Fmax / N_MAX  ->  measure Fmax via synthesis");
    $display("═══════════════════════════════════════════════════════════════");

    $finish;
  end

  initial begin
    #5000000;
    $fatal(1, "FAIL: global timeout");
  end

endmodule
