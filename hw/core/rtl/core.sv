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
    parameter int CSHAKE_STAGES = 24,  // cSHAKE pipeline layers; must divide 24
    parameter int MATMUL_STAGES = 8    // matmul pipeline layers; must divide 64
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
    localparam int C_LAT     = CSHAKE_STAGES + 2;      // cSHAKE valid_in->valid_out
    localparam int M_LAT     = MATMUL_STAGES;          // matmul valid_in->valid_out
    localparam int TOTAL_LAT = C_LAT + M_LAT + C_LAT;  // cshake1 + matmul + cshake2
    localparam int WID       = 8;                      // work/job id width

    // ---- Control FSM ----
    typedef enum logic [1:0] { IDLE = 2'b00, GEN = 2'b01, STREAM = 2'b10 } state_t;
    state_t state;
    logic   gen_ack;   // generator acknowledged start (done went low) — avoids stale done

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
    assign stream_valid = (state == STREAM);

    // 80-byte header: pre_pow_hash | timestamp | 256'b0 | nonce
    logic [639:0] header;
    assign header = {nonce_ctr, 256'b0, ts_reg, blk_pph};

    // cSHAKE1 (ProofOfWorkHash, 80-byte) -> pow_hash
    logic [255:0] pow_hash;
    logic         c1_valid;
    cshake256_pipelined_core #(
        .NUM_STAGES(CSHAKE_STAGES), .S_VALUE(1'b0), .DATA_80BYTE(1'b1)
    ) Cshake1 (
        .clk(clk), .rst(rst),
        .data_in(header),
        .valid_in(stream_valid),
        .hash_out(pow_hash),
        .valid_out(c1_valid)
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
        .NUM_STAGES(CSHAKE_STAGES), .S_VALUE(1'b1), .DATA_80BYTE(1'b0)
    ) Cshake2 (
        .clk(clk), .rst(rst),
        .data_in({384'b0, digest}),
        .valid_in(m_valid),
        .hash_out(hash_out),
        .valid_out(valid_out)
    );

    // Carry the nonce alongside the whole pipeline so hits map back to a nonce.
    logic [63:0] nonce_delay [0:TOTAL_LAT-1];
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            for (int k = 0; k < TOTAL_LAT; k++) nonce_delay[k] <= '0;
        else begin
            nonce_delay[0] <= nonce_ctr;
            for (int k = 1; k < TOTAL_LAT; k++) nonce_delay[k] <= nonce_delay[k-1];
        end
    end
    assign nonce_out = nonce_delay[TOTAL_LAT-1];

    // Carry the work id alongside so a hit is attributed to the right job and
    // stale in-flight results from a previous job are ignored.
    logic [WID-1:0] work_delay [0:TOTAL_LAT-1];
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            for (int k = 0; k < TOTAL_LAT; k++) work_delay[k] <= '0;
        else begin
            work_delay[0] <= work_id;
            for (int k = 1; k < TOTAL_LAT; k++) work_delay[k] <= work_delay[k-1];
        end
    end

    // Target compare (tail stage). NOTE: hash_out is compared as a raw 256-bit
    // unsigned value; confirm the byte order against kaspad before production.
    wire [WID-1:0] work_out = work_delay[TOTAL_LAT-1];
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
        end else begin
            matrix_gen_start <= 1'b0;   // one-shot default

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
                            pph_reg <= blk_pph;
                            state   <= STREAM;
                        end
                    end
                    STREAM: begin
                        nonce_ctr <= nonce_ctr + 64'd1;
                    end
                    default: ; // IDLE waits for start
                endcase
            end
        end
    end

endmodule
