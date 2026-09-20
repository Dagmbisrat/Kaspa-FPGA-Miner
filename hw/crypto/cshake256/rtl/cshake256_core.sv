module cshake256_pipelined_core #(
    // Mode switch: 0 = unfolded (spatial, one physical round-chain per
    // register layer, 1 hash/cycle streaming). 1 = folded (single reused
    // register, STAGES instances chained combinationally, looped per hash,
    // `busy` handshake gates re-entry).
    parameter bit FOLDED      = 1'b0,
    // Dual-meaning knob -- its physical effect depends on FOLDED:
    //   FOLDED=0: STAGES = number of pipeline REGISTER LAYERS the fixed 24
    //             round instances are split into (must divide 24). Pure
    //             Fmax knob -- total round-instance count is always 24
    //             regardless of STAGES.
    //   FOLDED=1: STAGES = number of PHYSICAL keccak_round instances
    //             actually built (must divide 24), chained combinationally
    //             into a single reused register and looped 24/STAGES times
    //             per hash. Area/throughput knob.
    // The same numeric value means a different physical quantity depending
    // on FOLDED -- that's the one subtlety of this parameterization.
    parameter int STAGES      = 24,
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
    output logic          valid_out,

    // High while a fold is mid-flight (FOLDED builds only); hold valid_in
    // low until it deasserts. Tied to 0 when not folded (today's streaming
    // 1 hash/cycle behavior, no handshake needed).
    output logic          busy
);

localparam int RATE_BITS  = 1088;  // 136 bytes
localparam int STATE_BITS = 1600;  // 25 x 64-bit lanes
localparam int NUM_ROUNDS = 24;
// Feed-forward sub-pipeline: STAGES register layers, each computing
// ROUNDS_PER_STAGE Keccak rounds combinationally.  Total round instances =
// STAGES * ROUNDS_PER_STAGE = 24 regardless of STAGES.  Only meaningful/used
// in g_unfolded (FOLDED=0).
localparam int ROUNDS_PER_STAGE = NUM_ROUNDS / STAGES;

// Only meaningful/used in g_folded (FOLDED=1): STAGES physical round
// instances chained per pass, looped FOLD_ITERS times per hash.
localparam int FOLD_ITERS     = NUM_ROUNDS / STAGES;
localparam int FOLD_ITER_BITS = (FOLD_ITERS > 1) ? $clog2(FOLD_ITERS) : 1;

// Latency = 1 (encode) + 1 (xor sponge) + N (keccak) cycles, where N is
// STAGES register hops (unfolded) or FOLD_ITERS loop passes (folded) --
// both are "how many more cycles after pr1 until hash_out is valid".
localparam int LAT = FOLDED ? (FOLD_ITERS + 2) : (STAGES + 2);

initial begin
    assert (NUM_ROUNDS % STAGES == 0)
        else $fatal(1, "STAGES (%0d) must divide NUM_ROUNDS (24)", STAGES);
end


// Pipeline registers
logic [RATE_BITS-1:0]  pr0;  // Stage 0: encoded message block
logic [STATE_BITS-1:0] pr1;  // Stage 1: after XOR into sponge state

// Valid shift register — one bit per pipeline stage (feed-forward, no stalls).
logic [LAT-1:0] valid_sr;


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

    // Standard cSHAKE256: absorb the message X raw (no left_encode), then the
    // cSHAKE domain byte 0x04 and the pad10*1 final bit 0x80 in byte 135.
    if (DATA_80BYTE) begin
        stage0_comb[639:0]     = data_in;        // 80 bytes of msg (640 bits)
        stage0_comb[647:640]   = 8'h04;          // cSHAKE domain separator at byte 80
        // bytes 81-134 already zero
        stage0_comb[1087:1080] = 8'h80;          // final bit marker at byte 135
    end else begin
        stage0_comb[255:0]     = data_in[255:0]; // 32 bytes of msg (256 bits)
        stage0_comb[263:256]   = 8'h04;          // cSHAKE domain separator at byte 32
        // bytes 33-134 already zero
        stage0_comb[1087:1080] = 8'h80;          // final bit marker at byte 135
    end
end

always_ff @(posedge clk) begin
    pr0 <= stage0_comb;
    if (rst) valid_sr <= '0;
    // Gated by ~busy (always 0 when not folded, so no change there): while
    // folded and busy, a caller that doesn't perfectly pulse valid_in must
    // not be able to re-enter the fold mid-flight and corrupt it. Same
    // pattern as matmul_pipelined_unit's `valid_in & ~busy` gating.
    else     valid_sr <= {valid_sr[LAT-2:0], valid_in & ~busy};
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


