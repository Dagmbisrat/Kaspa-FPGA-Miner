// matrix_rankcheck.sv
//
// Determines whether the 64×64 4-bit matrix held in matrix_cache is full rank
// using Gaussian elimination over GF(2).
//
// Each cache row is 256 bits (64 nibbles × 4 bits). Those 256 bits are treated
// as a vector in GF(2)^256. Gaussian elimination on the 64 row vectors finds
// how many are linearly independent; full_rank is asserted when that count = 64.
//
// Timing (cycles):
//   LOAD  : 64  — one cache read issued per cycle (1-cycle latency)
//   FLUSH :  1  — drain last row from cache pipeline
//   ELIM  : ≤256 — one column processed per cycle; exits early when rank = 64
//   DONE  :  1  — assert done
//   Total : ≤322 cycles worst case, ~130 typical for a full-rank matrix

module matrix_rankcheck (
    input  logic          clk,
    input  logic          rst,
    input  logic          start,
    output logic          done,
    output logic          full_rank,
    // Cache read interface
    output logic          rd_en,
    output logic [5:0]    rd_row,
    input  logic [255:0]  rd_row_data
);

  // ── FSM ──────────────────────────────────────────────────────────────────
  typedef enum logic [2:0] {
    IDLE  = 3'd0,
    LOAD  = 3'd1,   // issue reads for rows 0..63
    FLUSH = 3'd2,   // drain last row from cache pipeline
    ELIM  = 3'd3,   // GF(2) Gaussian elimination
    DONE  = 3'd4
  } state_t;
  state_t state;

  // ── Working matrix ────────────────────────────────────────────────────────
  // 64 rows, each 256 bits — the GF(2) row vectors under elimination.
  logic [255:0] M [64];

  // ── Counters ──────────────────────────────────────────────────────────────
  logic [5:0] load_idx;   // which row is being requested from cache
  logic [7:0] col;        // column bit currently being eliminated (0..255)
  logic [6:0] rank;       // number of pivot rows found so far   (0..64)

  // ── Pivot search (combinational, unrolled) ────────────────────────────────
  // Scans rows 63..0, keeping the lowest-indexed row r ≥ rank with M[r][col]=1.
  // The reverse loop + last-assignment-wins gives lowest-index priority.
  logic        pivot_found;
  logic [5:0]  pivot_row;

  always_comb begin
    pivot_found = 1'b0;
    pivot_row   = 6'h0;
    for (int r = 63; r >= 0; r--) begin
      if (7'(unsigned'(r)) >= rank && M[r][col]) begin
        pivot_found = 1'b1;
        pivot_row   = 6'(unsigned'(r));
      end
    end
  end

  // ── Sequential logic ──────────────────────────────────────────────────────
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      state    <= IDLE;
      done     <= 1'b0;
      full_rank<= 1'b0;
      load_idx <= '0;
      col      <= '0;
      rank     <= '0;
      for (int i = 0; i < 64; i++) M[i] <= '0;

    end else begin
      case (state)

        // ────────────────────────────────────────────────────────────────────
        IDLE: begin
          if (start) begin
            done     <= 1'b0;
            full_rank<= 1'b0;
            load_idx <= '0;
            col      <= '0;
            rank     <= '0;
            state    <= LOAD;
          end
        end

        // ────────────────────────────────────────────────────────────────────
        // Issue cache reads for rows 0..63.
        // Cache has 1-cycle read latency: data for row (load_idx−1) arrives
        // on the current clock edge.
        LOAD: begin
          if (load_idx < 6'd63)
            load_idx <= load_idx + 1'b1;
          else
            state <= FLUSH;

          // Capture the row that was requested on the previous cycle.
          // Skip cycle 0 (load_idx==0): no prior request has been issued yet.
          if (load_idx != 6'h0)
            M[load_idx - 1'b1] <= rd_row_data;
        end

        // ────────────────────────────────────────────────────────────────────
        // Row 63 was requested on the last LOAD cycle; capture its data now.
        FLUSH: begin
          M[63] <= rd_row_data;
          state <= ELIM;
        end

        // ────────────────────────────────────────────────────────────────────
        // GF(2) Gaussian elimination — one column bit per clock cycle.
        //
        // For column `col`:
        //   1. Combinationally find the lowest row r ≥ rank with M[r][col]=1.
        //   2. Swap M[pivot_row] and M[rank] (bring pivot to the rank slot).
        //   3. XOR the pivot into every other row that has bit `col` set,
        //      clearing that bit from the entire column.
        //   4. Increment rank; advance col; check termination.
        //
        // Non-blocking assignment semantics ensure all RHS reads in a single
        // always_ff body see the PRE-edge values of M, so the pivot value
        // used in every XOR is consistent and the two-register swap is clean.
        ELIM: begin
          if (pivot_found) begin

            // ── Step 2: bring pivot row up to position [rank] ─────────────
            M[rank[5:0]] <= M[pivot_row];          // new M[rank]     = pivot

            // ── Step 2b: vacated slot gets old M[rank], then eliminate ────
            // If old M[rank][col] is already 1, XOR pivot in to clear it.
            if (pivot_row != rank[5:0])
              M[pivot_row] <= M[rank[5:0]][col]
                              ? M[rank[5:0]] ^ M[pivot_row]  // XOR uses OLD M[pivot_row]
                              : M[rank[5:0]];

            // ── Step 3: eliminate col from every remaining row ────────────
            // Skips the two slots handled above (rank and pivot_row).
            // All reads of M[pivot_row] here return the OLD (pre-edge) value,
            // which is the actual pivot vector — correct behaviour.
            for (int r = 0; r < 64; r++) begin
              if (6'(unsigned'(r)) != rank[5:0] &&
                  6'(unsigned'(r)) != pivot_row  &&
                  M[r][col])
                M[r] <= M[r] ^ M[pivot_row];
            end

            rank <= rank + 1'b1;
          end

          // ── Termination ───────────────────────────────────────────────────
          // rank here is OLD rank; +1 happens simultaneously via NBA above.
          if (pivot_found && rank == 7'd63) begin
            // 64th pivot just placed → matrix is full rank
            full_rank <= 1'b1;
            state     <= DONE;
          end else if (col == 8'd255) begin
            // All 256 bit-columns exhausted without reaching rank 64
            full_rank <= 1'b0;
            state     <= DONE;
          end else begin
            col <= col + 1'b1;
          end
        end

        // ────────────────────────────────────────────────────────────────────
        DONE: begin
          done  <= 1'b1;
          state <= IDLE;
        end

        default: state <= IDLE;

      endcase
    end
  end

  // ── Cache read control ────────────────────────────────────────────────────
  assign rd_row = load_idx;
  assign rd_en  = (state == LOAD);

endmodule
