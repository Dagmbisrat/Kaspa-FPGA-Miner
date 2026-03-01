// kHeavyHash Mining Core
module core (
    input  logic         clk,
    input  logic         rst,

    input  logic         start,

    // ---- Inputs (kHeavyHash.md §Algorithm Inputs) ----
    input  logic [255:0] pre_pow_hash,  // 32 bytes - seeds matrix, stable per block
    input  logic [63:0]  timestamp,     // 8 bytes  - little-endian uint64
    input  logic [63:0]  nonce,         // 8 bytes  - mining nonce

    // ---- Outputs ----
    output logic [255:0] hash_out,      // 32-byte final hash
    output logic         done           // pulses high for one cycle when hash_out is valid
);

// 80-byte header: pre_pow_hash | timestamp | 32x0 | nonce
logic [639:0] header_reg;

// ---------------------------------------------------------------------------
//                      Fsm signals and definitions
// States
typedef enum logic [2:0] {
    IDLE    = 3'b000,
    STAGE1  = 3'b001, // Matirx Gen & Cshake 1 Gen
    STAGE2  = 3'b010, // Matmul
    STAGE3  = 3'b011, // Final cSHAKE256 2 Gen (XOR built in)
    DONE    = 3'b100
} state_t;
state_t state, next_state;
// ---------------------------------------------------------------------------



// ---------------------------------------------------------------------------
//                      Cache IP signals and definitions
// Write interface (Drivin only by Matrix Gen IP)
logic          wr_matrix_en;
logic          wr_PrePowHash_en;
logic [7:0]    n16th_value;
logic [63:0]   wr_matrix_data;
logic [255:0]  wr_PrePowHash;

// Read interface
logic          rd_en;
logic [5:0]    rd_row;
logic [255:0]  rd_row_data;   // Output only driven by the cache
logic [255:0]  rd_PrePowHash; // Output only driven by the cache

// Cache instance
matrix_cache Cache (
    .clk(clk),
    .rst(rst),

    // Write
    .wr_matrix_en(wr_matrix_en),
    .wr_PrePowHash_en(wr_PrePowHash_en),
    .n16th_value(n16th_value),
    .wr_matrix_data(wr_matrix_data),
    .wr_PrePowHash(wr_PrePowHash),

    // Read
    .rd_en(rd_en),
    .rd_row(rd_row),                                                       //|
    .rd_row_data(rd_row_data),                                             //|
    .rd_PrePowHash(rd_PrePowHash)                                          //|
);                                                                         //|
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
//                     Matrix Gen IP signals and definitions
logic         matrix_gen_start;
logic         matrix_gen_done; // Droven by matrix_gen IP
logic         matrix_gen_complete_reg;

// Cache write interface for Matrix Gen IP
logic          matrix_gen_wr_matrix_en;
logic          matrix_gen_wr_PrePowHash_en;
logic [7:0]    matrix_gen_n16th_value;
logic [63:0]   matrix_gen_wr_matrix_data;

// Cache read interface for Matrix Gen IP
logic           matrix_gen_rd_en;
logic [5:0]     matrix_gen_rd_row;

// Matrix Gen IP instance
matrix_generator MatrixGen (
    .clk(clk),
    .rst(rst),
    .start(matrix_gen_start),
    .PrePowHash(header_reg[255:0]),
    .done(matrix_gen_done), // Output

    // Cache write
    .wr_matrix_en(matrix_gen_wr_matrix_en),
    .wr_PrePowHash_en(matrix_gen_wr_PrePowHash_en),
    .n16th_value(matrix_gen_n16th_value),
    .wr_matrix_data(matrix_gen_wr_matrix_data),

    // Cache read
    .rd_en(matrix_gen_rd_en),
    .rd_row(matrix_gen_rd_row),
    .rd_row_data(rd_row_data),
    .rd_PrePowHash(rd_PrePowHash)
);
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
//                    Cshake IP signals and definitions
logic         cshake_start;
logic         cshake_done;
logic         cshake_complete_reg;

// Inputs to IP
logic [639:0] cshake_data_in;      // Driven by diffrent stages
logic         cshake_data_80byte;  // Driven by diffrent stages
logic         cshake_s_value;      // Driven by diffrent stages

// Outputs from IP
logic [255:0] cshake_hash_out;
logic [255:0] pow_hash_reg;


// Cshake IP instance
cshake256_core Cshake256 (
    .clk(clk),
    .rst(rst),
    .start(cshake_start),
    .data_in(cshake_data_in),
    .data_80byte(cshake_data_80byte),
    .s_value(cshake_s_value),
    .hash_out(cshake_hash_out),
    .done(cshake_done)
);
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
//                    Matrix Mul IP signals and definitions
logic         matrix_mul_start;
logic         matrix_mul_done;

// Cache read
logic           matrix_mul_rd_en;
logic [5:0]     matrix_mul_rd_row;


// Output from IP
logic [255:0] matrix_mul_product_out;
logic [255:0] matrix_mul_product_out_reg; // Reg should only hold the finished product

matmul_unit Matrix_Mul (
    .clk(clk),
    .rst(rst),

    .start(matrix_mul_start),
    .vector_in(pow_hash_reg),
    .done(matrix_mul_done),

    // Cache read
    .rd_en(matrix_mul_rd_en),
    .rd_row(matrix_mul_rd_row),
    .rd_row_data(rd_row_data), // Taken directly from Cache

    .product_out(matrix_mul_product_out)
);
// ---------------------------------------------------------------------------

