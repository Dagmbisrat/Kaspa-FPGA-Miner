module matrix_cache (
    input  logic          clk,
    input  logic          rst,

    // Write interface
    input  logic          wr_matrix_en,
    input  logic          wr_PrePowHash_en,
    input  logic [7:0]    n16th_value,
    input  logic [63:0]   wr_matrix_data,
    input  logic [255:0]  wr_PrePowHash,

    // Read interface
    input  logic          rd_en,
    input  logic [5:0]    rd_row,
    output logic [255:0]  rd_row_data,
    output logic [255:0]  rd_PrePowHash
);

  logic [3:0] matrix [64][64];
  logic [255:0] PrePowHash;

  // Write
  always_ff @(posedge clk or posedge rst) begin
      if (rst) begin
          PrePowHash <= '0;
          for (int i = 0; i < 64; i++)
              for (int j = 0; j < 64; j++)
                  matrix[i][j] = '0;  // - blocking ok under reset (Verilator requirement)
      end else begin
          if (wr_matrix_en)
              for (int i = 0; i < 16; i++) begin
                matrix[n16th_value >> 2][(n16th_value % 4) * 16 + i] <= wr_matrix_data[i*4 +: 4]; // Make sure to assign the correct bits to the matrix
              end
          if (wr_PrePowHash_en)
              PrePowHash <= wr_PrePowHash;
      end
  end

  // Read (registered, 1-cycle latency)
  always_ff @(posedge clk) begin
    if (rd_en) begin
        for (int i = 0; i < 64; i++)
            rd_row_data[i*4 +: 4] <= matrix[rd_row][i];
        rd_PrePowHash <= PrePowHash;
    end
  end

endmodule