// ********************** Keccak: spatial (default) or single-register fold *
// -------------------------------------------------------------------------
// FOLDED == 0 (default): the original, untouched feed-forward sub-pipeline.
// STAGES pipeline stages, each computing ROUNDS_PER_STAGE = 24/STAGES rounds
// combinationally, then registering into kstate[st]. No feedback: a new hash
// may enter every cycle and one result emerges every cycle after the
// LAT-cycle fill.
//
// FOLDED == 1: STAGES keccak_round instances chained combinationally feed a
// SINGLE register (fold_state), looped back FOLD_ITERS = 24/STAGES times per
// hash. Far fewer LUTs (proportional to STAGES instead of 24), but only one
// hash may occupy the fold at a time -- `busy` gates re-entry. Same pattern
// as the standalone keccak_f1600.sv (its STAGES=1 case) and the deleted
// commit f630086.
// -------------------------------------------------------------------------
generate
if (!FOLDED) begin : g_unfolded
    // Feed-forward Keccak — one 1600-bit register per pipeline stage.
    // A new hash may enter every cycle; result emerges LAT cycles later.
    logic [STATE_BITS-1:0] kstate [0:STAGES-1];

    genvar st, r;
    for (st = 0; st < STAGES; st++) begin : g_stage
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

    assign hash_out  = kstate[STAGES-1][255:0];
    assign valid_out = valid_sr[LAT-2];  // aligns valid_out with hash_out (kstate[STAGES-1])
    assign busy      = 1'b0;             // no fold, no re-entry handshake needed

end else begin : g_folded
    // Single reused register, STAGES rounds chained combinationally per
    // pass, looped FOLD_ITERS times. Only one hash resident at a time.
    logic [STATE_BITS-1:0]      fold_state;
    logic [FOLD_ITER_BITS-1:0]  iter;
    logic                       fold_active;

    // iter/fold_active are driven off valid_sr[0] (one cycle before pr1
    // becomes valid) so they're already primed to iter==0 by the cycle the
    // chain[0] mux below reads pr1 -- same timing convention as the
    // encode/sponge-xor stages above.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            iter        <= '0;
            fold_active <= 1'b0;
        end else if (valid_sr[0]) begin
            iter        <= '0;
            fold_active <= 1'b1;
        end else if (fold_active) begin
            if (iter == FOLD_ITER_BITS'(FOLD_ITERS - 1)) begin
                fold_active <= 1'b0;
                iter        <= '0;
            end else begin
                iter <= iter + 1'b1;
            end
        end
    end

    // Chain of STAGES purely-combinational keccak_round instances.
    // chain[0] = fold input, chain[STAGES] = fold output.
    logic [63:0] chain [0:STAGES][0:4][0:4];

    // iter==0 processing happens exactly on the cycle valid_sr[1] is high
    // (pr1 freshly valid); every other cycle continues looping fold_state.
    always_comb
        for (int x = 0; x < 5; x++)
            for (int y = 0; y < 5; y++)
                chain[0][x][y] = valid_sr[1]
                    ? pr1[(x + 5*y)*64 +: 64]
                    : fold_state[(x + 5*y)*64 +: 64];

    genvar fs;
    for (fs = 0; fs < STAGES; fs++) begin : g_fold_round
        // Round index for instance fs during iteration `iter`:
        //   iter*STAGES + fs, always in 0..23.
        wire [4:0] rc_idx;
        assign rc_idx = 5'(iter) * 5'(STAGES) + 5'(fs);

        keccak_round u_round (
            .state          (chain[fs]),
            .round_constant (RC[rc_idx]),
            .out            (chain[fs+1])
        );
    end

    // Gated by fold_active: with no enable, fold_state (and hence chain,
    // hash_out) would keep re-processing garbage through the round chain on
    // every idle cycle -- functionally harmless (nothing samples it except
    // on the one correct valid_out cycle) but needless switching activity in
    // both simulation and real hardware.
    always_ff @(posedge clk)
        if (fold_active)
            for (int x = 0; x < 5; x++)
                for (int y = 0; y < 5; y++)
                    fold_state[(x + 5*y)*64 +: 64] <= chain[STAGES][x][y];

    assign hash_out  = fold_state[255:0];
    // NOT the same tap as g_unfolded: fold_state's final update happens one
    // cycle after the fold's last combinational pass (the g_unfolded kstate
    // array has no such extra hop, each stage's own register captures the
    // final pass directly), so this needs valid_sr[LAT-1], not LAT-2.
    assign valid_out = valid_sr[LAT-1];
    // High from the cycle a hash's data becomes pending (valid_sr[0]) through
    // the last iteration of its fold -- conservative by construction, so a
    // second valid_in can never land on chain[0] while fold_active is 1.
    assign busy      = fold_active | valid_sr[0];
end
endgenerate
// -------------------------------------------------------------------------

endmodule
