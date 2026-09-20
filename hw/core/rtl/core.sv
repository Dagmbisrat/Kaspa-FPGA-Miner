// kHeavyHash Mining Core — streaming (1 nonce/cycle) pipeline
// ---------------------------------------------------------------------------
// Per block: if the incoming pre_pow_hash differs from the one the cached matrix
// was built for, (re)generate the matrix (blocking). Otherwise stream straight
// into the non-blocking pipeline:
//
//   nonce++ -> cshake1 -> matmul -> XOR(pow_hash) -> cshake2 -> hash_out
//
// pow_hash (per-nonce cSHAKE1 output) is both the matmul vector and, delayed by
// the matmul latency, the XOR operand for the digest. The nonce is carried down
// a matched delay line so each streamed hash_out is tagged with its nonce.
// ---------------------------------------------------------------------------
module core #(
    parameter int CSHAKE_STAGES = 24,     // cSHAKE pipeline layers; must divide 24
    parameter int MATMUL_STAGES = 8,      // matmul pipeline layers; must divide 64
    // Shared by both cSHAKE instances (not independent): Cshake1/Cshake2 are
    // equal-cost, so folding only one would still cap throughput to the
    // folded one's rate while wasting the other's area savings -- fold both
    // or neither. This also sidesteps a correctness issue found in the
    // mixed case: an unfolded cshake fed single isolated pulses (as the
    // g_serialized admission below does once folding is in play) showed a
    // one-cycle valid_out/hash_out misalignment not seen when both
    // instances share the same fold state. Both-folded and both-unfolded
    // are verified correct; mixed is not supported.
    parameter bit CSHAKE_FOLDED = 1'b0
) (
    input  logic         clk,
    input  logic         rst,

    input  logic         start,        // pulse to load a block and begin streaming

    input  logic [255:0] pre_pow_hash,  // matrix seed + header, stable per block
    input  logic [63:0]  timestamp,     // little-endian uint64
    input  logic [63:0]  nonce,         // starting nonce for the stream

    input  logic [255:0] target,        // difficulty target; hash <= target passes

    output logic [255:0] hash_out,      // streamed final hash
    output logic [63:0]  nonce_out,     // nonce that produced hash_out
    output logic         valid_out,     // high when hash_out/nonce_out are valid
    output logic         found,         // pulse: a streamed hash met the target
    output logic [63:0]  found_nonce,   // winning nonce
    output logic [7:0]   found_work_id  // job/work id the winning nonce belongs to
);

    // ---- Pipeline latencies ----
    localparam int M_LAT = MATMUL_STAGES;   // matmul valid_in->valid_out
    localparam int WID   = 8;               // work/job id width

    // Cshake's own per-item PROCESSING latency (admit -> THIS item's own
    // valid_out), regardless of admission rate. Matches
    // cshake256_pipelined_core's own internal LAT parameter exactly in
    // both fold modes.
    localparam int C_LAT_CSHAKE = CSHAKE_FOLDED ? (24/CSHAKE_STAGES + 2) : (CSHAKE_STAGES + 2);

    // Cshake's own admission RATE (how often a NEW item can be accepted).
    // Folded: single-token, admission rate == processing latency.
    // Unfolded: busy hardwired 0, no gating -- a new item every cycle.
    localparam int N_CSHAKE = CSHAKE_FOLDED ? C_LAT_CSHAKE : 1;

    // matmul's own sustainable admission rate (hardcoded 1 -- no fold
    // support today; the one line to change if/when matmul ever gains its
    // own FOLDED parameter).
    localparam int N_MATMUL = 1;

    localparam int N_MAX = (N_CSHAKE > N_MATMUL) ? N_CSHAKE : N_MATMUL;

    // Fixed round-trip PROCESSING latency: cshake1 + matmul + cshake2.
    localparam int TOTAL_LAT = C_LAT_CSHAKE + M_LAT + C_LAT_CSHAKE;

    // ---- Control FSM ----
    // IDLE -> GEN (new matrix) -> LOAD (rebuild matmul KCM tables) -> STREAM.
    typedef enum logic [1:0] { IDLE = 2'b00, GEN = 2'b01, STREAM = 2'b10, LOAD = 2'b11 } state_t;
    state_t state;
    logic   gen_ack;   // generator acknowledged start (done went low) — avoids stale done
    logic   mm_reload; // one-shot: tell matmul to rebuild its KCM product tables
    logic   mm_busy;   // matmul is rebuilding tables (from Matmul.busy)
    logic   load_seen; // saw mm_busy rise — avoids racing straight through LOAD

    // ---- Block context ----
    logic [255:0] blk_pph;    // pph of the block currently being mined
    logic [255:0] pph_reg;    // pph the cached matrix was generated for
    logic [63:0]  ts_reg;
    logic [63:0]  nonce_ctr;
    logic [255:0] tgt_reg;      // difficulty target for the current work
    logic [WID-1:0] work_id;    // increments per new work (job) load

    // ======================================================================
    // Matrix cache (widened: matrix_flat exposes the whole matrix in parallel)
    // ======================================================================
    logic          wr_matrix_en, wr_PrePowHash_en;
    logic [7:0]    n16th_value;
    logic [63:0]   wr_matrix_data;
    logic [255:0]  wr_PrePowHash;
    logic          rd_en;
    logic [5:0]    rd_row;
    logic [255:0]  rd_row_data, rd_PrePowHash;
    logic [16383:0] matrix_flat;

    matrix_cache Cache (
        .clk(clk), .rst(rst),
        .wr_matrix_en(wr_matrix_en),
        .wr_PrePowHash_en(wr_PrePowHash_en),
        .n16th_value(n16th_value),
        .wr_matrix_data(wr_matrix_data),
        .wr_PrePowHash(wr_PrePowHash),
        .rd_en(rd_en),
        .rd_row(rd_row),
        .rd_row_data(rd_row_data),
        .rd_PrePowHash(rd_PrePowHash),
        .matrix_flat(matrix_flat)
    );

    // ======================================================================
    // Matrix generator (blocking, once per new block)
    // ======================================================================
    logic        matrix_gen_start, matrix_gen_done;
    logic        matrix_gen_wr_matrix_en, matrix_gen_wr_PrePowHash_en;
    logic [7:0]  matrix_gen_n16th_value;
    logic [63:0] matrix_gen_wr_matrix_data;
    logic        matrix_gen_rd_en;
    logic [5:0]  matrix_gen_rd_row;

    matrix_generator MatrixGen (
        .clk(clk), .rst(rst),
        .start(matrix_gen_start),
        .PrePowHash(blk_pph),
        .done(matrix_gen_done),
        .wr_matrix_en(matrix_gen_wr_matrix_en),
        .wr_PrePowHash_en(matrix_gen_wr_PrePowHash_en),
        .n16th_value(matrix_gen_n16th_value),
        .wr_matrix_data(matrix_gen_wr_matrix_data),
        .rd_en(matrix_gen_rd_en),
        .rd_row(matrix_gen_rd_row),
        .rd_row_data(rd_row_data),
        .rd_PrePowHash(rd_PrePowHash)
    );

    // Cache writes come only from the generator; the row-read port is used only
    // by the generator's rank check (the matmul reads matrix_flat in parallel).
    assign wr_matrix_en     = matrix_gen_wr_matrix_en;
    assign wr_PrePowHash_en = matrix_gen_wr_PrePowHash_en;
    assign n16th_value      = matrix_gen_n16th_value;
    assign wr_matrix_data   = matrix_gen_wr_matrix_data;
    assign wr_PrePowHash    = blk_pph;
    assign rd_en            = matrix_gen_rd_en;
    assign rd_row           = matrix_gen_rd_row;

    // ======================================================================
    // Streaming pipeline
    // ======================================================================
    logic stream_valid;
    logic admit;
    logic c1_busy, c2_busy;
    logic [WID-1:0] work_out;

    // 80-byte header: pre_pow_hash | timestamp | 256'b0 | nonce
    logic [639:0] header;
    assign header = {nonce_ctr, 256'b0, ts_reg, blk_pph};

    // cSHAKE1 (ProofOfWorkHash, 80-byte) -> pow_hash
    logic [255:0] pow_hash;
    logic         c1_valid;
    cshake256_pipelined_core #(
        .FOLDED(CSHAKE_FOLDED), .STAGES(CSHAKE_STAGES),
        .S_VALUE(1'b0), .DATA_80BYTE(1'b1)
    ) Cshake1 (
        .clk(clk), .rst(rst),
        .data_in(header),
        .valid_in(stream_valid),
        .hash_out(pow_hash),
        .valid_out(c1_valid),
        .busy(c1_busy)
    );

    // matmul: vector_in = pow_hash directly (swapped nibble packing matches).
    logic [255:0] product;
    logic         m_valid;
    matmul_pipelined_unit #(
        .NUM_STAGES(MATMUL_STAGES), .INTERNAL_MATRIX(1'b0)
    ) Matmul (
        .clk(clk), .rst(rst),
        .wr_matrix_en(1'b0), .n16th_value(8'b0), .wr_matrix_data(64'b0),
        .matrix_in(matrix_flat),
        .matrix_reload(mm_reload),
        .busy(mm_busy),
        .vector_in(pow_hash),
        .valid_in(c1_valid),
        .product_out(product),
        .valid_out(m_valid)
    );

    // Delay pow_hash by the matmul latency so product ^ pow_hash stays per-nonce.
    logic [255:0] ph_delay [0:M_LAT-1];
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            for (int k = 0; k < M_LAT; k++) ph_delay[k] <= '0;
        else begin
            ph_delay[0] <= pow_hash;
            for (int k = 1; k < M_LAT; k++) ph_delay[k] <= ph_delay[k-1];
        end
    end
    logic [255:0] digest;
    assign digest = product ^ ph_delay[M_LAT-1];

    // cSHAKE2 (HeavyHash, 32-byte) -> final hash
    cshake256_pipelined_core #(
        .FOLDED(CSHAKE_FOLDED), .STAGES(CSHAKE_STAGES),
        .S_VALUE(1'b1), .DATA_80BYTE(1'b0)
    ) Cshake2 (
        .clk(clk), .rst(rst),
        .data_in({384'b0, digest}),
        .valid_in(m_valid),
        .hash_out(hash_out),
        .valid_out(valid_out),
        .busy(c2_busy)
    );

    // ======================================================================
    // Admission control: a single periodic counter paced at N_MAX =
    // max(cshake's own rate, matmul's own rate), direct unbuffered wiring
    // to Matmul/Cshake2 (already unconditional at module scope), and a tag
    // FIFO spanning the admit -> final-valid_out round trip. Degenerates to
    // N_MAX=1 in the default/unfolded config, where admit_ctr is provably
    // pinned at 0 forever and admit reduces to exactly (state==STREAM) --
    // bit-for-bit identical to the pipeline's original admission timing.
    // ======================================================================
    localparam int N_MAX_BITS = (N_MAX > 1) ? $clog2(N_MAX) : 1;
    logic [N_MAX_BITS-1:0] admit_ctr;
    always_ff @(posedge clk or posedge rst) begin
        if (rst || start || state != STREAM) admit_ctr <= '0;
        else if (admit_ctr == N_MAX-1)        admit_ctr <= '0;
        else                                   admit_ctr <= admit_ctr + 1'b1;
    end
    assign admit = (state == STREAM) && (admit_ctr == '0) && !c1_busy;

    // ---- Tag FIFO: push on admit, pop on final valid_out. Sized to the
    // exact peak occupancy (P=N_MAX push spacing, L=TOTAL_LAT item
    // lifetime, peak = ceil(L/P)) -- no power-of-2 padding, explicit
    // wraparound compare instead. ----
    localparam int TAG_SLOTS = (TOTAL_LAT + N_MAX - 1) / N_MAX;
    localparam int TAG_ABITS = (TAG_SLOTS <= 1) ? 1 : $clog2(TAG_SLOTS);

    logic [63:0]    tag_nonce [0:TAG_SLOTS-1];
    logic [WID-1:0] tag_work  [0:TAG_SLOTS-1];
    logic [TAG_ABITS-1:0] tag_wr_ptr, tag_rd_ptr;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            tag_wr_ptr <= '0; tag_rd_ptr <= '0;
        end else begin
            // Not reset by `start` (only rst) -- an abandoned in-flight
            // entry still drains and gets correctly rejected by the
            // work_out==work_id staleness check below.
            if (admit) begin
                tag_nonce[tag_wr_ptr] <= nonce_ctr;
                tag_work[tag_wr_ptr]  <= work_id;
                tag_wr_ptr <= (tag_wr_ptr == TAG_SLOTS-1) ? '0 : tag_wr_ptr + 1'b1;
            end
            if (valid_out) tag_rd_ptr <= (tag_rd_ptr == TAG_SLOTS-1) ? '0 : tag_rd_ptr + 1'b1;
        end
    end
    assign nonce_out = tag_nonce[tag_rd_ptr];
    assign work_out  = tag_work[tag_rd_ptr];

    `ifndef SYNTHESIS
    logic [31:0] tag_occ;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) tag_occ <= '0;
        else     tag_occ <= tag_occ + (admit ? 32'd1 : 32'd0) - (valid_out ? 32'd1 : 32'd0);
    end
    always_ff @(posedge clk)
        if (!rst) assert (tag_occ <= TAG_SLOTS) else
            $fatal(1, "tag FIFO overflow: occ=%0d slots=%0d", tag_occ, TAG_SLOTS);

    // matmul's own KCM-rebuild busy can squash a valid_in with no
    // corresponding valid_out ever appearing -- unrelated to admission,
    // kept as regression-proofing. Margin holds identically in both fold
    // modes (matrix_generator's GEN phase is >=256 cycles regardless;
    // worst-case C_LAT_CSHAKE is 26 either way).
    always_ff @(posedge clk)
        if (!rst) assert (!(c1_valid && mm_busy)) else
            $fatal(1, "cshake1 valid_out collided with matmul KCM reload -- token silently dropped");
    `endif

    assign stream_valid = admit;

    // Target compare (tail stage). kaspad's pow.toBig() treats the hash as
    // little-endian, which is exactly how hash_out is packed, so the raw 256-bit
    // hash_out <= target matches kaspad's CheckProofOfWork (no byte swap).
    wire hit = valid_out && (work_out == work_id) && (hash_out <= tgt_reg);
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            found         <= 1'b0;
            found_nonce   <= '0;
            found_work_id <= '0;
        end else begin
            found <= hit;
            if (hit) begin
                found_nonce   <= nonce_out;
                found_work_id <= work_out;
            end
        end
    end

    // ======================================================================
    // Control: load block on start, (re)generate matrix only on a new pph.
    // ======================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= IDLE;
            blk_pph          <= '0;
            pph_reg          <= '0;
            ts_reg           <= '0;
            nonce_ctr        <= '0;
            tgt_reg          <= '0;
            work_id          <= '0;
            matrix_gen_start <= 1'b0;
            gen_ack          <= 1'b0;
            mm_reload        <= 1'b0;
            load_seen        <= 1'b0;
        end else begin
            matrix_gen_start <= 1'b0;   // one-shot default
            mm_reload        <= 1'b0;   // one-shot default

            if (start) begin
                // Load a (possibly new) block and decide gen-vs-stream.
                blk_pph   <= pre_pow_hash;
                ts_reg    <= timestamp;
                nonce_ctr <= nonce;
                tgt_reg   <= target;
                work_id   <= work_id + 1'b1;
                if (pre_pow_hash != pph_reg) begin
                    matrix_gen_start <= 1'b1;   // seeds MatrixGen next cycle
                    gen_ack          <= 1'b0;   // wait for a fresh done (not the stale level)
                    state            <= GEN;
                end else begin
                    state <= STREAM;            // matrix already cached
                end
            end else begin
                case (state)
                    GEN: begin
                        if (!matrix_gen_done)
                            gen_ack <= 1'b1;              // generator started (done cleared)
                        if (gen_ack && matrix_gen_done) begin
                            pph_reg   <= blk_pph;
                            mm_reload <= 1'b1;            // rebuild matmul KCM tables
                            load_seen <= 1'b0;
                            state     <= LOAD;
                        end
                    end
                    LOAD: begin
                        // Wait for the matmul KCM rebuild: see busy rise, then fall.
                        if (mm_busy)               load_seen <= 1'b1;
                        if (load_seen && !mm_busy) state     <= STREAM;
                    end
                    STREAM: begin
                        if (admit) nonce_ctr <= nonce_ctr + 64'd1;
                    end
                    default: ; // IDLE waits for start
                endcase
            end
        end
    end

endmodule
