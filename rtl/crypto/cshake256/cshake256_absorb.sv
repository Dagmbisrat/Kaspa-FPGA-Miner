module cshake256_absorb (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [1087:0] input_block,
    input  logic        input_valid,
    output logic        done,
    output logic [1599:0] state_out
);

// FSM states
typedef enum logic [1:0] {
    IDLE        = 2'b00,
    ABSORB_XOR  = 2'b01,
    PERMUTE     = 2'b10,
    DONE        = 2'b11
} state_t;

state_t current_state, next_state;

// State register (1600 bits = 25 lanes of 64 bits in a 5x5 array)
logic [63:0] state [0:4][0:4];
logic [63:0] state_next [0:4][0:4];

// Keccak permutation signals
logic        perm_start;
logic [63:0] perm_state_in [0:4][0:4];
logic [63:0] perm_state_out [0:4][0:4];
logic        perm_done;

// Keccak-f[1600] instance
keccak_f1600 keccak_perm (
    .clk(clk),
    .rst(rst),
    .start(perm_start),
    .state_in(perm_state_in),
    .state_out(perm_state_out),
    .done(perm_done)
);

  // FSM sequential logic
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        current_state <= IDLE;
    end else begin
        current_state <= next_state;
    end
end

// FSM combinational logic
always_comb begin
    next_state = current_state;

    case (current_state)
        IDLE: begin
            if (start && input_valid)
                next_state = ABSORB_XOR;
        end

        ABSORB_XOR: begin
            next_state = PERMUTE;
        end

        PERMUTE: begin
            if (perm_done)
                next_state = DONE;
        end

        DONE: begin
            next_state = IDLE;
        end
    endcase
end

// State update on clk
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        for (int y = 0; y < 5; y++) begin
            for (int x = 0; x < 5; x++) begin
                state[y][x] <= 64'h0;
            end
        end
    end else begin
        state <= state_next;
    end
end

// State update logic
always_comb begin
    state_next = state;

    case (current_state)
        ABSORB_XOR: begin
            // XOR input block into rate portion (first 1088 bits = 17 lanes)
            // Lane mapping: state[y][x] where index = x + 5*y
            // Rate: lanes 0-16 (1088 bits)
            // Capacity: lanes 17-24 (512 bits)

            for (int lane = 0; lane < 17; lane++) begin
                int x = lane % 5;
                int y = lane / 5;
                state_next[y][x] = state[y][x] ^ input_block[lane*64 +: 64];
            end

            // Capacity lanes (17-24) unchanged
        end

        PERMUTE: begin
            if (perm_done) begin
                state_next = perm_state_out;
            end
        end
    endcase
end

    // Keccak permutation control
    assign perm_start = (current_state == PERMUTE) && !perm_done;
    assign perm_state_in = state;

    // Output assignments
    assign done = (current_state == DONE);

    // Flatten state to 1600-bit output
    always_comb begin
        for (int y = 0; y < 5; y++) begin
            for (int x = 0; x < 5; x++) begin
                int lane_idx = x + 5*y;
                state_out[lane_idx*64 +: 64] = state[y][x];
            end
        end
    end

endmodule
