`timescale 1ns / 1ps

module xoshiro256pp_tb;

logic clk;
logic rst;
logic [63:0] s0, s1, s2, s3;
logic [63:0] out, new_s0, new_s1, new_s2, new_s3;

xoshiro256pp uut (
    .clk(clk),
    .rst(rst),
    .s0(s0), .s1(s1), .s2(s2), .s3(s3),
    .out(out),
    .new_s0(new_s0), .new_s1(new_s1), .new_s2(new_s2), .new_s3(new_s3)
);

// Clock generation
always #5 clk = ~clk;

// Expected values
logic [63:0] expected_out[0:9];
logic [63:0] expected_s0[0:9];
logic [63:0] expected_s1[0:9];
logic [63:0] expected_s2[0:9];
logic [63:0] expected_s3[0:9];

integer i;
integer pass_count;
integer fail_count;

initial begin
    $dumpfile("xoshiro256pp_tb.vcd");
    $dumpvars(0, xoshiro256pp_tb);

    // =========================================
    // TODO: Fill expected values from Python
    // =========================================
    // Iteration 0
    expected_out[0] = 64'h7BA9D98CB5621547;
    expected_s0[0]  = 64'hB6B2B62B4D94D494;
    expected_s1[0]  = 64'h494D49D4B26B2B6B;
    expected_s2[0]  = 64'hC382FD17B34C684A;
    expected_s3[0]  = 64'hE32F7490DC0A7BA7;

    // Iteration 1
    expected_out[1] = 64'h14C785D36B61C5A9;
    expected_s0[1]  = 64'h1CD08B6F23F58458;
    expected_s1[1]  = 64'h3C7D02E84CB397B5;
    expected_s2[1]  = 64'hE6992FEAA80EBCDE;
    expected_s3[1]  = 64'h2A19954C47A88DCC;

    // Iteration 2
    expected_out[2] = 64'h7A865A783618F968;
    expected_s0[2]  = 64'h0AB41CCB28EE9E21;
    expected_s1[2]  = 64'hC634A66DC748AF33;
    expected_s2[2]  = 64'hFF993DE2A4913886;
    expected_s3[2]  = 64'h634F22CC92F48163;

    // Iteration 3
    expected_out[3] = 64'hD6920E5AEB259FC0;
    expected_s0[3]  = 64'hAFCF986A7D52B071;
    expected_s1[3]  = 64'h331987444B370994;
    expected_s2[3]  = 64'hB9F6AFB8D219A6A7;
    expected_s3[3]  = 64'h85CA14AF70942AB7;

    // Iteration 4
    expected_out[4] = 64'h3CC68BD8116D7D47;
    expected_s0[4]  = 64'h191C0B8146F19352;
    expected_s1[4]  = 64'h2520B096E47C1F42;
    expected_s2[4]  = 64'h18B1A1BCBC6316D6;
    expected_s3[4]  = 64'h646476DA727D6774;

    // Iteration 5
    expected_out[5] = 64'h46F8C2FEAA305393;
    expected_s0[5]  = 64'h5858CDCDD0F0EB64;
    expected_s1[5]  = 64'h248D1AAB1EEE9AC6;
    expected_s2[5]  = 64'h608062C5C4168584;
    expected_s3[5]  = 64'h2F06C82898C992C0;

    // Iteration 6
    expected_out[6] = 64'h538DAB0CE3349B2E;
    expected_s0[6]  = 64'h53D31F4E56D7E362;
    expected_s1[6]  = 64'h1C55B5A30A08F426;
    expected_s2[6]  = 64'h0D8E92D5216A6EE0;
    expected_s3[6]  = 64'hE100C1717A5070C4;

    // Iteration 7
    expected_out[7] = 64'hB3BBB37869F24D52;
    expected_s0[7]  = 64'hAE866B9C268F6780;
    expected_s1[7]  = 64'h420838387DB579A4;
    expected_s2[7]  = 64'h351B998A9FF18D82;
    expected_s3[7]  = 64'h109C5FAAAE9A4E0B;

    // Iteration 8
    expected_out[8] = 64'h51F10076EC6EF8E5;
    expected_s0[8]  = 64'hFC120C0EF5A0502F;
    expected_s1[8]  = 64'hD995CA2EC4CB93A6;
    expected_s2[8]  = 64'hEBED097C4A36EA02;
    expected_s3[8]  = 64'hE6F5EA528CF25A65;

    // Iteration 9
    expected_out[9] = 64'h2CD355644011D42A;
    expected_s0[9]  = 64'hC3722C72BD9999EC;
    expected_s1[9]  = 64'hCE6ACF5C7B5D298B;
    expected_s2[9]  = 64'h83A28CE598DABA2D;
    expected_s3[9]  = 64'h393867EC040F8907;

    // Initialize
    clk = 0;
    rst = 1;
    s0 = 64'h0;
    s1 = 64'h0;
    s2 = 64'h0;
    s3 = 64'h0;
    pass_count = 0;
    fail_count = 0;

    // Release reset
    @(posedge clk);
    #1 rst = 0;

    // Load seed state
    s0 = 64'h1234567890ABCDEF;
    s1 = 64'hFEDCBA0987654321;
    s2 = 64'hA5A5A5A5A5A5A5A5;
    s3 = 64'h5A5A5A5A5A5A5A5A;

    // Run 10 iterations, compare against expected
    for (i = 0; i < 10; i = i + 1) begin
        @(posedge clk);
        #1;

        if (out !== expected_out[i] ||
            new_s0 !== expected_s0[i] || new_s1 !== expected_s1[i] ||
            new_s2 !== expected_s2[i] || new_s3 !== expected_s3[i]) begin
            $display("FAIL iter %0d", i);
            $display("  out:  got=%h exp=%h %s", out, expected_out[i], (out !== expected_out[i]) ? "<-- MISMATCH" : "");
            $display("  s0:   got=%h exp=%h %s", new_s0, expected_s0[i], (new_s0 !== expected_s0[i]) ? "<-- MISMATCH" : "");
            $display("  s1:   got=%h exp=%h %s", new_s1, expected_s1[i], (new_s1 !== expected_s1[i]) ? "<-- MISMATCH" : "");
            $display("  s2:   got=%h exp=%h %s", new_s2, expected_s2[i], (new_s2 !== expected_s2[i]) ? "<-- MISMATCH" : "");
            $display("  s3:   got=%h exp=%h %s", new_s3, expected_s3[i], (new_s3 !== expected_s3[i]) ? "<-- MISMATCH" : "");
            fail_count = fail_count + 1;
        end else begin
            $display("PASS iter %0d  out=%h", i, out);
            pass_count = pass_count + 1;
        end

        // Feed state back
        s0 = new_s0;
        s1 = new_s1;
        s2 = new_s2;
        s3 = new_s3;
    end

    $display("");
    $display("=============================");
    $display(" Results: %0d PASS, %0d FAIL", pass_count, fail_count);
    $display("=============================");

    $finish;
end

endmodule
