`timescale 1ns / 1ps
// uart_if_tb -- self-checking bench for the UART transport adapter.
// No physical UART PHY is simulatable in Verilator, so this bench IS the
// host: it bit-bangs request frames onto the DUT's rx pin and bit-bangs
// received bytes off its tx pin (see docs/io/uart_if.md).
module uart_if_tb;

    localparam int CLK_FREQ_HZ = 16_000_000;
    localparam int BAUD_RATE   = 1_000_000;
    localparam int BIT_CYCLES  = CLK_FREQ_HZ / BAUD_RATE;

    localparam logic [7:0] CMD_READ_REQ  = 8'h00;
    localparam logic [7:0] CMD_WRITE_REQ = 8'h01;
    localparam logic [7:0] CMD_READ_RESP = 8'h80;
    localparam logic [7:0] CMD_WRITE_ACK = 8'h81;
    localparam logic [7:0] CMD_NACK      = 8'h82;
    localparam logic [7:0] SOF           = 8'hAA;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst;
    logic rx = 1'b1;
    logic tx;

    logic [7:0]  addr;
    logic [31:0] wdata;
    logic        we, re;
    logic [31:0] rdata;

    uart_if #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) dut (
        .clk  (clk),
        .rst  (rst),
        .rx   (rx),
        .tx   (tx),
        .addr (addr),
        .wdata(wdata),
        .we   (we),
        .re   (re),
        .rdata(rdata)
    );

    // Stand-in for work_controller (doesn't exist yet): plain memory,
    // always-valid combinational read. Real work_controller has side
    // effects (e.g. FOUND_NONCE pops a FIFO) this bench doesn't need.
    logic [31:0] mem [0:255];
    always_ff @(posedge clk) if (we) mem[addr] <= wdata;
    assign rdata = mem[addr];

    int pass_count = 0;
    int fail_count = 0;

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
            // Level-check, not edge-wait: the DUT can start driving tx low
            // before this task starts watching it, so `@(negedge tx)` can
            // miss the edge and hang forever.
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

    task automatic send_frame(input byte cmd, input byte a, input logic [31:0] data,
                               input bit corrupt_chk = 1'b0);
        byte d0, d1, d2, d3, chk;
        begin
            d0 = data[7:0]; d1 = data[15:8]; d2 = data[23:16]; d3 = data[31:24];
            chk = cmd ^ a ^ d0 ^ d1 ^ d2 ^ d3;
            if (corrupt_chk) chk = chk ^ 8'h01;
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

    task automatic check(input bit cond, input string msg);
        begin
            if (cond) begin
                pass_count++;
            end else begin
                fail_count++;
                $display("FAIL: %s", msg);
            end
        end
    endtask

    byte         sof, cmd, raddr, chk;
    logic [31:0] rdat;

    initial begin
        $dumpfile("sim/uart_if_tb.vcd");
        $dumpvars(0, uart_if_tb);

        rst = 1'b1;
        rx  = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        $display("Test 1: write 0xCAFEBABE to addr 0x10");
        send_frame(CMD_WRITE_REQ, 8'h10, 32'hCAFEBABE);
        recv_frame(sof, cmd, raddr, rdat, chk);
        check(sof   == SOF,           "write ack: bad SOF");
        check(cmd   == CMD_WRITE_ACK, "write ack: bad CMD");
        check(raddr == 8'h10,         "write ack: bad ADDR echo");
        check(rdat  == 32'hCAFEBABE,  "write ack: bad DATA echo");
        check(chk   == (cmd ^ raddr ^ rdat[7:0] ^ rdat[15:8] ^ rdat[23:16] ^ rdat[31:24]),
              "write ack: bad checksum");
        check(mem[8'h10] == 32'hCAFEBABE, "write: register bus write did not land");

        $display("Test 2: read back addr 0x10");
        send_frame(CMD_READ_REQ, 8'h10, 32'h0);
        recv_frame(sof, cmd, raddr, rdat, chk);
        check(sof   == SOF,           "read resp: bad SOF");
        check(cmd   == CMD_READ_RESP, "read resp: bad CMD");
        check(raddr == 8'h10,         "read resp: bad ADDR echo");
        check(rdat  == 32'hCAFEBABE,  "read resp: data did not match prior write");

        $display("Test 3: write with bad checksum to addr 0x20 -> expect NACK");
        send_frame(CMD_WRITE_REQ, 8'h20, 32'hDEADBEEF, 1'b1);
        recv_frame(sof, cmd, raddr, rdat, chk);
        check(sof  == SOF,        "NACK: bad SOF");
        check(cmd  == CMD_NACK,   "NACK: bad CMD");
        check(rdat == 32'h0,      "NACK: DATA should be zero");
        check(mem[8'h20] == 32'h0, "NACK: write must NOT have landed on the reg bus");

        $display("Test 4: stray byte then a valid write -> resync at WAIT_SOF");
        send_byte(8'h55);
        send_frame(CMD_WRITE_REQ, 8'h30, 32'h11223344);
        recv_frame(sof, cmd, raddr, rdat, chk);
        check(sof   == SOF,           "resync: bad SOF");
        check(cmd   == CMD_WRITE_ACK, "resync: bad CMD");
        check(raddr == 8'h30,         "resync: bad ADDR echo");
        check(rdat  == 32'h11223344,  "resync: bad DATA echo");
        check(mem[8'h30] == 32'h11223344, "resync: register bus write did not land");

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
        #2_000_000;
        $fatal(1, "FAIL: global timeout");
    end

endmodule
