module cshake256_core (
  // Control
    input  logic  clk, rst, start,

    // Input
    input logic  [639:0] data_in,
    input logic          data_80byte, // 0: 32-byte input, 1: 80-byte input

    // S vlaue
    input  logic s_value, // 0: S = "ProofOfWorkHash", 1: S = "HeavyHash"

    // Output
    output logic [255:0]  hash_out,
    output logic          done
);

// S customization strings (ASCII, N is always empty)
localparam int RATE_BYTES = 136;
localparam int RATE_LANES = 17;   // 136 / 8
localparam logic [119:0] S_PROOF_OF_WORK = 120'h687361486B726F57664F666F6F7250; // "ProofOfWorkHash" (15 bytes, LE)
localparam logic [71:0]  S_HEAVY_HASH    = 72'h687361487976616548; // "HeavyHash" (9 bytes, LE)

// Signals used Absorb
logic [1087:0] absorb_buffer;
logic absorb_start;
logic absorb_done;
logic [1599:0] absorb_state_out;

// FSM states
typedef enum logic [2:0] {
    IDLE          = 3'b000,
    INIT          = 3'b001,
    ENCODE_PREFIX = 3'b010,
    ABSORB_INPUT  = 3'b011,
    DONE          = 3'b100

} state_t;

state_t fsm_current_state, fsm_next_state;

// State register (1600 bits = 25 lanes of 64 bits in a 5x5 array)
logic [1599:0] data_state;
logic [1599:0] data_next_state;

// FSM combinatorial logic for state transition
always_comb begin
    fsm_next_state = fsm_current_state;
    case (fsm_current_state)
        IDLE: begin
            if (start) begin
                fsm_next_state = INIT;
            end
        end
        INIT: begin
              fsm_next_state = ENCODE_PREFIX;
        end
        ENCODE_PREFIX: begin
            if (absorb_done) begin
                fsm_next_state = ABSORB_INPUT;
            end
        end
        ABSORB_INPUT: begin
            if (absorb_done) begin
                fsm_next_state = DONE;
            end
        end
        DONE: begin
            fsm_next_state = IDLE;
        end
    endcase
end

// FSM sequential logic for setting the next state on clk
always_ff @(posedge clk or posedge rst) begin
  if (rst) begin
      fsm_current_state <= IDLE;
  end else begin
      fsm_current_state <= fsm_next_state;
  end
end

cshake256_absorb absorber (
    .clk(clk),
    .rst(rst || fsm_current_state == INIT),
    .start(absorb_start),
    .input_block(absorb_buffer),
    .input_valid(1'b1),
    .done(absorb_done),
    .state_out(absorb_state_out)
);

// State update combinatorial logic
always_comb begin
  data_next_state = data_state;
  absorb_buffer = 1088'b0;
  absorb_start = 1'b0;

    case (fsm_current_state)
        INIT: begin
            // Initialize state with zeros
            data_next_state = 1600'b0;
            //set conters if nedded:
        end
        ENCODE_PREFIX: begin
          // bytepad(encode_string("") || encode_string(S), 136)

          // 1. left_encode(136)
          absorb_buffer[7:0]   = 8'd1;
          absorb_buffer[15:8]  = 8'd136;

          // 2. encode_string(N) - N empty
          absorb_buffer[23:16] = 8'd1;
          absorb_buffer[31:24] = 8'd0;

          // 3. encode_string(S)
          if (s_value == 0) begin
              // ProofOfWorkHash - 15 bytes (120 bits)
              absorb_buffer[39:32] = 8'd1;
              absorb_buffer[47:40] = 8'd120;
              absorb_buffer[167:48] = S_PROOF_OF_WORK;
          end else begin
              // HeavyHash - 9 bytes (72 bits)
              absorb_buffer[39:32] = 8'd1;
              absorb_buffer[47:40] = 8'd72;
              absorb_buffer[119:48] = S_HEAVY_HASH;
          end
          absorb_start = 1'b1;
          if (absorb_done)
              data_next_state = absorb_state_out;
        end
        ABSORB_INPUT: begin
          absorb_buffer[639:0] = data_in;
          if (data_80byte) begin
              // 80-byte input: pad at byte 80
              absorb_buffer[647:640]  = 8'h04;
          end else begin
              // 32-byte input: pad at byte 32 (upper bits are zero)
              absorb_buffer[263:256]  = 8'h04;
          end
          absorb_buffer[1087:1080] = 8'h80;
          absorb_start = 1'b1;
          if (absorb_done)
              data_next_state = absorb_state_out;
        end
    endcase
end
assign done = (fsm_current_state == DONE);

// State sequential logic for setting the next on clk
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      data_state <= 1600'b0;
    end else begin
        data_state <= data_next_state;
    end
end

// Capture hash from registered data_state during DONE
// (avoids combinational timing issues with data_next_state)
always_ff @(posedge clk or posedge rst) begin
    if (rst)
        hash_out <= 256'b0;
    else if (fsm_current_state == DONE)
        hash_out <= data_state[255:0];
end
endmodule
