module cshake256_pipelined_core #(
    parameter int NUM_STAGES  = 24,   // pipeline register layers for the 24 Keccak rounds; must divide 24
    parameter bit S_VALUE     = 1'b0, // BUILD-TIME S string: 0 = "ProofOfWorkHash", 1 = "HeavyHash"
    parameter bit DATA_80BYTE = 1'b1  // BUILD-TIME input size: 0 = 32-byte input, 1 = 80-byte input
) (
    input  logic          clk,
    input  logic          rst,

    // Input
    input  logic [639:0]  data_in,
    input  logic          valid_in,

    // Output
    output logic [255:0]  hash_out,
    output logic          valid_out
);

localparam int RATE_BITS  = 1088;  // 136 bytes
localparam int STATE_BITS = 1600;  // 25 x 64-bit lanes
localparam int NUM_ROUNDS = 24;
// Feed-forward sub-pipeline: NUM_STAGES register layers, each computing
// ROUNDS_PER_STAGE Keccak rounds combinationally.  Total round instances =
// NUM_STAGES * ROUNDS_PER_STAGE = 24 regardless of NUM_STAGES.
localparam int ROUNDS_PER_STAGE = NUM_ROUNDS / NUM_STAGES;
// Latency = 1 (encode) + 1 (xor sponge) + NUM_STAGES (keccak layers) cycles.
localparam int LAT = NUM_STAGES + 2;

initial begin
    assert (NUM_ROUNDS % NUM_STAGES == 0)
        else $fatal(1, "NUM_STAGES (%0d) must divide NUM_ROUNDS (24)", NUM_STAGES);
end


// Pipeline registers
logic [RATE_BITS-1:0]  pr0;  // Stage 0: encoded message block
logic [STATE_BITS-1:0] pr1;  // Stage 1: after XOR into sponge state

// Valid shift register — one bit per pipeline stage (feed-forward, no stalls).
logic [LAT-1:0] valid_sr;

// Feed-forward Keccak — one 1600-bit register per pipeline stage.
// A new hash may enter every cycle; result emerges LAT cycles later.
logic [STATE_BITS-1:0] kstate [0:NUM_STAGES-1];


// Round constants
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


// ********************** Stage 0 : Encode Msg  ****************************
// -------------------------------------------------------------------------
// The input size is fixed at build time by DATA_80BYTE, so only one encoding
// branch is elaborated (the other is pruned as dead logic).
logic [RATE_BITS-1:0] stage0_comb;

always_comb begin
    stage0_comb = '0;

    if (DATA_80BYTE) begin
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
    pr0 <= stage0_comb;
    if (rst) valid_sr <= '0;
    else     valid_sr <= {valid_sr[LAT-2:0], valid_in};
end
// -------------------------------------------------------------------------


// ********************** Stage 1 : XOR into SpongeState  ******************
// -------------------------------------------------------------------------
// Pre-computed SpongeState constants (post-header Keccak-f output).
// Lane ordering: lane_idx = x + 5*y.  Both tables are declared as localparams
// so the S_VALUE selection below is resolved at elaboration — only the chosen
// table materializes as constants; the unused one produces no hardware.
localparam logic [63:0] SPONGE_POW [0:24] = '{
    64'h113cff0da1f6d83d, 64'h29bf8855b7027e3c, 64'h1e5f2e720efb44d2,
    64'h1ba5a4a3f59869a0, 64'h7b2fafca875e2d65, 64'h4aef61d629dce246,
    64'h183a981ead415b10, 64'h776bf60c789bc29c, 64'hf8ebf13388663140,
    64'h2e651c3c43285ff0, 64'h0f96070540f14a0e, 64'h44e367875b299152,
    64'hec70f1a425b13715, 64'he6c85d8f82e9da89, 64'hb21a601f85b4b223,
    64'h3485549064a36a46, 64'h8f06dd1c7a2f851a, 64'hc1a2021d563bb142,
    64'hba1de5e4451668e4, 64'hd102574105095f8d, 64'h89ca4e849bcecf4a,
    64'h48b09427a8742edb, 64'hb1fcce9ce78b5272, 64'h5d1129cf82afa5bc,
    64'h02b97c786f824383
};

