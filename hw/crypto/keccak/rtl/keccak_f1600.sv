module keccak_f1600(
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [63:0] state_in [0:4][0:4],
    output logic [63:0] state_out [0:4][0:4],
    output logic        done
);

// Round constants
localparam logic [63:0] RC [0:23] = '{
    64'h0000000000000001, 64'h0000000000008082,
    64'h800000000000808A, 64'h8000000080008000,
    64'h000000000000808B, 64'h0000000080000001,
    64'h8000000080008081, 64'h8000000000008009,
    64'h000000000000008A, 64'h0000000000000088,
    64'h0000000080008009, 64'h000000008000000A,
    64'h000000008000808B, 64'h800000000000008B,
    64'h8000000000008089, 64'h8000000000008003,
    64'h8000000000008002, 64'h8000000000000080,
    64'h000000000000800A, 64'h800000008000000A,
    64'h8000000080008081, 64'h8000000000008080,
    64'h0000000080000001, 64'h8000000080008008
};

// Round counter
logic [4:0] round_cnt;

// State register
logic [63:0] state_reg [0:4][0:4];
logic [63:0] round_out [0:4][0:4];

// Instantiate one round of keccak
keccak_round u_round (
    .state          (state_reg),
    .round_constant (RC[round_cnt]),
    .out            (round_out)
);

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        round_cnt <= '0;
        done      <= 1'b0;
        state_reg <= '{default: '{default: 64'h0}};
    end else if (start) begin
        // Load new input state, begin at round 0
        state_reg <= state_in;
        round_cnt <= '0;
        done      <= 1'b0;
    end else if (!done) begin
        // Loop round output back into state register for next round
        state_reg <= round_out;
        if (round_cnt == 5'd23) begin
            done <= 1'b1;
        end else begin
            round_cnt <= round_cnt + 1;
        end
    end
end

assign state_out = state_reg;

endmodule
