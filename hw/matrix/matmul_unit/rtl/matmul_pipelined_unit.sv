// ===========================================================================
// matmul_pipelined_unit
// ---------------------------------------------------------------------------
// Fully pipelined KHeavyHash matrix-vector multiply: sustains 1 result/cycle
// no matter how the reduction is sliced, parametrized exactly like
// cshake256_pipelined_core.
//
//   result[i] = ( sum_{j=0..63} M[i][j] * v[j] ) >> 10     (4-bit nibble)
//
// Constant-coefficient multiply (KCM):
//   The matrix M is constant for a whole work unit (it only changes when a new
//   pre_pow_hash arrives), so each M[i][j]*v[j] product is a lookup, not a
//   multiplier.  Per (row i, column j) there is a 16-entry x 8-bit table
//   pp[i][j] with pp[i][j][v] = M[i][j] * v, read asynchronously with that
//   column's (stage-delayed) vector nibble and fed into the same reduction as
//   before.  Vivado maps each table byte to one SLICEM distributed-RAM LUT.
//   When the matrix changes, a small load FSM rebuilds all 4096 tables in
//   ~1024 cycles by accumulation (pp[k] = pp[k-1] + M[i][j]), time-shared to
//   one 8-bit adder per row.  matrix_reload pulses the rebuild; busy is high
//   while it runs and valid_in must be held low.  This is a one-time
//   per-work-unit gap; steady-state latency is unchanged (still NUM_STAGES).
//
// Matrix source is selected at compile time by INTERNAL_MATRIX:
//   * INTERNAL_MATRIX = 1 (default, for standalone TB): the 64x64 matrix is
//     stored in internal flops and loaded via the wr_matrix_* write port
//     (same layout as matrix_cache).
//   * INTERNAL_MATRIX = 0 (for in-core IP build): NO internal storage - the
//     matrix is taken combinationally from matrix_in, wired straight from the
//     widened matrix_cache (matrix_flat). The write port is unused.
//   Either way the load FSM sweeps that `matrix` net to build the KCM tables.
//
// The 64-term dot product for all 64 rows is computed in parallel and its
// summation is pipelined across NUM_STAGES register layers (segmented
// accumulation). Throughput is always 1 vector/cycle after LAT-cycle fill.
//
// Inter-stage accumulate on DSP48:
//   Stage 0 has no incoming accumulator (ain=0) and stays a plain fabric
//   register. Every later stage's ain[i]+part[i] add (14-bit, ACC_W) is
//   packed two rows at a time into one 48-bit DSP48 ALU add - 24-bit lanes
//   with 10 guard bits each, so carry from the low row's lane can never
//   reach the high row's. This is an ordinary wide two's-complement add
//   (use_dsp="yes"), not Xilinx's SIMD/dual-add OPMODE. 32 row-pairs x
//   (NUM_STAGES-1) real stages = 224 DSP48 at the default NUM_STAGES=8 (240
//   available on xc7k70t) - see the budget assert below; DSP demand scales
//   WITH NUM_STAGES (more stages = more concurrent in-flight accumulators),
//   so this packing is only budget-safe up to NUM_STAGES<=8 at N=64.
//   EXTRA_LAT adds optional output-register cycles after the last stage,
//   only needed if synthesis timing on the packed-add path requires it
//   (default 0, i.e. no latency change from the pre-DSP design).
//
// Vector forwarding is minimized: vector_in is de-swapped once into plain
// column order, then each stage consumes its COLS_PER_STAGE columns from the
// low nibbles and forwards ONLY the still-unused columns to the next stage.
// The carried vector therefore shrinks by one stage's columns each layer, so
// the total forwarding registers are the triangular sum 128*(NUM_STAGES-1)
// bits instead of NUM_STAGES*256.
//
//   NUM_STAGES = 1   -> 64 cols/stage : lowest Fmax, LAT = 1, fewest regs
//   NUM_STAGES = 64  ->  1 col/stage  : highest Fmax, LAT = 64, most regs
//   NUM_STAGES must divide 64.
//
// Nibble conventions match matrix_cache / gen_vectors.py:
//   * Matrix element M[i][j] is stored plainly at matrix[i][j].
//     matrix_in packing: matrix_in[(i*64 + j)*4 +: 4] = M[i][j]  (matches
//     matrix_cache.matrix_flat).
//   * Vector element for column j is read from vector_in[(j^1)*4 +: 4].
//   * Output element i is written to product_out[(i^1)*4 +: 4].
// ===========================================================================
module matmul_pipelined_unit #(
    parameter int NUM_STAGES     = 8,  // pipeline register layers; must divide 64
    parameter bit INTERNAL_MATRIX = 1, // 1: internal flops + write port (TB)
                                       // 0: matrix wired from matrix_in (IP)
    parameter int EXTRA_LAT      = 0   // extra output-register cycles for the
                                       // DSP48 packed-accumulate path; bump
                                       // only if synthesis timing needs it
) (
    input  logic         clk,
    input  logic         rst,

    // ---- Matrix load (INTERNAL_MATRIX=1 only; same layout as matrix_cache) --
    input  logic         wr_matrix_en,
    input  logic [7:0]   n16th_value,    // [7:2] = row, [1:0] = 16-element group
    input  logic [63:0]  wr_matrix_data, // 16 nibbles for the addressed group

    // ---- Wired matrix input (INTERNAL_MATRIX=0 only; from matrix_flat) ------
    input  logic [16383:0] matrix_in,    // matrix_in[(i*64+j)*4 +: 4] = M[i][j]

    // ---- KCM table (re)build ----
    input  logic         matrix_reload,  // 1-cycle pulse: rebuild all product tables
    output logic         busy,           // high while tables build; hold valid_in low

    // ---- Streaming vector interface (feed-forward, 1 vector/cycle) ----
    input  logic [255:0] vector_in,      // 64 x 4-bit nibbles (swapped packing)
    input  logic         valid_in,

    // ---- Streaming result (LAT cycles later) ----
    output logic [255:0] product_out,    // 64 x 4-bit nibbles (swapped packing)
    output logic         valid_out
);

    localparam int N              = 64;
    localparam int NIB            = 4;
    localparam int COLS_PER_STAGE = N / NUM_STAGES;
    localparam int ACC_W          = 14;  // max dot = 64*(15*15) = 14400 < 2^14
    localparam int LAT            = NUM_STAGES + EXTRA_LAT;

    initial begin
        assert (N % NUM_STAGES == 0)
            else $fatal(1, "NUM_STAGES (%0d) must divide 64", NUM_STAGES);
        // Each real stage (all but stage 0) packs 2 rows' accumulate-adds
        // into one DSP48 ALU add (32 pairs/stage); this must fit the
        // target part's DSP48 budget (240 on xc7k70t).
        assert ((NUM_STAGES - 1) * (N / 2) <= 240)
            else $warning("matmul_pipelined_unit: estimated DSP48 usage (%0d) exceeds 240 for NUM_STAGES=%0d",
                          (NUM_STAGES - 1) * (N / 2), NUM_STAGES);
    end

    // -----------------------------------------------------------------------
    // Matrix source: internal flops (write port) or wired-in (matrix_in).
    // Read only by the KCM load FSM (below); the datapath uses the tables.
    // -----------------------------------------------------------------------
    logic [3:0] matrix [0:N-1][0:N-1];

    generate
        if (INTERNAL_MATRIX) begin : g_matrix_internal
            // Stored in flops, written exactly like matrix_cache.
            always_ff @(posedge clk or posedge rst) begin
                if (rst) begin
                    for (int i = 0; i < N; i++)
                        for (int j = 0; j < N; j++)
                            matrix[i][j] <= '0;
                end else if (wr_matrix_en) begin
                    for (int k = 0; k < 16; k++)
                        matrix[n16th_value >> 2][(n16th_value % 4) * 16 + k]
                            <= wr_matrix_data[k*4 +: 4];
                end
            end
        end else begin : g_matrix_wired
            // No storage: combinational tap from the widened cache.
            always_comb
                for (int i = 0; i < N; i++)
                    for (int j = 0; j < N; j++)
                        matrix[i][j] = matrix_in[(i*N + j)*4 +: 4];
        end
    endgenerate

    // -----------------------------------------------------------------------
    // KCM load FSM: rebuild pp[i][j][k] = M[i][j]*k for k=0..15, one column at
    // a time, via accumulation (pp[k] = pp[k-1] + M[i][j]).  One 8-bit adder
    // per row (64), swept over 64 columns x 16 steps = 1024 cycles.
    // -----------------------------------------------------------------------
    typedef enum logic { LD_IDLE, LD_RUN } ld_state_t;
    ld_state_t  ld_state;
    logic [5:0] ld_col;        // column being built (0..63)
    logic [3:0] ld_k;          // table entry being written (0..15)
    logic [7:0] ld_run [0:N-1]; // running M[i][ld_col]*ld_k, per row
    logic       ld_we;

    assign ld_we = (ld_state == LD_RUN);
    assign busy  = (ld_state == LD_RUN);

    logic [3:0] mcol [0:N-1];  // matrix column selected by ld_col, per row
    always_comb
        for (int i = 0; i < N; i++)
            mcol[i] = matrix[i][ld_col];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ld_state <= LD_IDLE;
            ld_col   <= '0;
            ld_k     <= '0;
            for (int i = 0; i < N; i++) ld_run[i] <= '0;
        end else begin
            case (ld_state)
                LD_IDLE: begin
                    if (matrix_reload) begin
                        ld_state <= LD_RUN;
                        ld_col   <= '0;
                        ld_k     <= '0;
                        for (int i = 0; i < N; i++) ld_run[i] <= '0;
                    end
                end
                LD_RUN: begin
                    // pp[ld_col][ld_k] <= ld_run  is written by g_pp_col below.
                    for (int i = 0; i < N; i++)
                        ld_run[i] <= ld_run[i] + 8'(mcol[i]);
                    if (ld_k == 4'd15) begin
                        ld_k <= '0;
                        for (int i = 0; i < N; i++) ld_run[i] <= '0; // restart accum (last write wins)
                        if (ld_col == 6'd63) ld_state <= LD_IDLE;
                        else                 ld_col   <= ld_col + 6'd1;
                    end else begin
                        ld_k <= ld_k + 4'd1;
                    end
                end
                default: ld_state <= LD_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // De-swap vector_in into plain column packing (column j at nibble j) so a
    // stage reads its columns from the low nibbles and forwards the remainder.
    // -----------------------------------------------------------------------
    logic [N*NIB-1:0] vec_plain;
    always_comb
        for (int col = 0; col < N; col++)
            vec_plain[col*NIB +: NIB] = vector_in[(col ^ 1)*NIB +: NIB];

    // -----------------------------------------------------------------------
    // Pipeline: one accumulator layer per stage; only the still-unused vector
    // columns are registered and forwarded (shrinking each stage).
    // -----------------------------------------------------------------------
    logic [ACC_W-1:0] acc [0:NUM_STAGES-1][0:N-1];

    genvar st;
    generate
        for (st = 0; st < NUM_STAGES; st++) begin : g_stage
            localparam int COL_BASE = st * COLS_PER_STAGE;
            localparam int IN_COLS  = N - st * COLS_PER_STAGE;       // input width
            localparam int OUT_COLS = N - (st + 1) * COLS_PER_STAGE; // forwarded

            // This stage's plain-packed input vector (column COL_BASE at nibble 0).
            logic [IN_COLS*NIB-1:0] vin;
            if (st == 0) begin : g_vin
                assign vin = vec_plain;
            end else begin : g_vin
                assign vin = g_stage[st-1].g_fwd.fwd_q;
            end

            // KCM product tables for this stage's columns: pp_rdata[row][c] =
            // M[row][COL_BASE+c] * vin_nibble(c).  One 16x8 distributed RAM per
            // (row, column); async read, sync write from the load FSM.
            logic [7:0] pp_rdata [0:N-1][0:COLS_PER_STAGE-1];
            genvar gi, gc;
            for (gi = 0; gi < N; gi++) begin : g_pp_row
                for (gc = 0; gc < COLS_PER_STAGE; gc++) begin : g_pp_col
                    localparam int ABS_COL = COL_BASE + gc;
                    (* ram_style = "distributed" *) logic [7:0] tbl [0:15];
                    always_ff @(posedge clk)
                        if (ld_we && (ld_col == 6'(ABS_COL)))
                            tbl[ld_k] <= ld_run[gi];
                    assign pp_rdata[gi][gc] = tbl[vin[gc*NIB +: NIB]];
                end
            end

            // Incoming accumulator (0 at the head, previous layer otherwise).
            logic [ACC_W-1:0] ain [0:N-1];
            if (st == 0) begin : g_ain
                always_comb for (int i = 0; i < N; i++) ain[i] = '0;
            end else begin : g_ain
                always_comb for (int i = 0; i < N; i++) ain[i] = acc[st-1][i];
            end

            // Partial dot product over this stage's COLS_PER_STAGE columns.
            logic [ACC_W-1:0] part [0:N-1];
            always_comb begin
                for (int i = 0; i < N; i++) begin
                    logic [ACC_W-1:0] s;
                    s = '0;
                    for (int c = 0; c < COLS_PER_STAGE; c++)
                        s = s + ACC_W'(pp_rdata[i][c]);
                    part[i] = s;
                end
            end

            // Accumulator register.
            //
            // Stage 0 is a pass-through (ain==0), so it stays a plain fabric
            // add. Every later stage packs 2 independent rows' 14-bit adds
            // into one 48-bit DSP48 ALU add: ACC_W=14 so ain+part needs only
            // 15 bits, and a 24-bit lane per row leaves 10 guard bits - the
            // carry out of the low lane can never reach the high lane. This
            // is a plain wide two's-complement add (not the SIMD/dual-add
            // OPMODE, which needs explicit CARRYINSEL/ALUMODE wiring), so
            // use_dsp="yes" reliably maps it onto one DSP48 ALU per pair.
            // 32 pairs x (NUM_STAGES-1) real stages = 224 DSP48 at the
            // default NUM_STAGES=8 (240 available) - see the budget assert
            // above.
            if (st == 0) begin : g_acc
                always_ff @(posedge clk or posedge rst) begin
                    if (rst)
                        for (int i = 0; i < N; i++) acc[st][i] <= '0;
                    else
                        for (int i = 0; i < N; i++) acc[st][i] <= part[i];
                end
            end else begin : g_acc
                localparam int LANE_W = 24;  // ACC_W=14 + 10 guard bits
                genvar gp;
                for (gp = 0; gp < N/2; gp++) begin : g_pair
                    localparam int R0 = gp*2;
                    localparam int R1 = gp*2 + 1;
                    (* use_dsp = "yes" *) logic [2*LANE_W-1:0] wide_sum;
                    always_comb
                        wide_sum = { {(LANE_W-ACC_W){1'b0}}, ain[R1],  {(LANE_W-ACC_W){1'b0}}, ain[R0]  }
                                 + { {(LANE_W-ACC_W){1'b0}}, part[R1], {(LANE_W-ACC_W){1'b0}}, part[R0] };
                    always_ff @(posedge clk or posedge rst) begin
                        if (rst) begin
                            acc[st][R0] <= '0;
                            acc[st][R1] <= '0;
                        end else begin
                            acc[st][R0] <= wide_sum[ACC_W-1:0];
                            acc[st][R1] <= wide_sum[LANE_W+ACC_W-1:LANE_W];
                        end
                    end
                end
            end

            // Forward only the columns the downstream stages still need.
            if (OUT_COLS > 0) begin : g_fwd
                logic [OUT_COLS*NIB-1:0] fwd_q;
                always_ff @(posedge clk or posedge rst) begin
                    if (rst) fwd_q <= '0;
                    else     fwd_q <= vin[COLS_PER_STAGE*NIB +: OUT_COLS*NIB];
                end
            end
        end
    endgenerate

    // Valid pipeline (array-based shift so NUM_STAGES == 1 is legal).
    // valid_in is squashed while the KCM tables are being rebuilt.
    logic valid_pipe [0:NUM_STAGES-1];
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int s = 0; s < NUM_STAGES; s++) valid_pipe[s] <= 1'b0;
        end else begin
            valid_pipe[0] <= valid_in & ~busy;
            for (int s = 1; s < NUM_STAGES; s++)
                valid_pipe[s] <= valid_pipe[s-1];
        end
    end

    // Optional extra pipeline tail after the last accumulate stage, only
    // needed if the packed-DSP accumulate path fails timing (EXTRA_LAT=0
    // collapses this to plain wiring, matching the pre-DSP latency).
    logic [ACC_W-1:0] acc_final [0:N-1];
    logic             valid_final;
    if (EXTRA_LAT == 0) begin : g_tail
        assign acc_final   = acc[NUM_STAGES-1];
        assign valid_final = valid_pipe[NUM_STAGES-1];
    end else begin : g_tail
        logic [ACC_W-1:0] tail [0:EXTRA_LAT-1][0:N-1];
        logic             tail_valid [0:EXTRA_LAT-1];
        always_ff @(posedge clk or posedge rst) begin
            if (rst) begin
                for (int k = 0; k < EXTRA_LAT; k++) begin
                    for (int i = 0; i < N; i++) tail[k][i] <= '0;
                    tail_valid[k] <= 1'b0;
                end
            end else begin
                for (int i = 0; i < N; i++) tail[0][i] <= acc[NUM_STAGES-1][i];
                tail_valid[0] <= valid_pipe[NUM_STAGES-1];
                for (int k = 1; k < EXTRA_LAT; k++) begin
                    for (int i = 0; i < N; i++) tail[k][i] <= tail[k-1][i];
                    tail_valid[k] <= tail_valid[k-1];
                end
            end
        end
        assign acc_final   = tail[EXTRA_LAT-1];
        assign valid_final = tail_valid[EXTRA_LAT-1];
    end

    // Output: >>10 truncation to a nibble, with the row^1 output swap.
    always_comb begin
        product_out = '0;
        for (int i = 0; i < N; i++)
            product_out[(i ^ 1)*4 +: 4] = acc_final[i][13:10];
    end

    assign valid_out = valid_final;

endmodule
