//------------------------------------------------------------------------------
// scratchpad
//------------------------------------------------------------------------------
// Ping-pong tile storage for activation and weight rows.
//
// Weight and activation banks are tracked by two independent active/inactive
// pointers (weight_active_bank_r / act_active_bank_r), each with its own
// swap pulse, so weight preload and activation load can proceed
// independently -- required for preload-while-computing: the weight bank
// must become active for reading as soon as its own load finishes,
// regardless of activation-load progress.
//
// Storage: flip-flop arrays (weight_mem_r/act_mem_r) -- a real SRAM macro
// at this depth is dominated by fixed decoder/sense-amp overhead. Being
// flip-flops rather than a true SRAM macro is what makes the widening
// below cheap: extra ports are just more mux/decode logic.
//
// Widened write port: the host bus delivers two rows per cycle (wr_addr is
// a row-pair index; wr_data packs row 2*wr_addr in its lower half and
// 2*wr_addr+1 in its upper half). Widened weight read: a second,
// independent read pipeline (rd_weight_row_b/rd_weight_data_b) feeds
// array_top's second shadow-shift chain, so shadow preload also completes
// in half the time. Activation reads stay single-port/single-row: the
// array only ever consumes one new activation column per cycle.
//------------------------------------------------------------------------------
module scratchpad #(
    parameter int ARRAY_SIZE       = 16,
    parameter int DATA_WIDTH       = 8,
    parameter int SCRATCHPAD_DEPTH = 4096,
    parameter int NUM_BANKS        = 2
)(
    input  logic                                         clk,
    input  logic                                         rst_n,

    // Bank swaps -- DMA asserts each independently for one cycle
    input  logic                                         wr_weight_bank_swap,
    input  logic                                         wr_act_bank_swap,

    // Write port — DMA writes two complete ARRAY_SIZE-byte rows per cycle.
    // wr_addr selects the PAIR (rows 2*wr_addr and 2*wr_addr+1); wr_data's
    // lower half is row 2*wr_addr, upper half is row 2*wr_addr+1.
    input  logic                                         wr_en,
    input  logic                                         wr_type,    // 0=weight  1=activation
    input  logic [$clog2(ARRAY_SIZE/2)-1:0]              wr_addr,
    input  logic [2*ARRAY_SIZE*DATA_WIDTH-1:0]           wr_data,

    // Weight read — TWO independent full rows per cycle from the active
    // weight bank (2-cycle latency each), feeding array_top's two shadow
    // shift-chain entry points.
    input  logic [$clog2(ARRAY_SIZE)-1:0]                rd_weight_row_a,
    output logic [DATA_WIDTH-1:0]                        rd_weight_data_a [ARRAY_SIZE],
    input  logic [$clog2(ARRAY_SIZE)-1:0]                rd_weight_row_b,
    output logic [DATA_WIDTH-1:0]                        rd_weight_data_b [ARRAY_SIZE],

    // Activation read — one full row per cycle from the active activation
    // bank (2-cycle latency)
    input  logic [$clog2(ARRAY_SIZE)-1:0]                rd_act_row,
    output logic [DATA_WIDTH-1:0]                        rd_act_data [ARRAY_SIZE]
);

    localparam int ROW_W     = $clog2(ARRAY_SIZE);
    localparam int PAIR_W    = $clog2(ARRAY_SIZE/2);
    localparam int ROW_WIDTH = ARRAY_SIZE * DATA_WIDTH;

    // ------------------------------------------------------------------
    // Independent active-bank tracking, one per memory type.
    // ------------------------------------------------------------------
    logic weight_active_bank_r;
    logic act_active_bank_r;

    always_ff @(posedge clk) begin
        if (!rst_n)
            weight_active_bank_r <= 1'b0;
        else if (wr_weight_bank_swap)
            weight_active_bank_r <= ~weight_active_bank_r;
    end

    always_ff @(posedge clk) begin
        if (!rst_n)
            act_active_bank_r <= 1'b0;
        else if (wr_act_bank_swap)
            act_active_bank_r <= ~act_active_bank_r;
    end

    logic weight_inactive_bank;
    logic act_inactive_bank;
    assign weight_inactive_bank = ~weight_active_bank_r;
    assign act_inactive_bank    = ~act_active_bank_r;

    // ------------------------------------------------------------------
    // Storage: one full row (ARRAY_SIZE*DATA_WIDTH bits) per address, per
    // bank. Each write lands two rows (low/high halves of wr_data) at
    // addresses 2*wr_addr and 2*wr_addr+1 in the same cycle.
    // ------------------------------------------------------------------
    logic [ROW_WIDTH-1:0] weight_mem_r [NUM_BANKS][ARRAY_SIZE];
    logic [ROW_WIDTH-1:0] act_mem_r    [NUM_BANKS][ARRAY_SIZE];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int bi = 0; bi < NUM_BANKS; bi++) begin
                for (int r = 0; r < ARRAY_SIZE; r++) begin
                    weight_mem_r[bi][r] <= '0;
                    act_mem_r[bi][r]    <= '0;
                end
            end
        end else begin
            if (wr_en && !wr_type) begin
                weight_mem_r[weight_inactive_bank][{wr_addr, 1'b0}] <= wr_data[ROW_WIDTH-1:0];
                weight_mem_r[weight_inactive_bank][{wr_addr, 1'b1}] <= wr_data[2*ROW_WIDTH-1:ROW_WIDTH];
            end
            if (wr_en && wr_type) begin
                act_mem_r[act_inactive_bank][{wr_addr, 1'b0}] <= wr_data[ROW_WIDTH-1:0];
                act_mem_r[act_inactive_bank][{wr_addr, 1'b1}] <= wr_data[2*ROW_WIDTH-1:ROW_WIDTH];
            end
        end
    end

    // ------------------------------------------------------------------
    // Read pipeline: address register + data register (2 cycles) per
    // memory type/port, each gated by its own active-bank pointer. Weight
    // reads have two fully independent instances (_a/_b) so array_top's two
    // shadow shift-chain entry points can each pull a different row on the
    // same cycle.
    // ------------------------------------------------------------------
    logic [ROW_W-1:0]     rd_weight_row_a_r1, rd_weight_row_b_r1, rd_act_row_r1;
    logic                 weight_active_cmd_r, weight_active_data_r;
    logic                 act_active_cmd_r, act_active_data_r;
    logic [ROW_WIDTH-1:0] weight_rdata_a_r [NUM_BANKS];
    logic [ROW_WIDTH-1:0] weight_rdata_b_r [NUM_BANKS];
    logic [ROW_WIDTH-1:0] act_rdata_r      [NUM_BANKS];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_weight_row_a_r1    <= '0;
            rd_weight_row_b_r1    <= '0;
            rd_act_row_r1         <= '0;
            weight_active_cmd_r   <= 1'b0;
            weight_active_data_r  <= 1'b0;
            act_active_cmd_r      <= 1'b0;
            act_active_data_r     <= 1'b0;
            for (int bi = 0; bi < NUM_BANKS; bi++) begin
                weight_rdata_a_r[bi] <= '0;
                weight_rdata_b_r[bi] <= '0;
                act_rdata_r[bi]      <= '0;
            end
        end else begin
            rd_weight_row_a_r1    <= rd_weight_row_a;
            rd_weight_row_b_r1    <= rd_weight_row_b;
            rd_act_row_r1         <= rd_act_row;
            weight_active_cmd_r   <= weight_active_bank_r;
            weight_active_data_r  <= weight_active_cmd_r;
            act_active_cmd_r      <= act_active_bank_r;
            act_active_data_r     <= act_active_cmd_r;
            for (int bi = 0; bi < NUM_BANKS; bi++) begin
                weight_rdata_a_r[bi] <= weight_mem_r[bi][rd_weight_row_a_r1];
                weight_rdata_b_r[bi] <= weight_mem_r[bi][rd_weight_row_b_r1];
                act_rdata_r[bi]      <= act_mem_r[bi][rd_act_row_r1];
            end
        end
    end

    genvar c;
    generate
        for (c = 0; c < ARRAY_SIZE; c++) begin : unpack_gen
            assign rd_weight_data_a[c] = weight_rdata_a_r[weight_active_data_r][c*DATA_WIDTH +: DATA_WIDTH];
            assign rd_weight_data_b[c] = weight_rdata_b_r[weight_active_data_r][c*DATA_WIDTH +: DATA_WIDTH];
            assign rd_act_data[c]      = act_rdata_r[act_active_data_r][c*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

endmodule
