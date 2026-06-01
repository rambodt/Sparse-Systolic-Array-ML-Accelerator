//------------------------------------------------------------------------------
// dma_ctrl
//------------------------------------------------------------------------------
// Tile-level control FSM for one 16x16-by-16x16 GEMM tile product.
//
// The controller accepts host row writes, fills the inactive scratchpad bank,
// flips banks, preloads weights into the systolic array, streams activation rows,
// and generates a one-cycle done pulse after drain/accumulation latency. Larger
// MxK by KxN GEMMs are handled by software/testbench loops around this unit.
//------------------------------------------------------------------------------
module dma_ctrl #(
    parameter int ARRAY_SIZE = 16,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
)(
    input  logic clk,
    input  logic rst_n,

    // Host control
    input  logic  start,
    output logic  done,

    // Host write port — host feeds one complete ARRAY_SIZE-byte row per cycle.
    input  logic                                         host_wr_en,
    input  logic [$clog2(ARRAY_SIZE)-1:0]                host_wr_addr,
    input  logic [ARRAY_SIZE*DATA_WIDTH-1:0]             host_wr_data,
    output logic                                         host_wr_rdy,

    // Scratchpad write port
    output logic                                         sp_wr_en,
    output logic                                         sp_wr_type,    // 0=weight  1=activation
    output logic [$clog2(ARRAY_SIZE)-1:0]                sp_wr_addr,
    output logic [ARRAY_SIZE*DATA_WIDTH-1:0]             sp_wr_data,

    // Scratchpad read control
    output logic [$clog2(ARRAY_SIZE)-1:0]                sp_rd_weight_row,
    output logic [$clog2(ARRAY_SIZE)-1:0]                sp_rd_act_row,
    output logic                                         sp_bank_swap,

    // Array control
    output logic                                         weight_load_en,
    output logic                                         act_col_vld
);

    // ------------------------------------------------------------------
    // State encoding
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE         = 3'd0,
        LOAD_WEIGHTS = 3'd1,
        LOAD_ACTS    = 3'd2,
        PRELOAD_PE   = 3'd3,
        COMPUTE      = 3'd4,
        DRAIN        = 3'd5,
        ACCUMULATE   = 3'd6,
        DONE         = 3'd7
    } state_t;

    state_t state_r, state_next;

    // ------------------------------------------------------------------
    // Local constants
    // ------------------------------------------------------------------
    localparam int ROW_W      = $clog2(ARRAY_SIZE);
    // DRAIN covers the post-compute array/output-buffer pipeline. The PE has a
    // registered activation operand plus multiply/accumulate stages, and the
    // output buffer pipelines the final accumulator write.
    localparam int PHASE_W    = $clog2(3 * ARRAY_SIZE) + 1;

    // ------------------------------------------------------------------
    // Counters
    // ------------------------------------------------------------------
    logic [ROW_W-1:0]    row_cnt_r;    // rows received in LOAD_WEIGHTS / LOAD_ACTS
    logic [PHASE_W-1:0]  phase_cnt_r;  // cycles elapsed in PRELOAD_PE / COMPUTE / DRAIN

    // ------------------------------------------------------------------
    // State register
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) state_r <= IDLE;
        else        state_r <= state_next;
    end

    // ------------------------------------------------------------------
    // Next-state logic
    // ------------------------------------------------------------------
    always_comb begin
        state_next = state_r;
        case (state_r)
            IDLE:         if (start)                                                        state_next = LOAD_WEIGHTS;
            LOAD_WEIGHTS: if (host_wr_en && row_cnt_r == ROW_W'(ARRAY_SIZE - 1))           state_next = LOAD_ACTS;
            LOAD_ACTS:    if (host_wr_en && row_cnt_r == ROW_W'(ARRAY_SIZE - 1))           state_next = PRELOAD_PE;
            PRELOAD_PE:   if (phase_cnt_r == PHASE_W'(ARRAY_SIZE))                         state_next = COMPUTE;
            COMPUTE:      if (phase_cnt_r == PHASE_W'(ARRAY_SIZE))                         state_next = DRAIN;
            DRAIN:        if (phase_cnt_r == PHASE_W'(3 * ARRAY_SIZE))                     state_next = ACCUMULATE;
            ACCUMULATE:                                                                     state_next = DONE;
            DONE:                                                                           state_next = IDLE;
            default:                                                                        state_next = IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Counter registers
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            row_cnt_r   <= '0;
            phase_cnt_r <= '0;
        end else begin
            case (state_r)
                LOAD_WEIGHTS, LOAD_ACTS: begin
                    if (host_wr_en) begin
                        if (row_cnt_r == ROW_W'(ARRAY_SIZE - 1)) row_cnt_r <= '0;
                        else                                      row_cnt_r <= row_cnt_r + 1'b1;
                    end
                    phase_cnt_r <= '0;
                end

                PRELOAD_PE, COMPUTE, DRAIN: begin
                    row_cnt_r <= '0;
                    if (state_next != state_r) phase_cnt_r <= '0;
                    else                       phase_cnt_r <= phase_cnt_r + 1'b1;
                end

                default: begin
                    row_cnt_r   <= '0;
                    phase_cnt_r <= '0;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Output logic
    // ------------------------------------------------------------------

    // Host write passthrough to scratchpad — active only in LOAD_* states
    assign host_wr_rdy = (state_r == LOAD_WEIGHTS) || (state_r == LOAD_ACTS);
    assign sp_wr_en    = host_wr_rdy && host_wr_en;
    assign sp_wr_type  = (state_r == LOAD_ACTS) ? 1'b1 : 1'b0;  // DMA determines type by state
    assign sp_wr_addr  = host_wr_addr;
    assign sp_wr_data  = host_wr_data;

    // Bank swap: one-cycle pulse at the last write of LOAD_ACTS
    // Swap takes effect on the next edge — active bank is ready for PRELOAD_PE
    assign sp_bank_swap = (state_r == LOAD_ACTS) &&
                          host_wr_en             &&
                          (row_cnt_r == ROW_W'(ARRAY_SIZE - 1));

    // ------------------------------------------------------------------
    // Weight preload read address
    // Issued one cycle ahead of when data is needed (1-cycle SRAM latency).
    // phase_cnt 0: present row ARRAY_SIZE-1 → data valid at phase_cnt 1
    // phase_cnt k: present row ARRAY_SIZE-1-k → data valid at phase_cnt k+1
    // weight_load_en goes high at phase_cnt 1 (when first data is valid)
    // ------------------------------------------------------------------
    always_comb begin
        if (state_r == PRELOAD_PE && phase_cnt_r < PHASE_W'(ARRAY_SIZE))
            sp_rd_weight_row = ROW_W'(ARRAY_SIZE - 1) - ROW_W'(phase_cnt_r[ROW_W-1:0]);
        else
            sp_rd_weight_row = '0;
    end

    assign weight_load_en = (state_r == PRELOAD_PE) && (phase_cnt_r >= 1);

    // ------------------------------------------------------------------
    // Activation streaming read address
    // Same 1-cycle latency pattern: phase_cnt 0 → row 0 address issued,
    // data valid at phase_cnt 1 → act_col_vld asserted.
    // ------------------------------------------------------------------
    always_comb begin
        if (state_r == COMPUTE && phase_cnt_r < PHASE_W'(ARRAY_SIZE))
            sp_rd_act_row = ROW_W'(phase_cnt_r[ROW_W-1:0]);
        else
            sp_rd_act_row = '0;
    end

    assign act_col_vld = (state_r == COMPUTE) && (phase_cnt_r >= 1);

    // Done
    assign done = (state_r == DONE);

endmodule
