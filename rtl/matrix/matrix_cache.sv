module matrix_cache (
    input  logic          clk,
    input  logic          rst,

    // Write interface
    input  logic          wr_matrix_en,
    input  logic          wr_PrePowHash_en,
    input  logic [5:0]    wr_row,
    input  logic [5:0]    wr_col,
    input  logic [3:0]    wr_matrix_data,
    input  logic [255:0]  wr_PrePowHash,

    // Read interface
    input logic           rd_en,
    input  logic [5:0]    rd_row,
    input  logic [5:0]    rd_col,
    output logic [3:0]   rd_data,
    output logic [255:0]  rd_PrePowHash
);

  logic [3:0] matrix [64][64];
  logic [255:0] PrePowHash;

  // Write
  always_ff @(posedge clk or posedge rst) begin
      if (rst) begin
          PrePowHash <= '0;
          for (int i = 0; i < 64; i++) begin
              for (int j = 0; j < 64; j++) begin
                  matrix[i][j] <= '0;
              end
          end
      end else begin
          if (wr_matrix_en)
              matrix[wr_row][wr_col] <= wr_matrix_data;
          if (wr_PrePowHash_en)
              PrePowHash <= wr_PrePowHash;
      end
  end

  // Read (registered, 1-cycle latency)
  always_ff @(posedge clk) begin
    if (rd_en)
        rd_data <= matrix[rd_row][rd_col];
        rd_PrePowHash <= PrePowHash;
  end

endmodule
