`timescale 1ns / 1ps
// ===========================================================================
// matmul_pipelined_tb
// ---------------------------------------------------------------------------
// Self-checking testbench for matmul_pipelined_unit. Matrix, vectors, and
// expected products come from sim/gen_vectors.py, which computes the golden
// results with the KHeavyHash Python reference (_matrix_vector_multiply) — so
// the RTL is checked against the same math as the production miner.
//
// Proves:
//   1. Correctness vs the Python reference (sim/expected_vectors.mem).
//   2. Sustained 1 result/cycle throughput: NUM_VEC vectors streamed with
//      valid_in high every cycle produce NUM_VEC contiguous valid_out pulses,
//      LAT cycles behind the input stream.
//
// expected_vectors.mem layout (256-bit words):
//   64 words       : matrix rows,   plain packing   nibble c   = M[row][c]
//   NUM_VEC words  : input vectors,  swapped packing nibble j^1 = v[j]
//   NUM_VEC words  : expected out,   swapped packing nibble i^1 = r[i]
// ===========================================================================
module matmul_pipelined_tb;

    parameter int NUM_STAGES = 8;             // must divide 64
    parameter int NUM_VEC    = 64;            // must match gen_vectors.py
    localparam int LAT       = NUM_STAGES;    // must match the DUT
    localparam int N         = 64;
    localparam int MEM_WORDS = N + 2*NUM_VEC;

    // -- Clock / reset ---------------------------------------------------------
    logic clk = 0;
    logic rst;
    always #5 clk = ~clk;

    // -- DUT signals -----------------------------------------------------------
    logic         wr_matrix_en;
    logic [7:0]   n16th_value;
    logic [63:0]  wr_matrix_data;
    logic [255:0] vector_in;
    logic         valid_in;
    logic [255:0] product_out;
    logic         valid_out;

    matmul_pipelined_unit #(.NUM_STAGES(NUM_STAGES)) dut (
        .clk            (clk),
        .rst            (rst),
        .wr_matrix_en   (wr_matrix_en),
        .n16th_value    (n16th_value),
        .wr_matrix_data (wr_matrix_data),
        .vector_in      (vector_in),
        .valid_in       (valid_in),
        .product_out    (product_out),
        .valid_out      (valid_out)
    );

    // -- Test data (loaded from the reference-generated .mem) -------------------
    logic [255:0] mem       [0:MEM_WORDS-1];
    logic [3:0]   tb_matrix [0:63][0:63];
    logic [255:0] vec_q     [0:NUM_VEC-1];
    logic [255:0] exp_q     [0:NUM_VEC-1];

    // Load tb_matrix into the DUT (4 groups x 64 rows = 256 writes).
    task automatic load_matrix();
        for (int r = 0; r < 64; r++) begin
            for (int g = 0; g < 4; g++) begin
                @(negedge clk);
                wr_matrix_en = 1'b1;
                n16th_value  = {r[5:0], g[1:0]};
                for (int k = 0; k < 16; k++)
                    wr_matrix_data[k*4 +: 4] = tb_matrix[r][g*16 + k];
            end
        end
        @(negedge clk);
        wr_matrix_en = 1'b0;
    endtask

    // -- Result collection / scoreboard ----------------------------------------
    integer out_idx    = 0;
    integer pass_count = 0;
    integer fail_count = 0;

    always @(posedge clk) begin
        if (!rst && valid_out) begin
            if (out_idx >= NUM_VEC) begin
                $display("  FAIL: extra valid_out beyond %0d results", NUM_VEC);
                fail_count++;
            end else if (product_out !== exp_q[out_idx]) begin
                $display("  FAIL: result %0d mismatch", out_idx);
                $display("    expected: %h", exp_q[out_idx]);
                $display("    got:      %h", product_out);
                fail_count++;
            end else begin
                pass_count++;
            end
            out_idx++;
        end
    end

    // -- Main ------------------------------------------------------------------
    initial begin
        $dumpfile("sim/matmul_pipelined_tb.vcd");
        $dumpvars(0, matmul_pipelined_tb);

        rst          = 1;
        wr_matrix_en = 0;
        valid_in     = 0;
        vector_in    = '0;

        // Load matrix, vectors and expected products from the reference file.
        $readmemh("sim/expected_vectors.mem", mem);
        for (int r = 0; r < 64; r++)
            for (int c = 0; c < 64; c++)
                tb_matrix[r][c] = mem[r][c*4 +: 4];
        for (int v = 0; v < NUM_VEC; v++) begin
            vec_q[v] = mem[N + v];
            exp_q[v] = mem[N + NUM_VEC + v];
        end

        @(posedge clk); @(posedge clk);
        #1 rst = 0;
        @(posedge clk);

        load_matrix();

        // Stream all vectors back-to-back, valid_in high every cycle.
        for (int v = 0; v < NUM_VEC; v++) begin
            @(negedge clk);
            valid_in  = 1'b1;
            vector_in = vec_q[v];
        end
        @(negedge clk);
        valid_in  = 1'b0;
        vector_in = '0;

        // Drain the pipeline.
        repeat (LAT + 4) @(posedge clk);

        $display("");
        $display("=================================================");
        $display(" NUM_STAGES = %0d,  LAT = %0d,  vectors = %0d",
                 NUM_STAGES, LAT, NUM_VEC);
        $display(" Received %0d result(s): %0d PASS, %0d FAIL",
                 out_idx, pass_count, fail_count);
        $display("=================================================");

        if (out_idx !== NUM_VEC) begin
            $fatal(1, "FAIL: throughput broken - got %0d results, expected %0d",
                   out_idx, NUM_VEC);
        end else if (fail_count > 0) begin
            $fatal(1, "FAIL: %0d result(s) mismatched", fail_count);
        end else begin
            $display(" All %0d results match the Python reference at 1 vector/cycle!",
                     NUM_VEC);
            $finish;
        end
    end

    // Global timeout safety net.
    initial begin
        #100000;
        $fatal(1, "FAIL: global timeout");
    end

endmodule