localparam logic [63:0] SPONGE_HH [0:24] = '{
    64'h3ad74c52b2248509, 64'h79629b0e2f9f4216, 64'h7a14ff4816c7f8ee,
    64'h11a75f4c80056498, 64'he720e0df44eecede, 64'h72c7d82e14f34069,
    64'hc100ff2a938935ba, 64'h5e219040250fc462, 64'h8039f9a60dcf6a48,
    64'ha0bcaa9f792a3d0c, 64'hf431c05dd0a9a226, 64'hd31f4cc354c18c3f,
    64'h6c6b7d01a769cc3d, 64'h2ec65bd3562493e4, 64'h4ef74b3a99cdb044,
    64'h774c86835434f2b0, 64'h87e961b036bc9416, 64'h7e8f1db17765cc07,
    64'hea8fdb80bac46d39, 64'hb992f2d37b34ca58, 64'hc776c5048481b957,
    64'h47c39f675112c22e, 64'h92bb399db5290c0a, 64'h549ae0312f9fc615,
    64'h1619327d10b9da35
};

// Selected sponge constant (compile-time: S_VALUE fixes the whole table).
localparam logic [63:0] SPONGE [0:24] = S_VALUE ? SPONGE_HH : SPONGE_POW;

logic [STATE_BITS-1:0] stage1_comb;

always_comb begin
    // Lanes 0-16 (rate): XOR formatted block lanes into SpongeState constant
    for (int i = 0; i < 17; i++)
        stage1_comb[i*64 +: 64] = SPONGE[i] ^ pr0[i*64 +: 64];

    // Lanes 17-24 (capacity): pass through constant unchanged
    for (int i = 17; i < 25; i++)
        stage1_comb[i*64 +: 64] = SPONGE[i];
end

always_ff @(posedge clk)
    pr1 <= stage1_comb;
// -------------------------------------------------------------------------


// ********************** Feed-Forward Keccak : NUM_STAGES layers **********
// -------------------------------------------------------------------------
// The 24 Keccak rounds are split into NUM_STAGES pipeline stages, each stage
// computing ROUNDS_PER_STAGE = 24/NUM_STAGES rounds combinationally, then
// registering into kstate[st].  There is NO feedback: data flows straight
// through, so a new hash may enter every clock cycle (initiation interval = 1)
// and one hash result emerges every cycle after the LAT-cycle fill.
//
// Critical path = ROUNDS_PER_STAGE Keccak rounds (this is the Fmax knob).
//   NUM_STAGES = 24 -> 1 round / stage  -> highest Fmax
//   NUM_STAGES < 24 -> more rounds/stage -> lower Fmax, fewer registers
//
// Global round index for stage st, inner round r is st*ROUNDS_PER_STAGE + r,
// which sweeps 0..23 from pr1 to hash_out.  All round constants are static.
// -------------------------------------------------------------------------
genvar st, r;
generate
    for (st = 0; st < NUM_STAGES; st++) begin : g_stage
        // Combinational chain of ROUNDS_PER_STAGE rounds.
        // chain[0] = stage input, chain[ROUNDS_PER_STAGE] = stage output.
        logic [63:0] chain [0:ROUNDS_PER_STAGE][0:4][0:4];

        // Stage input mux via generate-if to avoid an illegal kstate[-1] index.
        if (st == 0) begin : g_in_first
            always_comb
                for (int x = 0; x < 5; x++)
                    for (int y = 0; y < 5; y++)
                        chain[0][x][y] = pr1[(x + 5*y)*64 +: 64];
        end else begin : g_in_rest
            always_comb
                for (int x = 0; x < 5; x++)
                    for (int y = 0; y < 5; y++)
                        chain[0][x][y] = kstate[st-1][(x + 5*y)*64 +: 64];
        end

        // ROUNDS_PER_STAGE purely-combinational keccak_round instances.
        for (r = 0; r < ROUNDS_PER_STAGE; r++) begin : g_round
            localparam int GLOBAL_R = st*ROUNDS_PER_STAGE + r;  // 0..23
            keccak_round u_round (
                .state          (chain[r]),
                .round_constant (RC[GLOBAL_R]),
                .out            (chain[r+1])
            );
        end

        // Register this stage's output.
        always_ff @(posedge clk)
            for (int x = 0; x < 5; x++)
                for (int y = 0; y < 5; y++)
                    kstate[st][(x + 5*y)*64 +: 64] <= chain[ROUNDS_PER_STAGE][x][y];
    end
endgenerate
// -------------------------------------------------------------------------


// ********************** Output *******************************************
// -------------------------------------------------------------------------
assign hash_out  = kstate[NUM_STAGES-1][255:0];
assign valid_out = valid_sr[LAT-2];  // aligns valid_out with hash_out (kstate[NUM_STAGES-1])
// -------------------------------------------------------------------------

endmodule
