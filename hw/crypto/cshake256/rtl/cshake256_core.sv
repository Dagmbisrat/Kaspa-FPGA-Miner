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

// Valid shift register — tracks which stages hold live data
logic [26:0] valid_sr;


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
    valid_sr <= {valid_sr[25:0], valid_in};
end
// -------------------------------------------------------------------------


// ********************** Stage 1 : XOR into SpongeState  ******************
// -------------------------------------------------------------------------
logic [STATE_BITS-1:0] stage1_comb;

// Pre-computed SpongeState constants (post-header Keccak-f output)
// Lane ordering: lane_idx = x + 5*y  (matches absorb module convention)
localparam logic [63:0] SPONGE_POW [0:24] = '{
    // y=0: lanes 0-4
    64'hb08dee036fe1cdd5, 64'h833533355cc91b1f, 64'h8808752c531a506b,
    64'h4670ce44b2606c77, 64'h039a6a5bae88e5ad,
    // y=1: lanes 5-9
    64'hedb7cd4412115b98, 64'hcb86952ca553ad6a, 64'h488d68534b3d84ff,
    64'h8a6531470cf6cebf, 64'h09acbd0b98e33f2c,
    // y=2: lanes 10-14
    64'he9fbf67c0a5d01bc, 64'h30f583bd38d2bed7, 64'hd18c0bf6288590ab,
    64'h9704ebe8b6ecf519, 64'h16f6f9aad0cf8e7c,
    // y=3: lanes 15-19
    64'h1643b28f559f8650, 64'h0488e01dde10bd17, 64'h3c20a7939bc9c51a,
    64'h948d74ea54364de6, 64'h681f2c0817428514,
    // y=4: lanes 20-24
    64'haddedab19c1e9c60, 64'h5013c7d572442445, 64'h9e5bfcc18274e2e3,
    64'h5779ac19c74d66c0, 64'h851e49cfc7997a73
};

localparam logic [63:0] SPONGE_HH [0:24] = '{
    // y=0: lanes 0-4
    64'h1e8357896603c46c, 64'hf45a9a0a20f85dfd, 64'ha0d4b7bbb21581ce,
    64'hdfc8b7581c89ed05, 64'h526d742699e6426c,
    // y=1: lanes 5-9
    64'h473d100eb0263063, 64'h085f315a4476a9a0, 64'h9293d1bb86123413,
    64'ha81675ed0bf6929b, 64'h003849b026e0582b,
    // y=2: lanes 10-14
    64'h660a8aaf532af32f, 64'h3996ac6c067589a2, 64'hcbb3b88519c0308e,
    64'hb0cc3b0e1ecc7d73, 64'h6fc0c572a9710157,
    // y=3: lanes 15-19
    64'hfa70d4a9cb9e4a1a, 64'hc88462ad7b5f93a9, 64'h49c385e6b62d7460,
    64'hb4b2139c7d16f1bf, 64'h7a057b83d0befedf,
    // y=4: lanes 20-24
    64'hb269a02fb7ef4570, 64'h12cc3c946368d4b8, 64'h8384630610f619c8,
    64'hc727a285ee3646ec, 64'h70a6245ffa7125e2
};

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
assign valid_out = valid_sr[26];
// -------------------------------------------------------------------------

endmodule