// Combinational logic for state transitions
always_comb begin
    next_state = state;
    case (state)
        IDLE:    begin
          if (start) begin
            next_state = STAGE1;
          end
        end
        STAGE1:  begin
          if (matrix_gen_complete_reg && cshake_complete_reg) begin
            next_state = STAGE2;
          end
        end
        STAGE2:  begin
          if (matrix_mul_done) begin
            next_state = STAGE3;
          end
        end
        STAGE3:  begin
          if (cshake_done) begin
            next_state = DONE;
          end
        end
        DONE:    begin
          if (done) begin
            next_state = IDLE;
          end
        end
    endcase
end

// Sequential logic for setting the next state on clk
always_ff @(posedge clk or posedge rst) begin
  if (rst) begin
      state <= IDLE;
  end else begin
      state <= next_state;
  end
end


// Combinational logic for Core
always_comb begin
  // Default Matrix Gen signals

  // Default Cshake signals
  cshake_data_80byte = 1'b0;
  cshake_s_value = 1'b0;
  cshake_data_in = 640'b0;

  // Default Matrix Mul signals


  // Default Hash signals


  // Defult
  done = 1'b0;
  case (state)
    IDLE:    begin
      // No need
    end
    STAGE1:  begin
      // Matrix Gen set at sequential logic

      // Cshake
      cshake_data_80byte = 1'b1;
      cshake_s_value = 1'b0;
      cshake_data_in = header_reg;
    end
    STAGE2:  begin
      // Matrix Mul set at sequential logic
    end
    STAGE3:  begin
      // Cshake
      cshake_data_80byte = 1'b0;
      cshake_s_value = 1'b1;
      cshake_data_in = {384'b0, (matrix_mul_product_out_reg ^ pow_hash_reg)}; // Xor with pow_hash
    end
    DONE:  begin
      done = 1'b1;
    end
  endcase
end

// Cache Write assigns
assign wr_matrix_en = matrix_gen_wr_matrix_en;
assign wr_PrePowHash_en = matrix_gen_wr_PrePowHash_en;
assign n16th_value = matrix_gen_n16th_value;
assign wr_matrix_data = matrix_gen_wr_matrix_data;
assign wr_PrePowHash = header_reg[255:0];

// Cache Read assigns
assign rd_en  = (state == STAGE2) ? matrix_mul_rd_en  :
                (state == STAGE1) ? matrix_gen_rd_en  : 1'b0;
assign rd_row = (state == STAGE2) ? matrix_mul_rd_row : matrix_gen_rd_row;


// Sequential logic for Core spesifc register's
always_ff @(posedge clk or posedge rst) begin
  if (rst) begin
    // Core Reset values
    header_reg <= 640'b0;

    // Stage 1: Reset values
    matrix_gen_start <= 1'b0;
    cshake_start     <= 1'b0;

    matrix_gen_complete_reg <= 1'b0;
    cshake_complete_reg <= 1'b0;
    pow_hash_reg <= 256'b0;

    // Stage 2: Reset values
    matrix_mul_start <= 1'b0;
    matrix_mul_product_out_reg <= 256'b0;

    // Stage 3: Reset values
    hash_out <= 256'b0;
  end else begin

    case (state)
      IDLE: begin
        matrix_gen_complete_reg <= 1'b0;
        cshake_complete_reg <= 1'b0;
        pow_hash_reg <= 256'b0;
        matrix_mul_product_out_reg <= 256'b0;

        // Set for next stage (STAGE1)
        if (next_state == STAGE1) begin
          matrix_gen_start <= 1'b1;
          cshake_start <= 1'b1;
        end

        if (start) begin
          header_reg <= {nonce, 256'b0, timestamp, pre_pow_hash};
        end
      end
      STAGE1: begin

        // Clear start
        if (matrix_gen_start == 1'b1) begin
          matrix_gen_start <= 1'b0;
        end
        if (cshake_start == 1'b1) begin
          cshake_start <= 1'b0;
        end

        // Matrix Gen IP
        if (matrix_gen_done) begin
          matrix_gen_complete_reg <= 1'b1;
        end
        // Cshake IP
        if (cshake_done) begin
          cshake_complete_reg <= 1'b1;
          pow_hash_reg <= cshake_hash_out;
        end

        // Set for next stage (STAGE2)
        if (next_state == STAGE2) begin
          matrix_mul_start <= 1'b1;
        end
      end

      STAGE2: begin

        // Clear start
        if (matrix_mul_start == 1'b1) begin
          matrix_mul_start <= 1'b0;
        end

        // Matrix Mul
        if (matrix_mul_done) begin
          matrix_mul_product_out_reg <= matrix_mul_product_out;
        end

        // Set for next stage (STAGE3)
        if (next_state == STAGE3) begin
          cshake_start <= 1'b1;
        end
      end
      STAGE3: begin

        // Clear start
        if (cshake_start == 1'b1) begin
          cshake_start <= 1'b0;
        end

        // Cshake IP
        if (cshake_done) begin
          // cshake_complete_reg <= 1'b1;
          hash_out <= cshake_hash_out;
        end
      end
      default: begin

        // Stage 1:
        matrix_gen_start <= 1'b0;
        cshake_start     <= 1'b0;

        // Stage 2:
        matrix_mul_start <= 1'b0;

      end
    endcase
  end
end

endmodule
