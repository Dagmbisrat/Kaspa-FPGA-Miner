// keccak_round — one round of Keccak-f[1600]: theta, rho, pi, chi, iota.
//
// Functionally identical to the classic five-block form, but restructured so
// that theta's per-lane XOR, rho, pi, chi and iota collapse into a SINGLE
// LUT layer:
//
//   * Front layer  : column parity C[x] (5-input XOR) and the theta offset
//                    D[x] = C[x-1] ^ rotl(C[x+1], 1).
//   * Fused layer  : every output bit is
//                        out[x][y][i] = P0 ^ (~P1 & P2)
//                    with  Pk = state[.][.][.] ^ D[.][.]  (one state bit XOR
//                    one offset bit, after the rho rotation / pi permute).
//                    That is a function of 3 state bits + 3 offset bits = 6
//                    inputs -> one LUT6 per output bit.  iota is chi[0][0]
//                    XOR a per-instance constant, i.e. an output-polarity
//                    flip that folds into the same LUT6 (zero extra logic).
//
// rho and pi are pure wire re-indexing (no logic).  Keeping theta[x][y] /
// rho[x][y] / pi[x][y] as named nets is what made a tool emit theta's
// 1600 XOR2 as its own logic level; not naming them lets that XOR merge into
// the chi cone.  Latency / throughput / bit-level result are unchanged.
module keccak_round(
    input  logic [63:0] state          [0:4][0:4],
    input  logic [63:0] round_constant,
    output logic [63:0] out            [0:4][0:4]
);

// ---- Theta front layer: column parity C and offset D -----------------------
logic [63:0] cpar [0:4];   // C[x] = XOR of column x
logic [63:0] doff [0:4];   // D[x] = C[x-1] ^ rotl(C[x+1], 1)
always_comb begin : theta_front
    for (int x = 0; x < 5; x++)
        cpar[x] = state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4];
    for (int x = 0; x < 5; x++)
        doff[x] = cpar[(x+4)%5] ^ {cpar[(x+1)%5][62:0], cpar[(x+1)%5][63]};
end

// ---- Rho rotation amounts (constant) --------------------------------------
localparam logic [5:0] RHO_OFFSETS [0:4][0:4] = '{
    '{6'd0,  6'd36, 6'd3,  6'd41, 6'd18},  // x=0
    '{6'd1,  6'd44, 6'd10, 6'd45, 6'd2},   // x=1
    '{6'd62, 6'd6,  6'd43, 6'd15, 6'd61},  // x=2
    '{6'd28, 6'd55, 6'd25, 6'd21, 6'd56},  // x=3
    '{6'd27, 6'd20, 6'd39, 6'd8,  6'd14}   // x=4
};

// ---- Fused theta-apply + rho + pi ----------------------------------------
// b holds (theta-applied, rho-rotated) lanes already moved to their pi
// positions:  b[y%5][(2x+3y)%5] = rotl(state[x][y] ^ D[x], RHO_OFFSETS[x][y]).
// The "^ D[x]" stays inside this expression so it fuses into chi below.
logic [63:0] b [0:4][0:4];
always_comb begin : theta_apply_rho_pi
    for (int x = 0; x < 5; x++) begin
        for (int y = 0; y < 5; y++) begin
            logic [63:0] t;
            t = state[x][y] ^ doff[x];
            b[y % 5][((2*x) + (3*y)) % 5] =
                t << RHO_OFFSETS[x][y] | t >> (64 - RHO_OFFSETS[x][y]);
        end
    end
end

// ---- Fused chi + iota ---------------------------------------------------
// chi[x][y] = b[x][y] ^ (~b[x+1][y] & b[x+2][y]);  iota flips lane[0][0].
// chi is the nonlinear result itself (not a theta/rho/pi net), so the
// b -> chi cone still maps one LUT per output bit.
logic [63:0] chi [0:4][0:4];
always_comb begin : chi_iota
    for (int x = 0; x < 5; x++)
        for (int y = 0; y < 5; y++)
            chi[x][y] = b[x][y] ^ ((~b[(x+1)%5][y]) & b[(x+2)%5][y]);
    out = chi;
    out[0][0] = chi[0][0] ^ round_constant;
end

endmodule
