`timescale 1ns / 1ps
// kaspa_miner_tb -- first end-to-end test across uart_if, work_controller,
// and core together. Only rx/tx touch the DUT, so this bench bit-bangs
// UART frames as the host (same approach as uart_if_tb.sv) to load a real
// job (pph/timestamp/nonce_base from hw/core/sim's Python-reference
// vectors, phase 0) and reads a real found nonce back out over the wire.
//
// Target is a synthetic all-ones value (guaranteed find on every admitted
// nonce), the same real-job-fields/synthetic-target substitution
// work_controller_tb.sv's test 2 already uses -- at UART speed a register
// poll round trip is thousands of cycles, far slower than core's admission
// rate, so the found FIFO (FOUND_DEPTH=4) is already saturated by the time
// the host can read it regardless of target; this just makes that
// deterministic instead of leaving it to chance. Only FOUND_COUNT reaching
// its cap, found_work_id, and each popped nonce being real/increasing are
// asserted -- exact post-saturation contents aren't (same documented
// simplification as work_controller_tb.sv's test 2).
module kaspa_miner_tb;

    parameter int CSHAKE_STAGES = 24;
    parameter int MATMUL_STAGES = 8;
    parameter bit CSHAKE_FOLDED = 1'b0;

    // Fast-sim values -- real hardware defaults (200MHz/3Mbaud) would make
    // this bench's many full UART round trips prohibitively slow to simulate.
    parameter int CLK_FREQ_HZ = 16_000_000;
    parameter int BAUD_RATE   = 1_000_000;
    localparam int BIT_CYCLES = CLK_FREQ_HZ / BAUD_RATE;

    localparam int FOUND_DEPTH = 4;   // must match work_controller's default

    localparam logic [7:0] CMD_READ_REQ  = 8'h00;
    localparam logic [7:0] CMD_WRITE_REQ = 8'h01;
    localparam logic [7:0] CMD_READ_RESP = 8'h80;
    localparam logic [7:0] CMD_WRITE_ACK = 8'h81;
    localparam logic [7:0] SOF           = 8'hAA;

    localparam logic [7:0] ADDR_CTRL         = 8'h00;
    localparam logic [7:0] ADDR_PPH0         = 8'h08;
    localparam logic [7:0] ADDR_TS0          = 8'h28;
    localparam logic [7:0] ADDR_TGT0         = 8'h30;
    localparam logic [7:0] ADDR_NONCE0       = 8'h50;
    localparam logic [7:0] ADDR_FOUND_NONCE0 = 8'h58;
    localparam logic [7:0] ADDR_FOUND_NONCE1 = 8'h5C;
    localparam logic [7:0] ADDR_FOUND_WORKID = 8'h60;
    localparam logic [7:0] ADDR_FOUND_COUNT  = 8'h64;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst;
    logic rx = 1'b1;
    logic tx;

    kaspa_miner #(
        .CSHAKE_STAGES(CSHAKE_STAGES),
        .MATMUL_STAGES(MATMUL_STAGES),
        .CSHAKE_FOLDED(CSHAKE_FOLDED),
        .CLK_FREQ_HZ  (CLK_FREQ_HZ),
        .BAUD_RATE    (BAUD_RATE)
    ) dut (
        .clk(clk),
        .rst(rst),
        .rx (rx),
        .tx (tx)
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

    task automatic send_byte(input byte data);
        int i;
        begin
            rx = 1'b0;
            repeat (BIT_CYCLES) @(posedge clk);
            for (i = 0; i < 8; i++) begin
                rx = data[i];
                repeat (BIT_CYCLES) @(posedge clk);
            end
            rx = 1'b1;
            repeat (BIT_CYCLES) @(posedge clk);
        end
    endtask

    task automatic recv_byte(output byte data);
        int i;
        logic [7:0] shift;
        begin
            wait (tx == 1'b0);
            repeat (BIT_CYCLES/2) @(posedge clk);
            for (i = 0; i < 8; i++) begin
                repeat (BIT_CYCLES) @(posedge clk);
                shift[i] = tx;
            end
            repeat (BIT_CYCLES) @(posedge clk);
            data = shift;
        end
    endtask

    task automatic send_frame(input byte cmd, input byte a, input logic [31:0] data);
        byte d0, d1, d2, d3, chk;
        begin
            d0 = data[7:0]; d1 = data[15:8]; d2 = data[23:16]; d3 = data[31:24];
            chk = cmd ^ a ^ d0 ^ d1 ^ d2 ^ d3;
            send_byte(SOF);
            send_byte(cmd);
            send_byte(a);
            send_byte(d0); send_byte(d1); send_byte(d2); send_byte(d3);
            send_byte(chk);
        end
    endtask

    task automatic recv_frame(output byte sof, output byte cmd, output byte a,
                               output logic [31:0] data, output byte chk);
        byte d0, d1, d2, d3;
        begin
            recv_byte(sof);
            recv_byte(cmd);
            recv_byte(a);
            recv_byte(d0); recv_byte(d1); recv_byte(d2); recv_byte(d3);
            recv_byte(chk);
            data = {d3, d2, d1, d0};
        end
    endtask

    task automatic reg_write_uart(input logic [7:0] a, input logic [31:0] d);
        byte sof, cmd, raddr, chk;
        logic [31:0] rdat;
        begin
            send_frame(CMD_WRITE_REQ, a, d);
            recv_frame(sof, cmd, raddr, rdat, chk);
            check(sof == SOF && cmd == CMD_WRITE_ACK && raddr == a && rdat == d,
                  $sformatf("write ack mismatch at addr 0x%0h", a));
        end
    endtask

    task automatic reg_read_uart(input logic [7:0] a, output logic [31:0] d);
        byte sof, cmd, raddr, chk;
        begin
            send_frame(CMD_READ_REQ, a, 32'h0);
            recv_frame(sof, cmd, raddr, d, chk);
            check(sof == SOF && cmd == CMD_READ_RESP && raddr == a,
                  $sformatf("read resp mismatch at addr 0x%0h", a));
        end
    endtask

    task automatic load_job_uart(input logic [255:0] pph, input logic [63:0] ts,
                                  input logic [255:0] tgt, input logic [63:0] nb);
        int i;
        begin
            for (i = 0; i < 8; i++) reg_write_uart(8'(ADDR_PPH0 + i*4), pph[32*i +: 32]);
            for (i = 0; i < 2; i++) reg_write_uart(8'(ADDR_TS0  + i*4), ts[32*i +: 32]);
            for (i = 0; i < 8; i++) reg_write_uart(8'(ADDR_TGT0 + i*4), tgt[32*i +: 32]);
            for (i = 0; i < 2; i++) reg_write_uart(8'(ADDR_NONCE0 + i*4), nb[32*i +: 32]);
            reg_write_uart(ADDR_CTRL, 32'h1);
        end
    endtask

    // Same vectors file and layout as work_controller_tb.sv (phase 0 only).
    localparam int NVEC       = 32;
    localparam int WPH        = 6 + NVEC*4 + 4;
    localparam int NUM_PHASES = 3;
    logic [63:0] mem [0:NUM_PHASES*WPH-1];

    logic [255:0] p_pph;
    logic [63:0]  p_ts, p_base;

    function automatic logic [255:0] rd256(input logic [63:0] m[], input int off);
        rd256 = {m[off+3], m[off+2], m[off+1], m[off+0]};
    endfunction

    task automatic test1();
        localparam int MAX_POLLS = 300;
        int polls;
        logic [31:0] cnt, w0, w1, w2;
        logic [63:0] prev_nonce, popped_nonce;
        logic [7:0]  popped_workid;
        begin
            $display("Test 1: load real job over UART (all-ones target), read found nonces back");
            load_job_uart(p_pph, p_ts, {256{1'b1}}, p_base);

            polls = 0;
            do begin
                reg_read_uart(ADDR_FOUND_COUNT, cnt);
                polls++;
            end while (cnt != FOUND_DEPTH[31:0] && polls < MAX_POLLS);
            check(cnt == FOUND_DEPTH[31:0],
                  $sformatf("FOUND_COUNT never reached FOUND_DEPTH (last read %0d after %0d polls)", cnt, polls));

            prev_nonce = p_base - 1'b1;
            for (int i = 0; i < FOUND_DEPTH; i++) begin
                reg_read_uart(ADDR_FOUND_NONCE0, w0);
                reg_read_uart(ADDR_FOUND_NONCE1, w1);
                reg_read_uart(ADDR_FOUND_WORKID, w2);
                popped_nonce  = {w1, w0};
                popped_workid = w2[7:0];

                check(popped_workid == 8'h1, $sformatf("pop %0d: expected work_id 1, got %0d", i, popped_workid));
                check(popped_nonce >= p_base, $sformatf("pop %0d: found_nonce %0d below job's nonce base %0d", i, popped_nonce, p_base));
                check(popped_nonce >= prev_nonce, $sformatf("pop %0d: found_nonce %0d went backwards from %0d", i, popped_nonce, prev_nonce));
                prev_nonce = popped_nonce;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/kaspa_miner_tb.vcd");
        $dumpvars(0, kaspa_miner_tb);

        $readmemh("../../core/sim/expected_vectors.mem", mem);
        p_pph  = rd256(mem, 0);
        p_ts   = mem[4];
        p_base = mem[5];

        rst = 1'b1;
        rx  = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        test1();

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
        #100_000_000;
        $fatal(1, "FAIL: global timeout");
    end

endmodule
