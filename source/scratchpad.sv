module scratchpad #(
    parameter int ARRAY_SIZE       = 16,
    parameter int DATA_WIDTH       = 8,
    parameter int SCRATCHPAD_DEPTH = 4096,
    parameter int NUM_BANKS        = 2
)(
    input  logic                                         clk,
    input  logic                                         rst_n,

    // Bank swap — DMA asserts for one cycle to flip active/inactive
    input  logic                                         bank_swap,

    // Write port — DMA writes to inactive bank, one word per cycle
    input  logic                                         wr_en,
    input  logic                                         wr_type,    // 0=weight  1=activation
    input  logic [$clog2(ARRAY_SIZE*ARRAY_SIZE)-1:0]     wr_addr,
    input  logic [DATA_WIDTH-1:0]                        wr_data,

    // Weight read — one full row per cycle from active bank (1-cycle latency)
    input  logic [$clog2(ARRAY_SIZE)-1:0]                rd_weight_row,
    output logic [DATA_WIDTH-1:0]                        rd_weight_data [ARRAY_SIZE],

    // Activation read — one full row per cycle from active bank (1-cycle latency)
    input  logic [$clog2(ARRAY_SIZE)-1:0]                rd_act_row,
    output logic [DATA_WIDTH-1:0]                        rd_act_data [ARRAY_SIZE]
);

    // ------------------------------------------------------------------
    // Active bank tracking
    // ------------------------------------------------------------------
    logic active_bank_r;

    always_ff @(posedge clk) begin
        if (!rst_n)
            active_bank_r <= 1'b0;
        else if (bank_swap)
            active_bank_r <= ~active_bank_r;
    end

    // Inactive bank is always the opposite of active
    logic inactive_bank;
    assign inactive_bank = ~active_bank_r;

    // ------------------------------------------------------------------
    // Row-wide SRAM organization.
    // Each memory word stores one complete ARRAY_SIZE-byte row.  Byte masks
    // preserve the existing host/DMA interface, which writes one byte/cycle.
    // ------------------------------------------------------------------
    localparam int BYTES_PER_LANE = 4;
    localparam int LANE_COUNT     = ARRAY_SIZE / BYTES_PER_LANE;
    localparam int LANE_WIDTH     = BYTES_PER_LANE * DATA_WIDTH;
    localparam int SRAM_ROWS      = 64;  // Smallest 32-bit-wide fakeram size this flow generates.
    localparam int SRAM_ADDR_W    = $clog2(SRAM_ROWS);
    localparam int ROW_ADDR_W     = $clog2(ARRAY_SIZE);
    localparam int LANE_ADDR_W    = (LANE_COUNT > 1) ? $clog2(LANE_COUNT) : 1;
    localparam int BYTE_ADDR_W    = $clog2(BYTES_PER_LANE);
    localparam int TILE_ADDR_W    = $clog2(ARRAY_SIZE * ARRAY_SIZE);

    logic [ROW_ADDR_W-1:0] wr_row;
    logic [ROW_ADDR_W-1:0] wr_col;
    logic [LANE_ADDR_W-1:0] wr_lane;
    logic [BYTE_ADDR_W-1:0] wr_byte;
    logic [LANE_WIDTH-1:0]  wr_lane_data;
    logic [SRAM_ADDR_W-1:0] wr_sram_addr;
    logic [SRAM_ADDR_W-1:0] rd_weight_sram_addr;
    logic [SRAM_ADDR_W-1:0] rd_act_sram_addr;

    assign wr_row             = wr_addr[TILE_ADDR_W-1 -: ROW_ADDR_W];
    assign wr_col             = wr_addr[ROW_ADDR_W-1:0];
    assign wr_byte            = wr_col[BYTE_ADDR_W-1:0];
    assign wr_lane_data       = {BYTES_PER_LANE{wr_data}};
    assign wr_sram_addr       = {{(SRAM_ADDR_W-ROW_ADDR_W){1'b0}}, wr_row};
    assign rd_weight_sram_addr = {{(SRAM_ADDR_W-ROW_ADDR_W){1'b0}}, rd_weight_row};
    assign rd_act_sram_addr    = {{(SRAM_ADDR_W-ROW_ADDR_W){1'b0}}, rd_act_row};

    generate
        if (LANE_COUNT == 1) begin : single_lane_addr
            assign wr_lane = '0;
        end else begin : multi_lane_addr
            assign wr_lane = wr_col[ROW_ADDR_W-1:BYTE_ADDR_W];
        end
    endgenerate

    logic [LANE_WIDTH-1:0]       weight_rdata [NUM_BANKS][LANE_COUNT];
    logic [LANE_WIDTH-1:0]       act_rdata    [NUM_BANKS][LANE_COUNT];
    logic [BYTES_PER_LANE-1:0]   weight_wmask [NUM_BANKS][LANE_COUNT];
    logic [BYTES_PER_LANE-1:0]   act_wmask    [NUM_BANKS][LANE_COUNT];
    logic                        weight_v_r   [NUM_BANKS][LANE_COUNT];
    logic                        act_v_r      [NUM_BANKS][LANE_COUNT];
    logic                        weight_w_r   [NUM_BANKS][LANE_COUNT];
    logic                        act_w_r      [NUM_BANKS][LANE_COUNT];
    logic [SRAM_ADDR_W-1:0]      weight_addr_r [NUM_BANKS][LANE_COUNT];
    logic [SRAM_ADDR_W-1:0]      act_addr_r    [NUM_BANKS][LANE_COUNT];
    logic [LANE_WIDTH-1:0]       weight_wdata_r[NUM_BANKS][LANE_COUNT];
    logic [LANE_WIDTH-1:0]       act_wdata_r   [NUM_BANKS][LANE_COUNT];
    logic [BYTES_PER_LANE-1:0]   weight_wmask_r[NUM_BANKS][LANE_COUNT];
    logic [BYTES_PER_LANE-1:0]   act_wmask_r   [NUM_BANKS][LANE_COUNT];
    logic                        active_bank_cmd_r;
    logic                        active_bank_data_r;

    always_comb begin
        for (int b = 0; b < NUM_BANKS; b++) begin
            for (int l = 0; l < LANE_COUNT; l++) begin
                weight_wmask[b][l] = '0;
                act_wmask[b][l]    = '0;
            end
        end

        if (wr_en) begin
            if (!wr_type)
                weight_wmask[inactive_bank][wr_lane][wr_byte] = 1'b1;
            else
                act_wmask[inactive_bank][wr_lane][wr_byte] = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_bank_cmd_r  <= 1'b0;
            active_bank_data_r <= 1'b0;
            for (int bi = 0; bi < NUM_BANKS; bi++) begin
                for (int li = 0; li < LANE_COUNT; li++) begin
                    weight_v_r[bi][li]     <= 1'b0;
                    act_v_r[bi][li]        <= 1'b0;
                    weight_w_r[bi][li]     <= 1'b0;
                    act_w_r[bi][li]        <= 1'b0;
                    weight_addr_r[bi][li]  <= '0;
                    act_addr_r[bi][li]     <= '0;
                    weight_wdata_r[bi][li] <= '0;
                    act_wdata_r[bi][li]    <= '0;
                    weight_wmask_r[bi][li] <= '0;
                    act_wmask_r[bi][li]    <= '0;
                end
            end
        end else begin
            active_bank_cmd_r  <= active_bank_r;
            active_bank_data_r <= active_bank_cmd_r;

            for (int bi = 0; bi < NUM_BANKS; bi++) begin
                for (int li = 0; li < LANE_COUNT; li++) begin
                    weight_v_r[bi][li]     <= (active_bank_r == (bi == 1));
                    act_v_r[bi][li]        <= (active_bank_r == (bi == 1));
                    weight_w_r[bi][li]     <= 1'b0;
                    act_w_r[bi][li]        <= 1'b0;
                    weight_addr_r[bi][li]  <= rd_weight_sram_addr;
                    act_addr_r[bi][li]     <= rd_act_sram_addr;
                    weight_wdata_r[bi][li] <= wr_lane_data;
                    act_wdata_r[bi][li]    <= wr_lane_data;
                    weight_wmask_r[bi][li] <= '0;
                    act_wmask_r[bi][li]    <= '0;
                end
            end

            if (wr_en && !wr_type) begin
                weight_v_r[inactive_bank][wr_lane]     <= 1'b1;
                weight_w_r[inactive_bank][wr_lane]     <= 1'b1;
                weight_addr_r[inactive_bank][wr_lane]  <= wr_sram_addr;
                weight_wdata_r[inactive_bank][wr_lane] <= wr_lane_data;
                weight_wmask_r[inactive_bank][wr_lane] <= weight_wmask[inactive_bank][wr_lane];
            end

            if (wr_en && wr_type) begin
                act_v_r[inactive_bank][wr_lane]     <= 1'b1;
                act_w_r[inactive_bank][wr_lane]     <= 1'b1;
                act_addr_r[inactive_bank][wr_lane]  <= wr_sram_addr;
                act_wdata_r[inactive_bank][wr_lane] <= wr_lane_data;
                act_wmask_r[inactive_bank][wr_lane] <= act_wmask[inactive_bank][wr_lane];
            end
        end
    end

    genvar b, l;
    generate
        for (b = 0; b < NUM_BANKS; b++) begin : bank_gen
            for (l = 0; l < LANE_COUNT; l++) begin : lane_gen
                bsg_mem_1rw_sync_mask_write_byte #(
                    .data_width_p (LANE_WIDTH),
                    .els_p        (SRAM_ROWS)
                ) u_weight_mem (
                    .clk_i        (clk),
                    .reset_i      (~rst_n),
                    .v_i          (weight_v_r[b][l]),
                    .w_i          (weight_w_r[b][l]),
                    .addr_i       (weight_addr_r[b][l]),
                    .data_i       (weight_wdata_r[b][l]),
                    .write_mask_i (weight_wmask_r[b][l]),
                    .data_o       (weight_rdata[b][l])
                );

                bsg_mem_1rw_sync_mask_write_byte #(
                    .data_width_p (LANE_WIDTH),
                    .els_p        (SRAM_ROWS)
                ) u_act_mem (
                    .clk_i        (clk),
                    .reset_i      (~rst_n),
                    .v_i          (act_v_r[b][l]),
                    .w_i          (act_w_r[b][l]),
                    .addr_i       (act_addr_r[b][l]),
                    .data_i       (act_wdata_r[b][l]),
                    .write_mask_i (act_wmask_r[b][l]),
                    .data_o       (act_rdata[b][l])
                );
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Read: one command register plus synchronous SRAM output latency.
    // ------------------------------------------------------------------
    genvar c;
    generate
        for (c = 0; c < ARRAY_SIZE; c++) begin : unpack_gen
            localparam int LANE = c / BYTES_PER_LANE;
            localparam int BYTE = c % BYTES_PER_LANE;

            assign rd_weight_data[c] = weight_rdata[active_bank_data_r][LANE][BYTE*DATA_WIDTH +: DATA_WIDTH];
            assign rd_act_data[c]    = act_rdata[active_bank_data_r][LANE][BYTE*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

endmodule
