`timescale 1ns / 1ps
// work_controller_tb -- register-bus testbench, no transport/PHY: drives
// addr/wdata/we/re directly against work_controller wired to a REAL core
// (unlike uart_if_tb's stand-in memory -- work_controller is the thing
// actually sitting in front of the hashing logic, so it's tested against
// the real thing). See docs/work_controller.md, section 8.
//
// Test 1 reuses hw/core/sim/expected_vectors.mem (phase 0 only) to check
// that loading a job through 18 word-writes + one CTRL write produces the
// bit-exact same streamed hashes and found/target-compare behavior as
// core_tb.sv's direct port-driven check_phase.
//
// Tests 2/3 exercise the found FIFO on its own terms with synthetic
// all-ones/all-zeros targets (guaranteed find / guaranteed no-find), reusing
// the already-cached matrix from test 1's block so no regeneration is
// needed. Test 2's saturation check does not assert which entries survive
// an overflow -- work_controller.sv documents that as an accepted
// simplification (unconditional push, oldest entry silently overwritten),
// not a guaranteed ordering.
module work_controller_tb;

    // Forwarded to `core` (override via -G). Defaults to a slow FOLDED config
    // on purpose: test2's ordering check pops entries over the register bus
    // (several cycles per read) while `core` keeps admitting/finding in the
    // background. The default unfolded core finds every single cycle, which
    // no register-bus read sequence can keep pace with; folded with
    // CSHAKE_STAGES=1 admits only once every 26 cycles, comfortably slower
    // than a handful of register reads.
    parameter int CSHAKE_STAGES = 1;
    parameter int MATMUL_STAGES = 8;
    parameter bit CSHAKE_FOLDED = 1'b1;

    localparam int NVEC = 32;   // must match core_tb.sv / gen_vectors.py
    localparam int FOUND_DEPTH = 4;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst;

    logic [7:0]  addr;
    logic [31:0] wdata;
    logic        we, re;
    logic [31:0] rdata;

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

    work_controller #(.FOUND_DEPTH(FOUND_DEPTH)) dut (
        .clk(clk), .rst(rst),
        .addr(addr), .wdata(wdata), .we(we), .re(re), .rdata(rdata),
        .start(start), .pre_pow_hash(pre_pow_hash), .timestamp(timestamp),
        .nonce(nonce), .target(target),
        .found(found), .found_nonce(found_nonce), .found_work_id(found_work_id)
    );

    core #(
        .CSHAKE_STAGES(CSHAKE_STAGES),
        .MATMUL_STAGES(MATMUL_STAGES),
        .CSHAKE_FOLDED(CSHAKE_FOLDED)
    ) uut (
        .clk(clk), .rst(rst),
        .start(start),
        .pre_pow_hash(pre_pow_hash),
        .timestamp(timestamp),
        .nonce(nonce),
        .target(target),
        .hash_out(hash_out),
        .nonce_out(nonce_out),
        .valid_out(valid_out),
        .found(found),
        .found_nonce(found_nonce),
        .found_work_id(found_work_id)
    );

    int pass_count = 0;
    int fail_count = 0;

    task automatic check(input bit cond, input string msg);
        begin
            if (cond) pass_count++;
            else begin
                fail_count++;
                $display("FAIL: %s", msg);
            end
        end
    endtask

    // ======================================================================
    // Register-bus driver tasks (this bench acting as the transport adapter)
    // ======================================================================
    task automatic reg_write(input logic [7:0] a, input logic [31:0] d);
        begin
            @(negedge clk);
            addr = a; wdata = d; we = 1'b1;
            @(negedge clk);
            we = 1'b0;
        end
    endtask

    task automatic reg_read(input logic [7:0] a, output logic [31:0] d);
        begin
            @(negedge clk);
            addr = a; re = 1'b1;
            @(negedge clk);
            re = 1'b0;
            d = rdata;
        end
    endtask

    localparam logic [7:0] ADDR_CTRL         = 8'h00;
    localparam logic [7:0] ADDR_PPH0         = 8'h08;
    localparam logic [7:0] ADDR_TS0          = 8'h28;
    localparam logic [7:0] ADDR_TGT0         = 8'h30;
    localparam logic [7:0] ADDR_NONCE0       = 8'h50;
    localparam logic [7:0] ADDR_FOUND_NONCE0 = 8'h58;
    localparam logic [7:0] ADDR_FOUND_NONCE1 = 8'h5C;
    localparam logic [7:0] ADDR_FOUND_WORKID = 8'h60;
    localparam logic [7:0] ADDR_FOUND_COUNT  = 8'h64;

    task automatic load_job(input logic [255:0] pph, input logic [63:0] ts,
                             input logic [255:0] tgt, input logic [63:0] nb);
        int i;
        begin
            for (i = 0; i < 8; i++) reg_write(8'(ADDR_PPH0 + i*4), pph[32*i +: 32]);
            for (i = 0; i < 2; i++) reg_write(8'(ADDR_TS0  + i*4), ts[32*i +: 32]);
            for (i = 0; i < 8; i++) reg_write(8'(ADDR_TGT0 + i*4), tgt[32*i +: 32]);
            for (i = 0; i < 2; i++) reg_write(8'(ADDR_NONCE0 + i*4), nb[32*i +: 32]);
            reg_write(ADDR_CTRL, 32'h1);
        end
    endtask

    task automatic pop_found(output logic [63:0] pnonce, output logic [7:0] pworkid);
        logic [31:0] w0, w1, w2;
        begin
            reg_read(ADDR_FOUND_NONCE0, w0);
            reg_read(ADDR_FOUND_NONCE1, w1);
            reg_read(ADDR_FOUND_WORKID, w2);
            pnonce  = {w1, w0};
            pworkid = w2[7:0];
        end
    endtask

    task automatic read_found_count(output int cnt);
        logic [31:0] w;
        begin
            reg_read(ADDR_FOUND_COUNT, w);
            cnt = int'(w);
        end
    endtask

    // ======================================================================
    // Test 1: register-loaded job vs. Python reference (mirrors core_tb's
    // check_phase, but the job arrives through the register bus).
    // ======================================================================
    localparam int WPH        = 6 + NVEC*4 + 4;  // words per phase; matches gen_vectors.py's layout
    localparam int NUM_PHASES = 3;                // must match gen_vectors.py; only phase 0 is used here
    logic [63:0] mem [0:NUM_PHASES*WPH-1];         // sized to the whole file -- $readmemh errors if the
                                                    // file has more words than a start/finish-bounded read allows
    logic [255:0] p_pph;
    logic [63:0]  p_ts, p_base;
    logic [255:0] p_exp [0:NVEC-1];
    logic [255:0] p_tgt;

    function automatic logic [255:0] rd256(input logic [63:0] m[], input int off);
        rd256 = {m[off+3], m[off+2], m[off+1], m[off+0]};
    endfunction

    task automatic test1();
        logic [NVEC-1:0] got, fnd;
        int nchecked, guard, ri;
        logic [63:0] rel;
        bit exp_pass;
        begin
            $display("Test 1: register-loaded job vs. Python reference (phase 0, %0d nonces)", NVEC);
            load_job(p_pph, p_ts, p_tgt, p_base);

            got = '0; fnd = '0; nchecked = 0; guard = 0;
            while (nchecked < NVEC && guard < 60000) begin
                @(posedge clk);
                if (valid_out) begin
                    rel = nonce_out - p_base;
                    if (rel < NVEC && !got[rel[$clog2(NVEC)-1:0]]) begin
                        ri = rel[$clog2(NVEC)-1:0];
                        got[ri] = 1'b1;
                        nchecked++;
                        check(hash_out === p_exp[ri], $sformatf("test1: hash mismatch at nonce %0d", nonce_out));
                    end
                end
                if (found) begin
                    rel = found_nonce - p_base;
                    if (rel < NVEC) fnd[rel[$clog2(NVEC)-1:0]] = 1'b1;
                end
                guard++;
            end
            repeat (4) begin
                @(posedge clk);
                if (found) begin
                    rel = found_nonce - p_base;
                    if (rel < NVEC) fnd[rel[$clog2(NVEC)-1:0]] = 1'b1;
                end
            end

            check(nchecked == NVEC, "test1: did not receive all NVEC streamed hashes");
            for (int k = 0; k < NVEC; k++) begin
                exp_pass = (p_exp[k] <= p_tgt);
                check(exp_pass === fnd[k], $sformatf("test1: found mismatch at nonce %0d", p_base+k));
            end
        end
    endtask

    // ======================================================================
    // Tests 2/3: found-FIFO mechanics with synthetic targets. Reuses
    // p_pph/p_ts (already cached from test 1, no regen) with fresh nonce
    // bases and synthetic targets.
    // ======================================================================
    localparam int MAX_FINDS = FOUND_DEPTH + 2;   // largest batch any test waits for at once

    task automatic wait_for_finds(input int n, ref logic [63:0] out_nonce [0:MAX_FINDS-1],
                                   ref logic [7:0] out_workid [0:MAX_FINDS-1]);
        int cnt;
        begin
            cnt = 0;
            while (cnt < n) begin
                @(posedge clk);
                if (found) begin
                    out_nonce[cnt]  = found_nonce;
                    out_workid[cnt] = found_work_id;
                    cnt++;
                end
            end
        end
    endtask

    // Same as wait_for_finds but without capturing ground truth -- used
    // where a test only needs to know N finds happened, not what they were.
    task automatic wait_for_n_finds(input int n);
        int cnt;
        begin
            cnt = 0;
            while (cnt < n) begin
                @(posedge clk);
                if (found) cnt++;
            end
        end
    endtask

    task automatic test2();
        logic [63:0] gt_nonce [0:MAX_FINDS-1];
        logic [7:0]  gt_workid[0:MAX_FINDS-1];
        logic [63:0] popped_nonce;
        logic [7:0]  popped_workid;
        int cnt;
        begin
            $display("Test 2: found FIFO -- guaranteed find, ordering, and saturation");
            load_job(p_pph, p_ts, {256{1'b1}}, 64'h1000_0000);

            wait_for_finds(FOUND_DEPTH, gt_nonce, gt_workid);
            read_found_count(cnt);
            check(cnt == FOUND_DEPTH, "test2: FOUND_COUNT should equal FOUND_DEPTH after exactly DEPTH finds");

            // Pop only the first 2, leaving 2 pending for test3 to check against.
            for (int i = 0; i < 2; i++) begin
                pop_found(popped_nonce, popped_workid);
                check(popped_nonce == gt_nonce[i], $sformatf("test2: popped nonce %0d != expected %0d", popped_nonce, gt_nonce[i]));
                check(popped_workid == gt_workid[i], "test2: popped work_id mismatch");
            end
            read_found_count(cnt);
            check(cnt == FOUND_DEPTH-2, "test2: FOUND_COUNT should be DEPTH-2 after popping 2");

            // Saturation: push DEPTH+2 more on top of the 2 still pending.
            // Contents aren't asserted post-overflow (documented simplification
            // in work_controller.sv) -- only that the count itself caps.
            // Deliberately left saturated (not drained) here -- test3 checks
            // that a new job's load sequence neither clears this nor lets it
            // grow past FOUND_DEPTH.
            wait_for_n_finds(FOUND_DEPTH+2);
            read_found_count(cnt);
            check(cnt == FOUND_DEPTH, "test2: FOUND_COUNT must saturate at FOUND_DEPTH, not grow past it");
        end
    endtask

    task automatic test3();
        logic [63:0] popped_nonce;
        logic [7:0]  popped_workid;
        int cnt_before, cnt;
        int i;
        begin
            $display("Test 3: new job doesn't disturb a stale FIFO, and target=0 finds nothing");
            read_found_count(cnt_before);
            check(cnt_before == FOUND_DEPTH, "test3: expected to start saturated from test2");

            // Loading job B (target=0) takes ~21 register writes; job A
            // (target=all-1s, work_id unchanged until this start) is still
            // live until the very last CTRL write, so a few more finds can
            // still land during this sequence -- but the FIFO is already
            // saturated, so that can only keep the count AT FOUND_DEPTH, not
            // grow it. That saturation is what makes this check race-free.
            load_job(p_pph, p_ts, 256'h0, 64'h2000_0000);
            read_found_count(cnt);
            check(cnt == FOUND_DEPTH, "test3: new job's start must not clear a stale found FIFO");

            // Now job B is fully active (new work_id): target=0 means
            // (hash<=0) never happens, so no further pushes -- count must
            // hold steady at FOUND_DEPTH across real streaming.
            for (i = 0; i < NVEC; i++) begin
                @(posedge clk);
                check(!found, "test3: unexpected found pulse against target=0");
            end
            read_found_count(cnt);
            check(cnt == FOUND_DEPTH, "test3: FOUND_COUNT must hold steady once job B is active");

            // Final drain: pop rate exceeds production rate (which is now
            // zero anyway), so this reaches empty -- exact contents aren't
            // asserted (post-saturation entries, per the documented caveat).
            i = 0;
            while (cnt != 0 && i < 20) begin
                pop_found(popped_nonce, popped_workid);
                read_found_count(cnt);
                i++;
            end
            check(cnt == 0, "test3: FOUND_COUNT should reach 0 once fully drained");
        end
    endtask

    // ======================================================================
    // Main sequence
    // ======================================================================
    integer i;
    initial begin
        $dumpfile("sim/work_controller_tb.vcd");
        $dumpvars(0, work_controller_tb);

        $readmemh("../core/sim/expected_vectors.mem", mem);
        p_pph  = rd256(mem, 0);
        p_ts   = mem[4];
        p_base = mem[5];
        for (i = 0; i < NVEC; i++) p_exp[i] = rd256(mem, 6 + i*4);
        p_tgt  = rd256(mem, 6 + NVEC*4);

        rst = 1'b1;
        addr = '0; wdata = '0; we = 1'b0; re = 1'b0;
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        @(posedge clk);

        test1();
        rst = 1'b1;
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        @(posedge clk);
        test2();
        test3();

        $display("");
        $display("=================================================");
        $display(" %0d PASS, %0d FAIL", pass_count, fail_count);
        $display("=================================================");

        if (fail_count > 0)
            $fatal(1, "FAIL: %0d check(s) failed", fail_count);
        else begin
            $display(" All checks passed!");
            $finish;
        end
    end

    initial begin
        #10_000_000;
        $fatal(1, "FAIL: global timeout");
    end

endmodule
