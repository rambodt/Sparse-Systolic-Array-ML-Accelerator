//------------------------------------------------------------------------------
// array_top
//------------------------------------------------------------------------------
// Weight-stationary 2-D systolic MAC array.
//
// Weights are shifted from the top row down during PRELOAD_PE, then held in each
// PE. Activations enter from the left and move left-to-right. Partial sums move
// top-to-bottom and emerge from the bottom row as a diagonally staggered stream.
//
// The activation and skip-enable delay chains are deliberately matched to the
// two-stage PE pipeline so each zero-detect flag reaches a PE in the same cycle
// as the activation value it describes.
//------------------------------------------------------------------------------
module array_top #(
    parameter int ARRAY_SIZE = 16,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
)(
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [DATA_WIDTH-1:0]   act_col_in    [ARRAY_SIZE],
    input  logic                    act_col_vld,

    // Shadow (next-tile) weight preload chain -- the array's only weight
    // load path. Feeds every PE's shadow register; weight_commit copies
    // each PE's shadow into its live register on the same cycle, so the
    // array moves to the next tile with no preload stall. Each PE has five
    // shadow registers; shadow_load_sel picks which one (0..4) this
    // cycle's shift targets, global/undelayed since the whole chain must
    // agree on which register it's loading.
    //
    // Two independent shift chains: chain A enters at row 0 and covers
    // rows 0..ARRAY_SIZE/2-1, chain B enters at row ARRAY_SIZE/2 and
    // covers the rest, each running the same reversed-order, 1-cycle/row
    // shift over half the rows -- both finish in ARRAY_SIZE/2 cycles
    // instead of ARRAY_SIZE, matching the widened scratchpad weight-read
    // port (see dma_ctrl.sv).
    input  logic [DATA_WIDTH-1:0]   shadow_load_in_a [ARRAY_SIZE],
    input  logic [DATA_WIDTH-1:0]   shadow_load_in_b [ARRAY_SIZE],
    input  logic                    shadow_load_en,
    input  logic [2:0]              shadow_load_sel,

    // Per-PE staggered commit: a pulse, asserted when the current tile's
    // last activation row is issued, that ripples through the same
    // row-stagger/column-propagation delay network activations use (see
    // commit_row_stagger/commit_col0/commit_shift below), so weight_commit
    // arrives at PE[r][j] exactly when that PE reads its old weight for
    // the last time. commit_sel rides the identical delay network so it
    // arrives at each PE in lockstep, telling it which shadow buffer to
    // read at its own commit moment.
    input  logic                    commit_trigger,
    input  logic [2:0]              commit_sel,

    input  logic [ARRAY_SIZE-1:0]   skip_en_col,

    output logic [ACC_WIDTH-1:0]    psum_out_row [ARRAY_SIZE],
    output logic                    psum_out_vld
);

    // ------------------------------------------------------------------
    // Stagger shift registers → left-column activation inputs
    // Row 0: 1-cycle delay (one register).
    // Row r: 2*r+1 cycles delay. The pipelined PE takes two cycles to move
    // a psum contribution down one row, so consecutive activation rows must
    // be spaced by two cycles to meet the matching psum token.
    // Relative delay between consecutive rows = 2 cycles.
    // ------------------------------------------------------------------
    localparam int ROW_STAGGER_MAX = (ARRAY_SIZE > 1) ? (2*ARRAY_SIZE - 2) : 1;

    logic [DATA_WIDTH-1:0] stagger_sr  [ARRAY_SIZE][ROW_STAGGER_MAX];
    logic [DATA_WIDTH-1:0] act_stagger [ARRAY_SIZE];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                act_stagger[r] <= '0;
                for (int s = 0; s < ROW_STAGGER_MAX; s++)
                    stagger_sr[r][s] <= '0;
            end
        end else begin
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                if (r == 0) begin
                    // Gated on act_col_vld: dma_ctrl can hold with
                    // act_col_vld low while sp_rd_act_row stays parked on a
                    // live address, and the scratchpad's activation bank
                    // swap for the next tile would otherwise corrupt this
                    // tile's still-needed last activation before
                    // weight_commit consumes it. Later stages shift
                    // unconditionally; gating only the entry point
                    // preserves the held value without affecting the fixed
                    // 2r+1-cycle latency real data relies on.
                    if (act_col_vld) act_stagger[0] <= act_col_in[0];
                end else begin
                    if (act_col_vld) stagger_sr[r][0] <= act_col_in[r];
                    for (int s = 1; s < 2*r; s++)
                        stagger_sr[r][s] <= stagger_sr[r][s-1];
                    act_stagger[r] <= stagger_sr[r][2*r-1];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Commit-wave row stagger. Exact structural mirror of stagger_sr/
    // act_stagger above (2 cycles/row), but for a single broadcast bit
    // instead of per-row independent DATA_WIDTH-bit values -- commit_trigger
    // is timed (by dma_ctrl) to line up with when this tile's LAST
    // activation is issued, so commit_row_stagger[r] fires on the exact
    // same cycle act_stagger[r] receives that tile's last activation.
    // ------------------------------------------------------------------
    logic                  commit_sr [ARRAY_SIZE][ROW_STAGGER_MAX];
    logic [ARRAY_SIZE-1:0] commit_row_stagger;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            commit_row_stagger <= '0;
            for (int r = 0; r < ARRAY_SIZE; r++)
                for (int s = 0; s < ROW_STAGGER_MAX; s++)
                    commit_sr[r][s] <= 1'b0;
        end else begin
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                if (r == 0) begin
                    commit_row_stagger[0] <= commit_trigger;
                end else begin
                    commit_sr[r][0] <= commit_trigger;
                    for (int s = 1; s < 2*r; s++)
                        commit_sr[r][s] <= commit_sr[r][s-1];
                    commit_row_stagger[r] <= commit_sr[r][2*r-1];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Commit-select row stagger. Exact structural mirror of commit_sr/
    // commit_row_stagger above, propagating commit_sel (a level, not a
    // pulse) through the identical delay so it arrives at each row in
    // lockstep with that row's own commit_row_stagger bit.
    // ------------------------------------------------------------------
    logic [2:0] sel_sr [ARRAY_SIZE][ROW_STAGGER_MAX];
    logic [2:0] sel_row_stagger [ARRAY_SIZE];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                sel_row_stagger[r] <= '0;
                for (int s = 0; s < ROW_STAGGER_MAX; s++)
                    sel_sr[r][s] <= 3'b0;
            end
        end else begin
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                if (r == 0) begin
                    sel_row_stagger[0] <= commit_sel;
                end else begin
                    sel_sr[r][0] <= commit_sel;
                    for (int s = 1; s < 2*r; s++)
                        sel_sr[r][s] <= sel_sr[r][s-1];
                    sel_row_stagger[r] <= sel_sr[r][2*r-1];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // PE-to-PE interconnect — separate signals avoid multiple-driver issues
    // ------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] act_right    [ARRAY_SIZE][ARRAY_SIZE]; // act_out of PE[r][c]
    logic [DATA_WIDTH-1:0] shadow_down  [ARRAY_SIZE][ARRAY_SIZE]; // shadow_out of PE[r][c]
    logic [ACC_WIDTH-1:0]  psum_down [ARRAY_SIZE+1][ARRAY_SIZE]; // psum between rows

    // Top row psum boundary = 0
    genvar c, i, j;
    generate
        for (c = 0; c < ARRAY_SIZE; c++) begin : psum_top
            assign psum_down[0][c] = '0;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Per-column skip alignment.
    // skip_en_col[r] from sparsity_unit is staggered 2*r+1 cycles, which
    // aligns with when the activation reaches act_stagger[r] (column 0).
    // PE[r][c] sees the same activation c cycles later, so its skip must
    // also be delayed c cycles.
    //
    // skip_col0[r]      = skip_en_col[r]          (no extra delay, col 0)
    // skip_shift[k][r]  = skip_en_col[r] delayed k+1 cycles (cols 1..N-1)
    // ------------------------------------------------------------------
    logic [ARRAY_SIZE-1:0] skip_col0;                    // wire, col 0
    logic [ARRAY_SIZE-1:0] skip_shift [ARRAY_SIZE-1];    // regs, cols 1..N-1

    assign skip_col0 = skip_en_col;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int k = 0; k < ARRAY_SIZE-1; k++)
                skip_shift[k] <= '0;
        end else begin
            skip_shift[0] <= skip_en_col;                // col 1: 1 cycle delay
            for (int k = 1; k < ARRAY_SIZE-1; k++)
                skip_shift[k] <= skip_shift[k-1];        // col k+1: k+1 cycles delay
        end
    end

    // ------------------------------------------------------------------
    // Commit-wave column propagation. Exact structural mirror of
    // skip_col0/skip_shift above (1 cycle/column).
    // commit_col0[r]      = commit_row_stagger[r]        (no extra delay, col 0)
    // commit_shift[k][r]  = commit_row_stagger[r] delayed k+1 cycles (cols 1..N-1)
    // ------------------------------------------------------------------
    logic [ARRAY_SIZE-1:0] commit_col0;
    logic [ARRAY_SIZE-1:0] commit_shift [ARRAY_SIZE-1];

    assign commit_col0 = commit_row_stagger;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int k = 0; k < ARRAY_SIZE-1; k++)
                commit_shift[k] <= '0;
        end else begin
            commit_shift[0] <= commit_row_stagger;
            for (int k = 1; k < ARRAY_SIZE-1; k++)
                commit_shift[k] <= commit_shift[k-1];
        end
    end

    // ------------------------------------------------------------------
    // Commit-select column propagation. Exact structural mirror of
    // commit_col0/commit_shift above (1 cycle/column), keeping commit_sel
    // in lockstep with commit_mux at every (row, col) PE.
    // ------------------------------------------------------------------
    logic [2:0] sel_col0 [ARRAY_SIZE];
    logic [2:0] sel_shift [ARRAY_SIZE-1][ARRAY_SIZE];

    assign sel_col0 = sel_row_stagger;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int k = 0; k < ARRAY_SIZE-1; k++)
                for (int r = 0; r < ARRAY_SIZE; r++)
                    sel_shift[k][r] <= 3'b0;
        end else begin
            sel_shift[0] <= sel_row_stagger;
            for (int k = 1; k < ARRAY_SIZE-1; k++)
                sel_shift[k] <= sel_shift[k-1];
        end
    end

    // ------------------------------------------------------------------
    // PE grid
    // ------------------------------------------------------------------
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : row_gen
            for (j = 0; j < ARRAY_SIZE; j++) begin : col_gen
                logic [DATA_WIDTH-1:0] act_in_mux;
                logic [DATA_WIDTH-1:0] shadow_in_mux;
                logic                  skip_en_mux;
                logic                  commit_mux;
                logic [2:0]            commit_sel_mux;

                if (j == 0) begin : left_boundary
                    assign act_in_mux     = act_stagger[i];
                    assign skip_en_mux    = skip_col0[i];
                    assign commit_mux     = commit_col0[i];
                    assign commit_sel_mux = sel_col0[i];
                end else begin : inner_col
                    assign act_in_mux     = act_right[i][j-1];
                    assign skip_en_mux    = skip_shift[j-1][i];
                    assign commit_mux     = commit_shift[j-1][i];
                    assign commit_sel_mux = sel_shift[j-1][i];
                end

                if (i == 0) begin : top_boundary
                    // Shadow chain A's entry point.
                    assign shadow_in_mux = shadow_load_in_a[j];
                end else if (i == ARRAY_SIZE/2) begin : mid_boundary
                    // Shadow chain B's entry point -- row ARRAY_SIZE/2 does
                    // NOT read from row ARRAY_SIZE/2-1 (that belongs to
                    // chain A); it's an independent entry fed directly from
                    // the scratchpad's second weight-read port.
                    assign shadow_in_mux = shadow_load_in_b[j];
                end else begin : inner_row
                    assign shadow_in_mux = shadow_down[i-1][j];
                end

                pe #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) u_pe (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .act_in         (act_in_mux),
                    .psum_in        (psum_down[i][j]),
                    .shadow_in      (shadow_in_mux),
                    .shadow_load_en (shadow_load_en),
                    .shadow_load_sel(shadow_load_sel),
                    .weight_commit  (commit_mux),
                    .commit_sel     (commit_sel_mux),
                    .skip_en        (skip_en_mux),
                    .act_out        (act_right[i][j]),
                    .shadow_out     (shadow_down[i][j]),
                    .psum_out       (psum_down[i+1][j])
                );
            end
        end
    endgenerate

    // Bottom row → outputs
    generate
        for (c = 0; c < ARRAY_SIZE; c++) begin : psum_out_con
            assign psum_out_row[c] = psum_down[ARRAY_SIZE][c];
        end
    endgenerate

    // ------------------------------------------------------------------
    // psum_out_vld: delay act_col_vld to the first useful bottom-row output.
    // The PE has registered multiply and accumulate stages.
    // C[t][c] is valid at S_tick = t + c + 2*ARRAY_SIZE + 1 from streaming
    // start, so the first valid output appears 2*ARRAY_SIZE+1 ticks after
    // the first activation-valid tick.
    // psum_out_vld asserts for the window when bottom-row data is meaningful.
    // ------------------------------------------------------------------
    localparam int PIPE = 3*ARRAY_SIZE - 1;
    logic [PIPE-1:0] vld_sr;

    always_ff @(posedge clk) begin
        if (!rst_n)
            vld_sr <= '0;
        else
            vld_sr <= {vld_sr[PIPE-2:0], act_col_vld};
    end

    assign psum_out_vld = vld_sr[PIPE-1];

endmodule
