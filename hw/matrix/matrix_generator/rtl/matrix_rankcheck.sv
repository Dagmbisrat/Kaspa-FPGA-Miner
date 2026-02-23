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

  // FSM
  typedef enum logic [2:0] {
    IDLE  = 3'd0,
    LOAD  = 3'd1,   // issue reads for rows 0..63
    FLUSH = 3'd2,   // drain last row from cache pipeline
    ELIM  = 3'd3,   // GF(2) Gaussian elimination
    DONE  = 3'd4
  } state_t;
  state_t state;

  // Working matrix: 64 rows of 256 bits for GF(2) elimination
  logic [255:0] M [64];

  logic [5:0] load_idx;   // row being requested from cache
  logic [7:0] col;        // column being eliminated (0..255)
  logic [6:0] rank;       // pivot rows found so far (0..64)

  // Combinational pivot search: lowest-index row r >= rank with M[r][col]=1
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

        LOAD: begin
          if (load_idx < 6'd63)
            load_idx <= load_idx + 1'b1;
          else
            state <= FLUSH;

          // capture row requested on previous cycle (skip first cycle)
          if (load_idx != 6'h0)
            M[load_idx - 1'b1] <= rd_row_data;
        end

        // drain last row from cache pipeline
        FLUSH: begin
          M[63] <= rd_row_data;
          state <= ELIM;
        end

        // GF(2) Gaussian elimination, one column per cycle
        ELIM: begin
          if (pivot_found) begin
            // bring pivot row up to M[rank]
            M[rank[5:0]] <= M[pivot_row];

            // vacated slot gets old M[rank]; XOR out col bit if set
            if (pivot_row != rank[5:0])
              M[pivot_row] <= M[rank[5:0]][col]
                              ? M[rank[5:0]] ^ M[pivot_row]
                              : M[rank[5:0]];

            // eliminate col from all other rows
            for (int r = 0; r < 64; r++) begin
              if (6'(unsigned'(r)) != rank[5:0] &&
                  6'(unsigned'(r)) != pivot_row  &&
                  M[r][col])
                M[r] <= M[r] ^ M[pivot_row];
            end

            rank <= rank + 1'b1;
          end

          if (pivot_found && rank == 7'd63) begin
            full_rank <= 1'b1;
            state     <= DONE;
          end else if (col == 8'd255) begin
            full_rank <= 1'b0;
            state     <= DONE;
          end else begin
            col <= col + 1'b1;
          end
        end

        DONE: begin
          done  <= 1'b1;
          state <= IDLE;
        end

        default: state <= IDLE;

      endcase
    end
  end

  assign rd_row = load_idx;
  assign rd_en  = (state == LOAD);

endmodule
