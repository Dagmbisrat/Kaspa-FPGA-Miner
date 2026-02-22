module xoshiro256pp(
    input logic [63:0] s0, s1, s2, s3,
    output logic [63:0] out, new_s0, new_s1, new_s2, new_s3
);

logic [63:0] temp;
logic [63:0] t;
logic [63:0] temp_s2;
logic [63:0] temp_s3;

always_comb begin
    temp = s0 + s3;
    t = {s1[46:0], 17'b0}; // t = s1 << 17

    temp_s2 = s2 ^ s0;
    temp_s3 = s3 ^ s1;

    // PRNG output
    out = {temp[40:0], temp[63:41]} + s0;

    // Next state
    new_s0 = s0 ^ temp_s3;
    new_s1 = s1 ^ temp_s2;
    new_s2 = temp_s2 ^ t;
    new_s3 = {temp_s3[18:0], temp_s3[63:19]};
end

endmodule
