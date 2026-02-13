module xoshiro256pp(
    input logic clk,
    input logic rst,
    input logic [63:0] s0, s1, s2,s3,
    output logic [63:0] out, new_s0, new_s1, new_s2, new_s3
);

logic [63:0] temp;
logic [63:0] t;
logic [63:0] temp_s2;
logic [63:0] temp_s3;

//logic for intermediate combinational values
always_comb begin
    temp = s0 + s3; // Temp usage for output

    t = {s1[46:0], 17'b0}; // t = s1 << 17

    temp_s2 = s2 ^ s0;
    temp_s3 = s3 ^ s1;
end

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        out <= 0;
        new_s0 <= 0;
        new_s1 <= 0;
        new_s2 <= 0;
        new_s3 <= 0;
    end else begin
        // output new PRNG 64bit number
        out <= {temp[40:0], temp[63:41]} + s0;

        // output updated state
        new_s0 <= s0 ^ temp_s3;
        new_s1 <= s1 ^ temp_s2;
        new_s2 <= temp_s2 ^ t;
        new_s3 <= {temp_s3[18:0], temp_s3[63:19]};
    end
end

endmodule
