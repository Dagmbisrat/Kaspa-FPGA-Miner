`timescale 1ns / 1ps

// latency_tb.sv
//
// Measures matrix_generator latency across all test vectors.
// Per test reports:
//   - total cycles (start → done)
//   - generation-phase cycles (in GENERATE_MATRIX state)
//   - rank-check-phase cycles (in RANK_CHECK state)
//   - whether the seed required regen (gen cycles > 256)
//
// Summary reports min/max/avg for each phase across all valid tests.

module latency_tb;

  // ── Parameters ──────────────────────────────────────────────────────────────
  parameter NUM_TESTS = 49;
  parameter TIMEOUT   = 8000;   // max cycles per test (~13 regen attempts)

  // ── DUT signals ─────────────────────────────────────────────────────────────
  logic          clk = 0;
  logic          rst;
  logic          start;
  logic [255:0]  PrePowHash;
  logic          done;

  logic          wr_matrix_en;
  logic          wr_PrePowHash_en;
  logic [7:0]    n16th_value;
  logic [63:0]   wr_matrix_data;
  logic          rd_en;
  logic [5:0]    rd_row;
  logic [255:0]  rd_row_data;
  logic [255:0]  rd_PrePowHash;

  // ── Instantiation ────────────────────────────────────────────────────────────
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

  always #5 clk = ~clk;

  // ── Vector storage ───────────────────────────────────────────────────────────
  logic [255:0] vectors [0:NUM_TESTS*65-1];

  // ── FSM state encoding (must match matrix_generator.sv) ─────────────────────
  localparam FSM_GENERATE_MATRIX = 3'd2;
  localparam FSM_RANK_CHECK      = 3'd3;

  // ── Statistics ───────────────────────────────────────────────────────────────
  integer total_cycles, gen_cycles, rank_cycles;
  integer min_total, max_total, sum_total;
  integer min_gen,   max_gen,   sum_gen;
  integer min_rank,  max_rank,  sum_rank;
  integer valid_tests, timeout_count, regen_count;
  integer test_idx, base;

  // ── Main ─────────────────────────────────────────────────────────────────────
  initial begin
    $dumpfile("sim/latency_tb.vcd");
    $dumpvars(0, latency_tb);

    $readmemh("sim/expected_matrix.mem", vectors);

    rst   = 1;
    start = 0;
    PrePowHash = '0;

    min_total = 999999; max_total = 0; sum_total = 0;
    min_gen   = 999999; max_gen   = 0; sum_gen   = 0;
    min_rank  = 999999; max_rank  = 0; sum_rank  = 0;
    valid_tests   = 0;
    timeout_count = 0;
    regen_count   = 0;

    @(posedge clk); @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    for (test_idx = 0; test_idx < NUM_TESTS; test_idx++) begin
      base = test_idx * 65;

      if (vectors[base] === 256'bx) begin
        $display("Test %0d: no vector, skipping", test_idx);
        continue;
      end

      PrePowHash   = vectors[base];
      total_cycles = 0;
      gen_cycles   = 0;
      rank_cycles  = 0;

      // Assert start then count from the posedge the FSM samples it.
      // Deassert inside the first iteration so start is a one-cycle pulse.
      @(posedge clk);
      #1 start = 1;

      while (total_cycles < TIMEOUT) begin
        @(posedge clk);
        total_cycles++;
        if (total_cycles == 1) #1 start = 0;
        case (uut.fsm_current_state)
          FSM_GENERATE_MATRIX: gen_cycles++;
          FSM_RANK_CHECK:      rank_cycles++;
        endcase
        if (done) break;
      end

      if (!done) begin
        $display("Test %0d  [%h]: TIMEOUT after %0d cycles",
                 test_idx, PrePowHash[63:0], TIMEOUT);
        timeout_count++;
        @(posedge clk); @(posedge clk);
        continue;
      end

      // gen_cycles > 256 means more than one GENERATE_MATRIX pass (regen)
      if (gen_cycles > 256) regen_count++;

      $display("Test %0d  total=%4d  gen=%4d  rank=%4d%s",
               test_idx, total_cycles, gen_cycles, rank_cycles,
               gen_cycles > 256 ? "  [REGEN]" : "");

      if (total_cycles < min_total) min_total = total_cycles;
      if (total_cycles > max_total) max_total = total_cycles;
      sum_total += total_cycles;

      if (gen_cycles < min_gen) min_gen = gen_cycles;
      if (gen_cycles > max_gen) max_gen = gen_cycles;
      sum_gen += gen_cycles;

      if (rank_cycles < min_rank) min_rank = rank_cycles;
      if (rank_cycles > max_rank) max_rank = rank_cycles;
      sum_rank += rank_cycles;

      valid_tests++;

      @(posedge clk); @(posedge clk);
    end

    // ── Summary ──────────────────────────────────────────────────────────────
    $display("");
    $display("═══════════════════════════════════════════════════════");
    $display(" Latency Summary  (%0d tests, %0d timeout, %0d regen)",
             valid_tests, timeout_count, regen_count);
    $display("───────────────────────────────────────────────────────");
    $display("           Min     Max     Avg");
    if (valid_tests > 0) begin
      $display(" Total :  %5d   %5d   %5d", min_total, max_total, sum_total / valid_tests);
      $display(" Gen   :  %5d   %5d   %5d", min_gen,   max_gen,   sum_gen   / valid_tests);
      $display(" Rank  :  %5d   %5d   %5d", min_rank,  max_rank,  sum_rank  / valid_tests);
    end
    $display("═══════════════════════════════════════════════════════");

    $finish;
  end

endmodule
