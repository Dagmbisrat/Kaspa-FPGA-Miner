`timescale 1ns / 1ps
//
// throughput_tb.sv — Throughput benchmark for cshake256_pipelined_core
//
// Sweeps a set of batch sizes, sending each as back-to-back valid_in pulses.
// Counts clock edges from the first sampling edge until the last valid_out
// assertion, so the measurement is correct regardless of PIPE_DEPTH vs batch.
//
// For every batch reports:
//   - total cycles (first sampling edge → last valid_out edge)
//   - measured hashes/cycle
//   - MH/s at the assumed clock frequency
//
// Summary reports min/max/avg across all batches and the ideal steady-state rate.
//
// Plusarg overrides:
//   +clk_mhz=N   assumed clock for MH/s display  (default 500)
//   +s_value=N   hash mode: 1=HeavyHash, 0=POW   (default 1)

module throughput_tb;

  // ── Parameters ──────────────────────────────────────────────────────────────
  parameter int PIPE_DEPTH    = 26;
  parameter int CLK_PERIOD_NS = 10;

  // Batch sizes to sweep (number of back-to-back hashes per run)
  localparam int NUM_BATCHES = 7;
  int batch_sizes [NUM_BATCHES] = '{32, 128, 512, 2048, 8192, 32768, 131072};

  // ── DUT signals ─────────────────────────────────────────────────────────────
  logic         clk;
  logic         rst;
  logic [639:0] data_in;
  logic         data_80byte;
  logic         s_value;
  logic         valid_in;
  logic [255:0] hash_out;
  logic         valid_out;

  // ── DUT ─────────────────────────────────────────────────────────────────────
  cshake256_pipelined_core uut (
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

  // ── Statistics ───────────────────────────────────────────────────────────────
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
    $display("  Pipeline : %0d stages", PIPE_DEPTH);
    $display("───────────────────────────────────────────────────────────────");
    $display("  %8s  %8s  %12s  %10s", "Batch", "Cycles", "H/cycle", "MH/s");
    $display("───────────────────────────────────────────────────────────────");

    for (bi = 0; bi < NUM_BATCHES; bi++) begin
      automatic int n          = batch_sizes[bi];
      automatic int sent       = 0;
      automatic int out_count  = 0;
      automatic int cycle_count = 0;

      // ── Send n inputs, count cycles until all n outputs seen ───────────────
      // First input: assert valid_in, wait for the sampling posedge.
      // cycle_count starts at 0 on that edge and increments every posedge after.
      data_in[63:0] = 64'h0;
      sent = 1;
      #1 valid_in = 1;
      @(posedge clk);  // cycle 0 — first input sampled here

      forever begin
        @(posedge clk);
        cycle_count++;

        // Count this cycle's output before driving next input so we break on
        // the exact edge where the last hash_out is valid.
        if (valid_out) begin
          out_count++;
          if (out_count == n) break;
        end

        // Drive next input if we still have some to send
        if (sent < n) begin
          data_in[63:0] = 64'(sent);
          sent++;
          if (sent == n) begin
            // Last input has been applied; deassert valid_in next cycle
            #1 valid_in = 0;
            data_in = '0;
          end
        end
      end

      // Ensure valid_in is deasserted (in case n was reached before all sent)
      valid_in = 0;
      data_in  = '0;

      throughput = real'(n) / real'(cycle_count);

      $display("  %8d  %8d  %12.6f  %10.2f",
               n, cycle_count, throughput, throughput * real'(clk_mhz));

      if (throughput < min_tp) min_tp = throughput;
      if (throughput > max_tp) max_tp = throughput;
      sum_tp += throughput;

      // drain before next batch
      repeat (4) @(posedge clk);
    end

    // ── Summary ───────────────────────────────────────────────────────────────
    $display("───────────────────────────────────────────────────────────────");
    $display("  Min throughput : %.6f H/cycle  (%.2f MH/s)",
             min_tp, min_tp * real'(clk_mhz));
    $display("  Max throughput : %.6f H/cycle  (%.2f MH/s)",
             max_tp, max_tp * real'(clk_mhz));
    $display("  Avg throughput : %.6f H/cycle  (%.2f MH/s)",
             sum_tp / real'(NUM_BATCHES), sum_tp / real'(NUM_BATCHES) * real'(clk_mhz));
    $display("  Ideal (filled) : 1.000000 H/cycle  (%0d.00 MH/s)", clk_mhz);
    $display("  Fill overhead  : %0d cycles / batch  (PIPE_DEPTH-1 = %0d)",
             PIPE_DEPTH - 1, PIPE_DEPTH - 1);
    $display("═══════════════════════════════════════════════════════════════");

    $finish;
  end

endmodule
