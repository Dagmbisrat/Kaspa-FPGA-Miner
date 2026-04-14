module cshake256_pipelined_core (
    input  logic          clk,
    input  logic          rst,

    // Input
    input  logic [639:0]  data_in,
    input  logic          data_80byte,  // 0: 32-byte input, 1: 80-byte input
    input  logic          s_value,      // 0: S = "ProofOfWorkHash", 1: S = "HeavyHash"
    input  logic          valid_in,

    // Output
    output logic [255:0]  hash_out,
    output logic          valid_out
);

localparam int RATE_BITS  = 1088;  // 136 bytes
localparam int STATE_BITS = 1600;  // 25 x 64-bit lanes
localparam int NUM_ROUNDS = 24;


// Pipeline registers
logic [RATE_BITS-1:0]  pr0;           // After stage 0: encoded message block
logic [STATE_BITS-1:0] pr [1:25];     // After stage 1 (XOR) through stage 25 (Round 23)

// Valid shift register — 26 bits so valid_sr[25] asserts on the same edge
// that pr[25] is written (cycle 26), matching the Notes.txt timing diagram.
logic [25:0] valid_sr;


// ********************** Stage 0 : Encode Msg  ****************************
// -------------------------------------------------------------------------
logic [RATE_BITS-1:0] stage0_comb;

always_comb begin
    stage0_comb = '0;

    if (data_80byte) begin
        // left_encode(640) = 0x02, 0x02, 0x80
        stage0_comb[7:0]       = 8'h02;
        stage0_comb[15:8]      = 8'h02;
        stage0_comb[23:16]     = 8'h80;
        stage0_comb[663:24]    = data_in;        // 80 bytes of msg (640 bits)
        stage0_comb[671:664]   = 8'h04;          // domain separator at byte 83
        // bytes 84-134 already zero
        stage0_comb[1087:1080] = 8'h80;          // final bit marker at byte 135
    end else begin
        // left_encode(256) = 0x02, 0x01, 0x00
        stage0_comb[7:0]       = 8'h02;
        stage0_comb[15:8]      = 8'h01;
        stage0_comb[23:16]     = 8'h00;
        stage0_comb[279:24]    = data_in[255:0]; // 32 bytes of msg (256 bits)
        stage0_comb[287:280]   = 8'h04;          // domain separator at byte 35
        // bytes 36-134 already zero
        stage0_comb[1087:1080] = 8'h80;          // final bit marker at byte 135
    end
end

always_ff @(posedge clk) begin
    pr0      <= stage0_comb;
    valid_sr <= {valid_sr[24:0], valid_in};
end
// -------------------------------------------------------------------------


// ********************** Stage 1 : XOR into SpongeState  ******************
// -------------------------------------------------------------------------
logic [STATE_BITS-1:0] stage1_comb;

// Pre-computed SpongeState constants (post-header Keccak-f output)
// Lane ordering: lane_idx = x + 5*y  (matches absorb module convention)
// Keccak-f[1600] output state — paste into .sv
logic [63:0] SPONGE_POW [0:24];
initial begin
    SPONGE_POW[ 0] = 64'h113cff0da1f6d83d;  // A[0][0]
    SPONGE_POW[ 1] = 64'h29bf8855b7027e3c;  // A[1][0]
    SPONGE_POW[ 2] = 64'h1e5f2e720efb44d2;  // A[2][0]
    SPONGE_POW[ 3] = 64'h1ba5a4a3f59869a0;  // A[3][0]
    SPONGE_POW[ 4] = 64'h7b2fafca875e2d65;  // A[4][0]
    SPONGE_POW[ 5] = 64'h4aef61d629dce246;  // A[0][1]
    SPONGE_POW[ 6] = 64'h183a981ead415b10;  // A[1][1]
    SPONGE_POW[ 7] = 64'h776bf60c789bc29c;  // A[2][1]
    SPONGE_POW[ 8] = 64'hf8ebf13388663140;  // A[3][1]
    SPONGE_POW[ 9] = 64'h2e651c3c43285ff0;  // A[4][1]
    SPONGE_POW[10] = 64'h0f96070540f14a0e;  // A[0][2]
    SPONGE_POW[11] = 64'h44e367875b299152;  // A[1][2]
    SPONGE_POW[12] = 64'hec70f1a425b13715;  // A[2][2]
    SPONGE_POW[13] = 64'he6c85d8f82e9da89;  // A[3][2]
    SPONGE_POW[14] = 64'hb21a601f85b4b223;  // A[4][2]
    SPONGE_POW[15] = 64'h3485549064a36a46;  // A[0][3]
    SPONGE_POW[16] = 64'h8f06dd1c7a2f851a;  // A[1][3]
    SPONGE_POW[17] = 64'hc1a2021d563bb142;  // A[2][3]
    SPONGE_POW[18] = 64'hba1de5e4451668e4;  // A[3][3]
    SPONGE_POW[19] = 64'hd102574105095f8d;  // A[4][3]
    SPONGE_POW[20] = 64'h89ca4e849bcecf4a;  // A[0][4]
    SPONGE_POW[21] = 64'h48b09427a8742edb;  // A[1][4]
    SPONGE_POW[22] = 64'hb1fcce9ce78b5272;  // A[2][4]
    SPONGE_POW[23] = 64'h5d1129cf82afa5bc;  // A[3][4]
    SPONGE_POW[24] = 64'h02b97c786f824383;  // A[4][4]
end

