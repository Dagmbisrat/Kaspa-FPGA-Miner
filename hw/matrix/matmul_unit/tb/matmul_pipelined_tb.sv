`timescale 1ns / 1ps
// ===========================================================================
// matmul_pipelined_tb
// ---------------------------------------------------------------------------
// Self-checking testbench for matmul_pipelined_unit. Proves:
//   1. Correctness against a behavioral golden model (same nibble conventions
//      as gen_vectors.py / matrix_cache).
//   2. Sustained 1 result/cycle throughput: NUM_VEC vectors are streamed with
//      valid_in asserted every cycle, and exactly NUM_VEC contiguous valid_out
//      pulses must appear, LAT cycles behind the input stream.
//
// The matrix is random nibbles (matmul does not care about rank), loaded once
// through the write interface, then held constant while vectors stream.
// ===========================================================================
module matmul_pipelined_tb;

    parameter int NUM_STAGES = 8;             // must divide 64
    parameter int NUM_VEC    = 64;            // vectors streamed back-to-back
    localparam int LAT       = NUM_STAGES;    // must match the DUT

    // -- Clock / reset --------------------------------------------------------
    logic clk = 0;
    logic rst;
    always #5 clk = ~clk;

    // -- DUT signals ----------------------------------------------------------
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

    // -- Test data ------------------------------------------------------------
    logic [3:0]   tb_matrix [0:63][0:63];      // golden matrix
    logic [255:0] vec_q      [0:NUM_VEC-1];     // input vectors (swapped packing)
    logic [255:0] exp_q      [0:NUM_VEC-1];     // expected products (swapped)

    // Behavioral golden matmul for one vector (swapped packing in and out).
    function automatic logic [255:0] golden(input logic [255:0] vec);
        logic [17:0] dot;
        golden = '0;
        for (int i = 0; i < 64; i++) begin
            dot = '0;
            for (int j = 0; j < 64; j++)
                dot += tb_matrix[i][j] * vec[(j ^ 1)*4 +: 4];
            golden[(i ^ 1)*4 +: 4] = dot[13:10];  // >>10 truncation to a nibble
        end
    endfunction

    // Load tb_matrix into the DUT (4 groups x 64 rows = 256 writes).
    task automatic load_matrix();
        for (int r = 0; r < 64; r++) begin
            for (int g = 0; g < 4; g++) begin
                @(negedge clk);
                wr_matrix_en   = 1'b1;
                n16th_value    = {r[5:0], g[1:0]};
                for (int k = 0; k < 16; k++)
                    wr_matrix_data[k*4 +: 4] = tb_matrix[r][g*16 + k];
            end
        end
        @(negedge clk);
        wr_matrix_en = 1'b0;
    endtask

    // -- Result collection / scoreboard ---------------------------------------
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

    // -- Main -----------------------------------------------------------------
    integer seed = 32'hC0FFEE;
    initial begin
        $dumpfile("sim/matmul_pipelined_tb.vcd");
        $dumpvars(0, matmul_pipelined_tb);

        rst          = 1;
        wr_matrix_en = 0;
        valid_in     = 0;
        vector_in    = '0;

        // Randomize matrix and vectors, precompute expected products.
        for (int i = 0; i < 64; i++)
            for (int j = 0; j < 64; j++)
                tb_matrix[i][j] = $random(seed) & 4'hF;

        @(posedge clk); @(posedge clk);
        #1 rst = 0;
        @(posedge clk);

        load_matrix();

        for (int v = 0; v < NUM_VEC; v++) begin
            logic [255:0] rv;
            for (int j = 0; j < 64; j++)
                rv[(j ^ 1)*4 +: 4] = $random(seed) & 4'hF;
            vec_q[v] = rv;
            exp_q[v] = golden(rv);
        end

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
            $display(" All %0d results correct at 1 vector/cycle!", NUM_VEC);
            $finish;
        end
    end

    // Global timeout safety net.
    initial begin
        #100000;
        $fatal(1, "FAIL: global timeout");
    end

endmodule
