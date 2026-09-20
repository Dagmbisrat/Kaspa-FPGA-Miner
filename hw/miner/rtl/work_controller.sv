// work_controller -- transport-agnostic register-bus slave between a
// transport adapter (uart_if today) and one core. Implements the map in
// docs/miner/work_controller.md: stores job fields, pulses core.start once
// loaded, and collects core's winning nonces into a small FIFO the host
// polls. Knows nothing about UART -- only the plain addr/wdata/rdata/we/re
// bus, so a different adapter (pcie_if/axi_if) needs no changes here.
//
// Multi-word fields (PPH, TARGET) are split into 32-bit words, word 0 =
// bits [31:0] (little-endian word order) -- this convention isn't fixed
// anywhere else, so it's stated here for whoever writes the host side.
module work_controller #(
    parameter int FOUND_DEPTH = 4   // must be a power of 2 (pointer wraparound relies on it)
) (
    input  logic         clk,
    input  logic         rst,

    input  logic [7:0]   addr,
    input  logic [31:0]  wdata,
    input  logic         we,
    input  logic         re,
    output logic [31:0]  rdata,

    output logic          start,
    output logic [255:0]  pre_pow_hash,
    output logic [63:0]   timestamp,
    output logic [63:0]   nonce,
    output logic [255:0]  target,

    input  logic          found,
    input  logic [63:0]   found_nonce,
    input  logic [7:0]    found_work_id
);

    localparam logic [7:0] ADDR_CTRL         = 8'h00;
    localparam logic [7:0] ADDR_STATUS       = 8'h04;
    localparam logic [7:0] ADDR_PPH0         = 8'h08;
    localparam logic [7:0] ADDR_PPH1         = 8'h0C;
    localparam logic [7:0] ADDR_PPH2         = 8'h10;
    localparam logic [7:0] ADDR_PPH3         = 8'h14;
    localparam logic [7:0] ADDR_PPH4         = 8'h18;
    localparam logic [7:0] ADDR_PPH5         = 8'h1C;
    localparam logic [7:0] ADDR_PPH6         = 8'h20;
    localparam logic [7:0] ADDR_PPH7         = 8'h24;
    localparam logic [7:0] ADDR_TS0          = 8'h28;
    localparam logic [7:0] ADDR_TS1          = 8'h2C;
    localparam logic [7:0] ADDR_TGT0         = 8'h30;
    localparam logic [7:0] ADDR_TGT1         = 8'h34;
    localparam logic [7:0] ADDR_TGT2         = 8'h38;
    localparam logic [7:0] ADDR_TGT3         = 8'h3C;
    localparam logic [7:0] ADDR_TGT4         = 8'h40;
    localparam logic [7:0] ADDR_TGT5         = 8'h44;
    localparam logic [7:0] ADDR_TGT6         = 8'h48;
    localparam logic [7:0] ADDR_TGT7         = 8'h4C;
    localparam logic [7:0] ADDR_NONCE0       = 8'h50;
    localparam logic [7:0] ADDR_NONCE1       = 8'h54;
    localparam logic [7:0] ADDR_FOUND_NONCE0 = 8'h58;
    localparam logic [7:0] ADDR_FOUND_NONCE1 = 8'h5C;
    localparam logic [7:0] ADDR_FOUND_WORKID = 8'h60;
    localparam logic [7:0] ADDR_FOUND_COUNT  = 8'h64;

    // ------------------------------------------------------------------
    // Job registers: plain per-word storage, concatenated into the wide
    // core ports. core only samples these at the instant `start` pulses,
    // so building a job up one word at a time is never a hazard.
    // ------------------------------------------------------------------
    logic [31:0] pph_words [0:7];
    logic [31:0] ts_words  [0:1];
    logic [31:0] tgt_words [0:7];
    logic [31:0] nb_words  [0:1];

    assign pre_pow_hash = {pph_words[7], pph_words[6], pph_words[5], pph_words[4],
                            pph_words[3], pph_words[2], pph_words[1], pph_words[0]};
    assign timestamp    = {ts_words[1], ts_words[0]};
    assign target       = {tgt_words[7], tgt_words[6], tgt_words[5], tgt_words[4],
                            tgt_words[3], tgt_words[2], tgt_words[1], tgt_words[0]};
    assign nonce        = {nb_words[1], nb_words[0]};

    assign start = we && (addr == ADDR_CTRL) && wdata[0];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int i = 0; i < 8; i++) pph_words[i] <= '0;
            for (int i = 0; i < 2; i++) ts_words[i]  <= '0;
            for (int i = 0; i < 8; i++) tgt_words[i] <= '0;
            for (int i = 0; i < 2; i++) nb_words[i]  <= '0;
        end else if (we) begin
            case (addr)
                ADDR_PPH0: pph_words[0] <= wdata;
                ADDR_PPH1: pph_words[1] <= wdata;
                ADDR_PPH2: pph_words[2] <= wdata;
                ADDR_PPH3: pph_words[3] <= wdata;
                ADDR_PPH4: pph_words[4] <= wdata;
                ADDR_PPH5: pph_words[5] <= wdata;
                ADDR_PPH6: pph_words[6] <= wdata;
                ADDR_PPH7: pph_words[7] <= wdata;
                ADDR_TS0:  ts_words[0]  <= wdata;
                ADDR_TS1:  ts_words[1]  <= wdata;
                ADDR_TGT0: tgt_words[0] <= wdata;
                ADDR_TGT1: tgt_words[1] <= wdata;
                ADDR_TGT2: tgt_words[2] <= wdata;
                ADDR_TGT3: tgt_words[3] <= wdata;
                ADDR_TGT4: tgt_words[4] <= wdata;
                ADDR_TGT5: tgt_words[5] <= wdata;
                ADDR_TGT6: tgt_words[6] <= wdata;
                ADDR_TGT7: tgt_words[7] <= wdata;
                ADDR_NONCE0: nb_words[0] <= wdata;
                ADDR_NONCE1: nb_words[1] <= wdata;
                default: ; // ADDR_CTRL (handled combinationally above) and unmapped addresses
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Found FIFO. Push is unconditional on `found` -- pushes are rare
    // enough that overflow handling isn't worth the complexity; falling
    // more than FOUND_DEPTH finds behind just overwrites the oldest
    // unread entry.
    // ------------------------------------------------------------------
    localparam int FOUND_ABITS = $clog2(FOUND_DEPTH);

    logic [63:0] found_nonce_mem  [0:FOUND_DEPTH-1];
    logic [7:0]  found_workid_mem [0:FOUND_DEPTH-1];
    logic [FOUND_ABITS-1:0] found_wr_ptr, found_rd_ptr;
    logic [FOUND_ABITS:0]   found_count;

    logic do_push, do_pop;
    assign do_push = found;
    assign do_pop  = re && (addr == ADDR_FOUND_NONCE0) && (found_count != '0);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            found_wr_ptr <= '0;
        end else if (do_push) begin
            found_nonce_mem[found_wr_ptr]  <= found_nonce;
            found_workid_mem[found_wr_ptr] <= found_work_id;
            found_wr_ptr <= found_wr_ptr + 1'b1;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            found_count <= '0;
        end else begin
            case ({do_push, do_pop})
                2'b10:   found_count <= (found_count == FOUND_DEPTH[FOUND_ABITS:0]) ? found_count : found_count + 1'b1;
                2'b01:   found_count <= found_count - 1'b1;
                default: found_count <= found_count; // 00 or 11 (push+pop nets to unchanged)
            endcase
        end
    end

    // Upper nonce word + work_id of the popped entry, held for the
    // FOUND_NONCE[1]/FOUND_WORKID reads that follow a FOUND_NONCE[0] pop
    // -- those reads don't move found_rd_ptr. The lower word doesn't need
    // holding: it's returned straight from the FIFO at pop time.
    logic [31:0] cur_nonce_hi;
    logic [7:0]  cur_workid;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rdata        <= '0;
            found_rd_ptr <= '0;
            cur_nonce_hi <= '0;
            cur_workid   <= '0;
        end else if (re) begin
            case (addr)
                ADDR_PPH0: rdata <= pph_words[0];
                ADDR_PPH1: rdata <= pph_words[1];
                ADDR_PPH2: rdata <= pph_words[2];
                ADDR_PPH3: rdata <= pph_words[3];
                ADDR_PPH4: rdata <= pph_words[4];
                ADDR_PPH5: rdata <= pph_words[5];
                ADDR_PPH6: rdata <= pph_words[6];
                ADDR_PPH7: rdata <= pph_words[7];
                ADDR_TS0:  rdata <= ts_words[0];
                ADDR_TS1:  rdata <= ts_words[1];
                ADDR_TGT0: rdata <= tgt_words[0];
                ADDR_TGT1: rdata <= tgt_words[1];
                ADDR_TGT2: rdata <= tgt_words[2];
                ADDR_TGT3: rdata <= tgt_words[3];
                ADDR_TGT4: rdata <= tgt_words[4];
                ADDR_TGT5: rdata <= tgt_words[5];
                ADDR_TGT6: rdata <= tgt_words[6];
                ADDR_TGT7: rdata <= tgt_words[7];
                ADDR_NONCE0: rdata <= nb_words[0];
                ADDR_NONCE1: rdata <= nb_words[1];
                ADDR_STATUS: rdata <= {30'b0, (found_count != '0), 1'b0};
                ADDR_FOUND_COUNT: rdata <= {{(32-FOUND_ABITS-1){1'b0}}, found_count};

                ADDR_FOUND_NONCE0: begin
                    if (found_count != '0) begin
                        rdata        <= found_nonce_mem[found_rd_ptr][31:0];
                        cur_nonce_hi <= found_nonce_mem[found_rd_ptr][63:32];
                        cur_workid   <= found_workid_mem[found_rd_ptr];
                        found_rd_ptr <= found_rd_ptr + 1'b1;
                    end else begin
                        rdata <= 32'b0;
                    end
                end
                ADDR_FOUND_NONCE1: rdata <= cur_nonce_hi;
                ADDR_FOUND_WORKID: rdata <= {24'b0, cur_workid};

                default: rdata <= 32'b0;
            endcase
        end
    end

endmodule
