`timescale 1ns / 1ps
// ===========================================================================
// core_tb — streaming kHeavyHash core testbench
// ---------------------------------------------------------------------------
// The core streams nonces (nonce_ctr increments internally from the base nonce)
// through cshake1 -> matmul -> xor -> cshake2. This TB drives NUM_PHASES blocks
// and checks every streamed hash_out against the Python reference, matching each
// result by its nonce_out tag (so it is robust to fill latency / block seams).
//
// Phases (must match sim/gen_vectors.py):
//   0: block A, fresh matrix generation
//   1: block A again (cache-hit, matrix reused, new nonce base)
//   2: block B, new matrix generation (block switch)
// ===========================================================================
module core_tb;

    localparam int NVEC       = 32;
    localparam int NUM_PHASES = 3;
    localparam int WPH        = 6 + NVEC*4;      // 64-bit words per phase
    localparam int TOTAL_W    = NUM_PHASES*WPH;

    logic         clk = 0;
    logic         rst;
    logic         start;
    logic [255:0] pre_pow_hash;
    logic [63:0]  timestamp;
    logic [63:0]  nonce;
    logic [255:0] hash_out;
    logic [63:0]  nonce_out;
    logic         valid_out;

    core uut (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .pre_pow_hash (pre_pow_hash),
        .timestamp    (timestamp),
        .nonce        (nonce),
        .hash_out     (hash_out),
        .nonce_out    (nonce_out),
        .valid_out    (valid_out)
    );

    always #5 clk = ~clk;







    logic [63:0] mem [0:TOTAL_W-1];

    // Parsed per-phase data.
    logic [255:0] ph_pph  [0:NUM_PHASES-1];
    logic [63:0]  ph_ts   [0:NUM_PHASES-1];
    logic [63:0]  ph_base [0:NUM_PHASES-1];
    logic [255:0] ph_exp  [0:NUM_PHASES-1][0:NVEC-1];

    integer pass_count = 0;
    integer fail_count = 0;

    function automatic logic [255:0] rd256(input int off);
        rd256 = {mem[off+3], mem[off+2], mem[off+1], mem[off+0]};
    endfunction

    task automatic run_phase(input int p);
        logic [NVEC-1:0] got;
        integer nchecked;
        integer guard;
        logic [63:0] rel;
        int ri;
        begin
            got      = '0;
            nchecked = 0;
            guard    = 0;

            @(negedge clk);
            start        = 1'b1;
            pre_pow_hash = ph_pph[p];
            timestamp    = ph_ts[p];
            nonce        = ph_base[p];
            @(negedge clk);
            start        = 1'b0;

            while (nchecked < NVEC && guard < 60000) begin
                @(posedge clk);
                if (valid_out) begin
                    rel = nonce_out - ph_base[p];
                    if (rel < NVEC && !got[rel[$clog2(NVEC)-1:0]]) begin
                        ri = rel[$clog2(NVEC)-1:0];
                        got[ri] = 1'b1;
                        nchecked = nchecked + 1;
                        if (hash_out === ph_exp[p][ri]) begin
                            pass_count = pass_count + 1;
                        end else begin
                            fail_count = fail_count + 1;
                            $display("  FAIL phase %0d nonce %0d", p, nonce_out);
                            $display("    expected: %h", ph_exp[p][ri]);
                            $display("    got:      %h", hash_out);
                        end
                    end
                end
                guard = guard + 1;
            end

            if (nchecked < NVEC) begin
                $display("  TIMEOUT phase %0d: only %0d/%0d results", p, nchecked, NVEC);
                fail_count = fail_count + 1;
            end else begin
                $display("  phase %0d done (%0d nonces)", p, NVEC);
            end
        end
    endtask

    integer p, i, off;
    initial begin
        $dumpfile("sim/core_tb.vcd");
        $dumpvars(0, core_tb);

        $readmemh("sim/expected_vectors.mem", mem);

        for (p = 0; p < NUM_PHASES; p = p + 1) begin
            off          = p*WPH;
            ph_pph[p]    = rd256(off);
            ph_ts[p]     = mem[off+4];
            ph_base[p]   = mem[off+5];
            for (i = 0; i < NVEC; i = i + 1)
                ph_exp[p][i] = rd256(off + 6 + i*4);
        end

        rst          = 1'b1;
        start        = 1'b0;
        pre_pow_hash = '0;
        timestamp    = '0;
        nonce        = '0;

        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        @(posedge clk);

        for (p = 0; p < NUM_PHASES; p = p + 1)
            run_phase(p);

        $display("");
        $display("=================================================");
        $display(" phases = %0d,  nonces/phase = %0d", NUM_PHASES, NVEC);
        $display(" %0d PASS, %0d FAIL", pass_count, fail_count);
        $display("=================================================");

        if (fail_count > 0)
            $fatal(1, "FAIL: %0d mismatch(es)", fail_count);
        else begin
            $display(" All %0d streamed hashes match the Python reference!",
                     pass_count);
            $finish;
        end
    end

    initial begin
        #5000000;
        $fatal(1, "FAIL: global timeout");
    end

endmodule
