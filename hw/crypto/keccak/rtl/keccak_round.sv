module keccak_round(
    input logic [63:0] state [0:4][0:4],
    input logic [63:0] round_constant,
    output logic [63:0] out [0:4][0:4]
);

// Theta intermediate placeholders
logic [63:0] xor_array [0:4];
logic [63:0] offset_array [0:4];
logic [63:0] theta [0:4][0:4];
always_comb begin : theta_block
    // 1. XOR mixing of columns
    for (int x = 0; x < 5; x++) begin
        xor_array[x] = state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4];
    end

    // 2. Offset rotation of rows
    offset_array[0] = xor_array[4] ^ {xor_array[1][62:0], xor_array[1][63]};
    for (int x = 1; x < 4; x++) begin
        offset_array[x] = xor_array[x-1] ^ {xor_array[x+1][62:0], xor_array[x+1][63]};
    end
    offset_array[4] = xor_array[3] ^ {xor_array[0][62:0], xor_array[0][63]};

    // 3. Apply to each lane
    for (int x = 0; x < 5; x++) begin
        for (int y = 0; y < 5; y++) begin
            theta[x][y] = state[x][y] ^ offset_array[x];
        end
    end
end

// Rho intermediate placeholders
localparam logic [5:0] RHO_OFFSETS [0:4][0:4] = '{
    '{6'd0,  6'd36, 6'd3,  6'd41, 6'd18},  // x=0
    '{6'd1,  6'd44, 6'd10, 6'd45, 6'd2},   // x=1
    '{6'd62, 6'd6,  6'd43, 6'd15, 6'd61},  // x=2
    '{6'd28, 6'd55, 6'd25, 6'd21, 6'd56},  // x=3
    '{6'd27, 6'd20, 6'd39, 6'd8,  6'd14}   // x=4
};
logic [63:0] rho [0:4][0:4];
always_comb begin : rho_block
    // Rotate each lane by a different offset
    for (int x = 0; x < 5; x++) begin
        for (int y = 0; y < 5; y++) begin
            rho[x][y] = theta[x][y] << RHO_OFFSETS[x][y] | theta[x][y] >> (64 - RHO_OFFSETS[x][y]);
        end
    end
end

// Pi intermediate placeholders
logic [63:0] pi [0:4][0:4];
always_comb begin : pi_block
    for (int x = 0; x < 5; x++) begin
        for (int y = 0; y < 5; y++) begin
            pi[y % 5][((2*x) + (3*y)) % 5] = rho[x][y];
        end
    end
end

// Chi intermediate placeholders
logic [63:0] chi [0:4][0:4];
always_comb begin : chi_block
    for (int x = 0; x < 5; x++) begin
        for (int y = 0; y < 5; y++) begin
            chi[x][y] = pi[x][y] ^ ((~pi[(x+1)%5][y]) & pi[(x+2)%5][y]);
        end
    end
end

// Iota - XOR round constant into lane [0][0]
always_comb begin : iota_block
    out = chi;
    out[0][0] = chi[0][0] ^ round_constant;
end

endmodule
