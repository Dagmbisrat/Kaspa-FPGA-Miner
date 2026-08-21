// ===========================================================================
// matmul_pipelined_unit
// ---------------------------------------------------------------------------
// Fully pipelined KHeavyHash matrix-vector multiply: sustains 1 result/cycle
// no matter how the reduction is sliced, parametrized exactly like
// cshake256_pipelined_core.
//
//   result[i] = ( sum_{j=0..63} M[i][j] * v[j] ) >> 10     (4-bit nibble)
//
// Matrix source is selected at compile time by INTERNAL_MATRIX:
//   * INTERNAL_MATRIX = 1 (default, for standalone TB): the 64x64 matrix is
//     stored in internal flops and loaded via the wr_matrix_* write port
//     (same layout as matrix_cache).
//   * INTERNAL_MATRIX = 0 (for in-core IP build): NO internal storage — the
//     matrix is taken combinationally from matrix_in, wired straight from the
//     widened matrix_cache (matrix_flat). The write port is unused.
//
// The 64-term dot product for all 64 rows is computed in parallel and its
// summation is pipelined across NUM_STAGES register layers (segmented
// accumulation). Throughput is always 1 vector/cycle after LAT-cycle fill.
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
    parameter bit INTERNAL_MATRIX = 1  // 1: internal flops + write port (TB)
                                       // 0: matrix wired from matrix_in (IP)
) (
    input  logic         clk,
    input  logic         rst,

    // ---- Matrix load (INTERNAL_MATRIX=1 only; same layout as matrix_cache) --
    input  logic         wr_matrix_en,
    input  logic [7:0]   n16th_value,    // [7:2] = row, [1:0] = 16-element group
    input  logic [63:0]  wr_matrix_data, // 16 nibbles for the addressed group

    // ---- Wired matrix input (INTERNAL_MATRIX=0 only; from matrix_flat) ------
    input  logic [16383:0] matrix_in,    // matrix_in[(i*64+j)*4 +: 4] = M[i][j]

    // ---- Streaming vector interface (feed-forward, 1 vector/cycle) ----
    input  logic [255:0] vector_in,      // 64 x 4-bit nibbles (swapped packing)
    input  logic         valid_in,

    // ---- Streaming result (LAT cycles later) ----
    output logic [255:0] product_out,    // 64 x 4-bit nibbles (swapped packing)
    output logic         valid_out
);

    localparam int N              = 64;
    localparam int COLS_PER_STAGE = N / NUM_STAGES;
    localparam int ACC_W          = 14;  // max dot = 64*(15*15) = 14400 < 2^14
    localparam int LAT            = NUM_STAGES;

    initial begin
        assert (N % NUM_STAGES == 0)
            else $fatal(1, "NUM_STAGES (%0d) must divide 64", NUM_STAGES);
    end

    // -----------------------------------------------------------------------
    // Matrix source: internal flops (write port) or wired-in (matrix_in).
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
    // Pipeline state: one accumulator layer and one vector copy per stage.
    // -----------------------------------------------------------------------
    logic [ACC_W-1:0] acc      [0:NUM_STAGES-1][0:N-1];
    logic [255:0]     vec_pipe [0:NUM_STAGES-1];
    logic             valid_pipe [0:NUM_STAGES-1];

    genvar st;
    generate
        for (st = 0; st < NUM_STAGES; st++) begin : g_stage
            localparam int COL_BASE = st * COLS_PER_STAGE;

            logic [255:0]     vin;
            logic [ACC_W-1:0] ain [0:N-1];

            if (st == 0) begin : g_src
                assign vin = vector_in;
                always_comb
                    for (int i = 0; i < N; i++) ain[i] = '0;
            end else begin : g_src
                assign vin = vec_pipe[st-1];
                always_comb
                    for (int i = 0; i < N; i++) ain[i] = acc[st-1][i];
            end

            logic [ACC_W-1:0] part [0:N-1];
            always_comb begin
                for (int i = 0; i < N; i++) begin
                    logic [ACC_W-1:0] s;
                    s = '0;
                    for (int c = 0; c < COLS_PER_STAGE; c++) begin
                        automatic int col = COL_BASE + c;
                        s = s + ACC_W'(matrix[i][col]
                                       * vin[(col ^ 1)*4 +: 4]);
                    end
                    part[i] = s;
                end
            end

            always_ff @(posedge clk or posedge rst) begin
                if (rst) begin
                    vec_pipe[st] <= '0;
                    for (int i = 0; i < N; i++) acc[st][i] <= '0;
                end else begin
                    vec_pipe[st] <= vin;
                    for (int i = 0; i < N; i++)
                        acc[st][i] <= ain[i] + part[i];
                end
            end
        end
    endgenerate

    // Valid pipeline (array-based shift so NUM_STAGES == 1 is legal).
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int s = 0; s < NUM_STAGES; s++) valid_pipe[s] <= 1'b0;
        end else begin
            valid_pipe[0] <= valid_in;
            for (int s = 1; s < NUM_STAGES; s++)
                valid_pipe[s] <= valid_pipe[s-1];
        end
    end

    // Output: >>10 truncation to a nibble, with the row^1 output swap.
    always_comb begin
        product_out = '0;
        for (int i = 0; i < N; i++)
            product_out[(i ^ 1)*4 +: 4] = acc[NUM_STAGES-1][i][13:10];
    end

    assign valid_out = valid_pipe[NUM_STAGES-1];

endmodule
