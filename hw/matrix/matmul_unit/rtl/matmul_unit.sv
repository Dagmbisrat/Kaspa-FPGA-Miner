module matmul_unit (
    input  logic         clk,
    input  logic         rst,
    input  logic         start,
    input  logic [255:0] vector_in,   // 64 x 4-bit nibbles
    output logic         done,

    // Cache read interface
    output logic         rd_en,
    output logic [5:0]   rd_row,
    input  logic [255:0] rd_row_data,

    output logic [255:0] product_out  // 64 x 4-bit nibbles
);

    typedef enum logic [1:0] {
        IDLE = 2'b00,
        RUN  = 2'b01,
        DONE = 2'b10
    } state_t;
    state_t state;

    logic [6:0] row_ptr;  // 0..64

    // rd_en/rd_row are combinational so the cache sees the request in the same
    // cycle the FSM advances row_ptr, giving exactly 1-cycle read latency.
    // Registering them would add a second pipeline stage and shift every product
    // by one element.
    assign rd_en = (state == RUN) && (row_ptr < 7'd64);
    assign rd_row = row_ptr[5:0];

    // Dot product of cached row with vector; max 64*(15*15)=14400 fits in 14 bits
    logic [13:0] dot;
    always_comb begin
        dot = 14'd0;
        for (int j = 0; j < 64; j++)
            dot = dot + 14'(rd_row_data[j*4 +: 4] * vector_in[j*4 +: 4]);
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= IDLE;
            row_ptr     <= 7'd0;
            done        <= 1'b0;
            product_out <= '0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        row_ptr <= 7'd0;
                        state   <= RUN;
                    end
                end

                RUN: begin
                    // rd_row_data holds row (row_ptr-1), fetched last cycle
                    if (row_ptr > 7'd0)
                        product_out[(row_ptr - 7'd1) * 4 +: 4] <= dot[13:10];

                    if (row_ptr == 7'd64)
                        state <= DONE;
                    else
                        row_ptr <= row_ptr + 7'd1;
                end

                DONE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
