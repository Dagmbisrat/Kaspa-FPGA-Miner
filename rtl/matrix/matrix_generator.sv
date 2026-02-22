module matrix_generator (
    input  logic          clk,
    input  logic          rst,
    input  logic          start,
    input  logic [255:0]  PrePowHash,
    output logic          done,

    // Cache write interface
    output logic          wr_matrix_en,
    output logic          wr_PrePowHash_en,
    output logic [7:0]    n16th_value,
    output logic [63:0]   wr_matrix_data,

    // Cache read interface (hit/miss check only)
    output logic          rd_en,
    input  logic [255:0]  rd_PrePowHash
);

  // PRNG state
  logic [63:0] s0_reg, s1_reg, s2_reg, s3_reg;
  logic [63:0] s0_next, s1_next, s2_next, s3_next;
  logic [63:0] prng_out;
  logic [7:0]  next_n16th_value;
  logic        full_rank;

  // Cache write data is the PRNG output
  assign wr_matrix_data = prng_out;

  // FSM states
  typedef enum logic [1:0] {
      IDLE            = 2'b00,
      IDLE_CHECK      = 2'b01,
      GENERATE_MATRIX = 2'b10,
      DONE            = 2'b11
  } state_t;
  state_t fsm_current_state, fsm_next_state;

  xoshiro256pp prng(
    .s0(s0_reg),
    .s1(s1_reg),
    .s2(s2_reg),
    .s3(s3_reg),
    .out(prng_out),
    .new_s0(s0_next),
    .new_s1(s1_next),
    .new_s2(s2_next),
    .new_s3(s3_next)
  );

  // FSM combinatorial logic for state transition
  always_comb begin
      fsm_next_state = fsm_current_state;
      case (fsm_current_state)
          IDLE: begin
              if (start)
                fsm_next_state = IDLE_CHECK;
          end
          IDLE_CHECK: begin
              if (rd_PrePowHash == PrePowHash) // Cache hit
                fsm_next_state = DONE;
              else                             // Cache miss
                fsm_next_state = GENERATE_MATRIX;
          end
          GENERATE_MATRIX: begin
            if (full_rank)
              fsm_next_state = DONE;
          end
          DONE: begin
            fsm_next_state = IDLE;
          end
      endcase
  end

  // FSM sequential logic
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        fsm_current_state <= IDLE;
        n16th_value <= 8'h0;
        s0_reg <= 64'h0;
        s1_reg <= 64'h0;
        s2_reg <= 64'h0;
        s3_reg <= 64'h0;
    end else begin
        fsm_current_state <= fsm_next_state;
        case (fsm_current_state)
          IDLE_CHECK: begin
            s0_reg <= PrePowHash[63:0];
            s1_reg <= PrePowHash[127:64];
            s2_reg <= PrePowHash[191:128];
            s3_reg <= PrePowHash[255:192];
            n16th_value <= 8'h0;
          end
          GENERATE_MATRIX: begin
            s0_reg <= s0_next;
            s1_reg <= s1_next;
            s2_reg <= s2_next;
            s3_reg <= s3_next;
            n16th_value <= next_n16th_value;
          end
          default: ; // hold values
        endcase
    end
  end

  // Combinatorial output logic
  always_comb begin
    wr_matrix_en     = 1'b0;
    wr_PrePowHash_en = 1'b0;
    rd_en            = 1'b0;
    full_rank        = 1'b0;
    next_n16th_value = 8'h0;

    case (fsm_current_state)
        IDLE: begin
          rd_en = 1'b1;
        end
        GENERATE_MATRIX: begin
          wr_matrix_en = 1'b1;
          if (n16th_value == 8'h0)
            wr_PrePowHash_en = 1'b1; // Set the PrePowHash register
          if (n16th_value == 8'hFF)
            full_rank = 1'b1;
          else
            next_n16th_value = n16th_value + 8'h1;
        end
        default: ;
    endcase
  end

  always_ff @(posedge clk or posedge rst) begin
    if (rst)
      done <= 1'b0;
    else if (start)
      done <= 1'b0;
    else if (fsm_current_state == DONE)
      done <= 1'b1;
  end

endmodule
