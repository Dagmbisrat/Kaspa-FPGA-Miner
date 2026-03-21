`timescale 1ns / 1ps

module core_bench_tb;

// ---- Parameters -------------------------------------------------------
parameter real CLK_PERIOD_NS = 10.0;        // 100 MHz default
parameter real CLK_FREQ_MHZ  = 1000.0 / CLK_PERIOD_NS;
parameter int  NUM_RUNS      = 50;
// -----------------------------------------------------------------------

logic         clk;
logic         rst;
logic         start;
logic [255:0] pre_pow_hash;
logic [63:0]  timestamp;
logic [63:0]  nonce;
logic [255:0] hash_out;
logic         done;

core uut (
    .clk         (clk),
    .rst         (rst),
    .start       (start),
    .pre_pow_hash(pre_pow_hash),
    .timestamp   (timestamp),
    .nonce       (nonce),
    .hash_out    (hash_out),
    .done        (done)
);

always #(CLK_PERIOD_NS / 2.0) clk = ~clk;

// ---- Bench variables --------------------------------------------------
longint unsigned start_cycle, end_cycle;
longint unsigned total_cycles;
longint unsigned cycle_counter;
real             avg_latency_cycles;
real             throughput_hps;

// Free-running cycle counter
always_ff @(posedge clk)
    if (rst) cycle_counter <= 0;
    else      cycle_counter <= cycle_counter + 1;

// ---- Task: run one hash, reset between runs (cache wiped) -------------
task automatic run_core_wReset(
    input  logic [255:0] ppow,
    input  logic [63:0]  ts,
    input  logic [63:0]  nc,
    output longint unsigned latency,
    output logic [255:0] captured_hash
);
    longint unsigned s, e;
    pre_pow_hash = ppow;
    timestamp    = ts;
    nonce        = nc;

    @(posedge clk);
    #1 start = 1;
    s = cycle_counter;
    @(posedge clk);
    #1 start = 0;

    wait (done === 1'b1);
    e = cycle_counter;
    #1;
    latency       = e - s;
    captured_hash = hash_out;

    // Reset clears the matrix cache 
    #1 rst = 1;
    @(posedge clk);
    #1 rst = 0;
    @(posedge clk);
endtask

// ---- Task: run one hash, NO reset — cache stays warm ------------------
task automatic run_core_woReset(
    input  logic [255:0] ppow,
    input  logic [63:0]  ts,
    input  logic [63:0]  nc,
    output longint unsigned latency,
    output logic [255:0] captured_hash
);
    longint unsigned s, e;
    pre_pow_hash = ppow;
    timestamp    = ts;
    nonce        = nc;

    @(posedge clk);
    #1 start = 1;
    s = cycle_counter;
    @(posedge clk);
    #1 start = 0;

    wait (done === 1'b1);
    e = cycle_counter;
    #1;
    latency       = e - s;
    captured_hash = hash_out;

    // FSM returns to IDLE on its own — no reset needed
    @(posedge clk);
endtask

// -----------------------------------------------------------------------
initial begin
    $dumpfile("sim/core_bench_tb.vcd");
    $dumpvars(0, core_bench_tb);

    clk          = 0;
    rst          = 1;
    start        = 0;
    pre_pow_hash = '0;
    timestamp    = 64'h0000_0000_6789_ABCD;
    nonce        = '0;
    total_cycles = 0;

    @(posedge clk);
    #1 rst = 0;
    @(posedge clk);

    // ==================================================================
    // Case 1: fixed pre_pow_hash, varying nonce
    // ==================================================================
    $display("");
    $display("==============================================");
    $display(" Core Benchmark  —  CLK = %.1f MHz", CLK_FREQ_MHZ);
    $display("==============================================");
    $display("");
    $display("[Case 1] Fixed pre_pow_hash — nonce sweep (%0d runs)", NUM_RUNS);
    $display("  run 0: cold cache (matrix gen runs), runs >0 have a cache hit (matrix gen skipped)");
    $display("----------------------------------------------");

    total_cycles = 0;
    for (int run = 0; run < NUM_RUNS; run++) begin
        longint unsigned lat;
        logic [255:0] h;
        run_core_woReset(
            256'hDEADBEEFCAFEBABE_0123456789ABCDEF_FEDCBA9876543210_1122334455667788,
            64'h0000_0000_6789_ABCD,
            64'(run),
            lat, h
        );
        total_cycles += lat;
        $display("  run %2d | nonce=%016h | latency=%0d cycles | hash=%h",
                 run, 64'(run), lat, h);
    end

    avg_latency_cycles = real'(total_cycles) / real'(NUM_RUNS);
    throughput_hps     = (CLK_FREQ_MHZ * 1.0e6) / avg_latency_cycles;
    $display("----------------------------------------------");
    $display("  Avg latency : %.1f cycles", avg_latency_cycles);
    $display("  Hash rate   : %.2f hashes/sec", throughput_hps);

    // ==================================================================
    // Case 2: Sims new pre_pow_hash every run
    //   Forces full matrix regeneration each time — worst case latency.
    // ==================================================================
    $display("");
    $display("[Case 2] Simulate a new pre_pow_hash every run (%0d runs)", NUM_RUNS);
    $display("  (matrix cache miss every run — worst case)");
    $display("----------------------------------------------");

    total_cycles = 0;
    for (int run = 0; run < NUM_RUNS; run++) begin
        longint unsigned lat;
        logic [255:0] ppow, h;
        ppow = {192'hDEADBEEFCAFEBABE_0123456789ABCDEF_FEDCBA987654, 64'(run)};
        run_core_wReset(ppow, 64'h0000_0000_6789_ABCD, 64'(run), lat, h);
        total_cycles += lat;
        $display("  run %2d | pre_pow_hash[63:0]=%016h | latency=%0d cycles | hash=%h",
                 run, 64'(run), lat, h);
    end

    avg_latency_cycles = real'(total_cycles) / real'(NUM_RUNS);
    throughput_hps     = (CLK_FREQ_MHZ * 1.0e6) / avg_latency_cycles;
    $display("----------------------------------------------");
    $display("  Avg latency : %.1f cycles", avg_latency_cycles);
    $display("  Hash rate   : %.2f hashes/sec", throughput_hps);

    $display("");
    $display("==============================================");
    $finish;
end

endmodule