// Keccak-f[1600] output state — paste into .sv
logic [63:0] SPONGE_HH [0:24];
initial begin
    SPONGE_HH[ 0] = 64'h3ad74c52b2248509;  // A[0][0]
    SPONGE_HH[ 1] = 64'h79629b0e2f9f4216;  // A[1][0]
    SPONGE_HH[ 2] = 64'h7a14ff4816c7f8ee;  // A[2][0]
    SPONGE_HH[ 3] = 64'h11a75f4c80056498;  // A[3][0]
    SPONGE_HH[ 4] = 64'he720e0df44eecede;  // A[4][0]
    SPONGE_HH[ 5] = 64'h72c7d82e14f34069;  // A[0][1]
    SPONGE_HH[ 6] = 64'hc100ff2a938935ba;  // A[1][1]
    SPONGE_HH[ 7] = 64'h5e219040250fc462;  // A[2][1]
    SPONGE_HH[ 8] = 64'h8039f9a60dcf6a48;  // A[3][1]
    SPONGE_HH[ 9] = 64'ha0bcaa9f792a3d0c;  // A[4][1]
    SPONGE_HH[10] = 64'hf431c05dd0a9a226;  // A[0][2]
    SPONGE_HH[11] = 64'hd31f4cc354c18c3f;  // A[1][2]
    SPONGE_HH[12] = 64'h6c6b7d01a769cc3d;  // A[2][2]
    SPONGE_HH[13] = 64'h2ec65bd3562493e4;  // A[3][2]
    SPONGE_HH[14] = 64'h4ef74b3a99cdb044;  // A[4][2]
    SPONGE_HH[15] = 64'h774c86835434f2b0;  // A[0][3]
    SPONGE_HH[16] = 64'h87e961b036bc9416;  // A[1][3]
    SPONGE_HH[17] = 64'h7e8f1db17765cc07;  // A[2][3]
    SPONGE_HH[18] = 64'hea8fdb80bac46d39;  // A[3][3]
    SPONGE_HH[19] = 64'hb992f2d37b34ca58;  // A[4][3]
    SPONGE_HH[20] = 64'hc776c5048481b957;  // A[0][4]
    SPONGE_HH[21] = 64'h47c39f675112c22e;  // A[1][4]
    SPONGE_HH[22] = 64'h92bb399db5290c0a;  // A[2][4]
    SPONGE_HH[23] = 64'h549ae0312f9fc615;  // A[3][4]
    SPONGE_HH[24] = 64'h1619327d10b9da35;  // A[4][4]
end

always_comb begin
    // Lanes 0-16 (rate): XOR formatted block lanes into SpongeState constant
    for (int i = 0; i < 17; i++)
        stage1_comb[i*64 +: 64] = (s_value ? SPONGE_HH[i] : SPONGE_POW[i]) ^ pr0[i*64 +: 64];

    // Lanes 17-24 (capacity): pass through constant unchanged, input never reaches here
    for (int i = 17; i < 25; i++)
        stage1_comb[i*64 +: 64] = s_value ? SPONGE_HH[i] : SPONGE_POW[i];
end

always_ff @(posedge clk)
    pr[1] <= stage1_comb;
// -------------------------------------------------------------------------


// ********************** Stages 2-25 : Keccak Rounds 0-23 ****************
// -------------------------------------------------------------------------
// Each iteration of the generate loop is one pipeline stage:
//   - Unpacks the flat 1600-bit pr[r+1] into a 5x5 lane array  (lane = x + 5*y)
//   - Feeds it into a keccak_round instance with its hardcoded RC
//   - Packs the result back into flat pr[r+2] on the clock edge
// -------------------------------------------------------------------------

localparam logic [63:0] RC [0:23] = '{
    64'h0000000000000001, 64'h0000000000008082, 64'h800000000000808A,
    64'h8000000080008000, 64'h000000000000808B, 64'h0000000080000001,
    64'h8000000080008081, 64'h8000000000008009, 64'h000000000000008A,
    64'h0000000000000088, 64'h0000000080008009, 64'h000000008000000A,
    64'h000000008000808B, 64'h800000000000008B, 64'h8000000000008089,
    64'h8000000000008003, 64'h8000000000008002, 64'h8000000000000080,
    64'h000000000000800A, 64'h800000008000000A, 64'h8000000080008081,
    64'h8000000000008080, 64'h0000000080000001, 64'h8000000080008008
};

genvar r;
generate
    for (r = 0; r < NUM_ROUNDS; r++) begin : g_round

        // Unpack flat pr[r+1] → 5x5 lane array for keccak_round input
        logic [63:0] round_in  [0:4][0:4];
        logic [63:0] round_out [0:4][0:4];

        always_comb begin
            for (int x = 0; x < 5; x++)
                for (int y = 0; y < 5; y++)
                    round_in[x][y] = pr[r+1][(x + 5*y)*64 +: 64];
        end

        keccak_round u_round (
            .state          (round_in),
            .round_constant (RC[r]),
            .out            (round_out)
        );

        // Pack keccak_round output → flat pr[r+2] on clock edge
        always_ff @(posedge clk) begin
            for (int x = 0; x < 5; x++)
                for (int y = 0; y < 5; y++)
                    pr[r+2][(x + 5*y)*64 +: 64] <= round_out[x][y];
        end

    end
endgenerate
// -------------------------------------------------------------------------


// ********************** Stage 26 : Output ********************************
// -------------------------------------------------------------------------
// pr[25] is already a register just wire the first 256 bits out
assign hash_out  = pr[25][255:0];
assign valid_out = valid_sr[25];
// -------------------------------------------------------------------------

endmodule
