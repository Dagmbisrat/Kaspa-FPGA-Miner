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
            if (perm_done && perm_started)
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
            // Lane mapping: state[x][y] where lane index = x + 5*y
            // (matches keccak_round convention: first dim = x, second = y)
            // y=0: lanes 0-4
            state_next[0][0] = state[0][0] ^ input_block[  0*64 +: 64];
            state_next[1][0] = state[1][0] ^ input_block[  1*64 +: 64];
            state_next[2][0] = state[2][0] ^ input_block[  2*64 +: 64];
            state_next[3][0] = state[3][0] ^ input_block[  3*64 +: 64];
            state_next[4][0] = state[4][0] ^ input_block[  4*64 +: 64];
            // y=1: lanes 5-9
            state_next[0][1] = state[0][1] ^ input_block[  5*64 +: 64];
            state_next[1][1] = state[1][1] ^ input_block[  6*64 +: 64];
            state_next[2][1] = state[2][1] ^ input_block[  7*64 +: 64];
            state_next[3][1] = state[3][1] ^ input_block[  8*64 +: 64];
            state_next[4][1] = state[4][1] ^ input_block[  9*64 +: 64];
            // y=2: lanes 10-14
            state_next[0][2] = state[0][2] ^ input_block[ 10*64 +: 64];
            state_next[1][2] = state[1][2] ^ input_block[ 11*64 +: 64];
            state_next[2][2] = state[2][2] ^ input_block[ 12*64 +: 64];
            state_next[3][2] = state[3][2] ^ input_block[ 13*64 +: 64];
            state_next[4][2] = state[4][2] ^ input_block[ 14*64 +: 64];
            // y=3: lanes 15-16 (partial row, rate ends at lane 16)
            state_next[0][3] = state[0][3] ^ input_block[ 15*64 +: 64];
            state_next[1][3] = state[1][3] ^ input_block[ 16*64 +: 64];
        end

        PERMUTE: begin
            if (perm_done && perm_started) begin
                state_next = perm_state_out;
            end
        end
    endcase
end

    // Keccak permutation control — one-cycle pulse to avoid
    // re-loading state_in every cycle (keccak's start branch
    // has priority over its round-advance branch).
    logic perm_started;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            perm_started <= 1'b0;
        else if (current_state != PERMUTE)
            perm_started <= 1'b0;
        else
            perm_started <= 1'b1;
    end
    assign perm_start = (current_state == PERMUTE) && !perm_started;
    assign perm_state_in = state;

    // Output assignments
    assign done = (current_state == DONE);

    // Flatten state to 1600-bit output (state[x][y], lane = x + 5*y)
    always_comb begin
        for (int x = 0; x < 5; x++) begin
            for (int y = 0; y < 5; y++) begin
                int lane_idx = x + 5*y;
                state_out[lane_idx*64 +: 64] = state[x][y];
            end
        end
    end

endmodule
