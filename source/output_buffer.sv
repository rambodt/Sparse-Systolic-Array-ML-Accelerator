//------------------------------------------------------------------------------
// output_buffer
//------------------------------------------------------------------------------
// Captures the diagonally staggered bottom-row outputs from array_top and stores
// a dense 16x16 C tile. When clear_accum is not asserted between tile products,
// the buffer adds new partial sums into the existing entries so K-tiling can be
// accumulated on chip.
//
// Storage: NUM_ACC_SLOTS independent 16x16 accumulator slots (default 4),
// each a plain flip-flop array (buf_r[slot][row][col]).
//
// Multiple slots let the host keep several output tiles' partial sums open at
// once, so a weight tile can be reused across several activation tiles before
// being evicted (see dma_ctrl's reuse_weights path).
//
// Parallel capture-window tracking: with per-PE staggered weight commit, a
// new capture window can open before earlier ones close -- each window lasts
// S_MAX=63 ticks, opened at minimum MIN_TILE_GAP cycles apart, so up to
// ceil(S_MAX/MIN_TILE_GAP) windows can be in flight simultaneously.
// NUM_TRACKERS independent parallel trackers, FIFO-allocated (windows close
// in the order they open, since every tile has the same fixed latency), track
// each open window. `done` is the OR of every tracker closing that cycle --
// two windows can never close on the same cycle, so this is a clean
// one-cycle pulse per completed tile in FIFO order.
//
// Capture timing (derived from array_top pipeline analysis):
//   At streaming tick S (1-indexed from first act_col_vld rising edge),
//   psum_out_row[c] = C[t][c]  where  S = t + c + 2*ARRAY_SIZE + 1
//   -> t = S - c - 2*ARRAY_SIZE - 1
//   Valid when t in [0, ARRAY_SIZE-1],
//   i.e., S in [c + 2*ARRAY_SIZE + 1,  c + 3*ARRAY_SIZE]
//
//   All ARRAY_SIZE*ARRAY_SIZE elements arrive within S = 1..4*ARRAY_SIZE-1.
//   Outputs for different columns are staggered (diagonal pattern).
//------------------------------------------------------------------------------

module output_buffer #(
    parameter int ARRAY_SIZE    = 16,
    parameter int ACC_WIDTH     = 32,
    parameter int NUM_ACC_SLOTS = 4
)(
    input  logic                             clk,
    input  logic                             rst_n,

    // Pulse from host (via accel_top start) -- zeros the selected slot before
    // a new GEMM. clear_slot_sel is this pulse's own target slot only.
    input  logic                             buf_clear,
    input  logic [$clog2(NUM_ACC_SLOTS)-1:0] clear_slot_sel,

    // Slot the accumulate path latches into active_slot_r when act_col_vld
    // rises -- the currently-committed tile's slot (dma_ctrl's
    // committed_slot_sel_r), held for that tile's whole capture window.
    // Kept separate from clear_slot_sel: a new tile's buf_clear pulse and
    // an already-computing tile's act_col_vld rising edge can land on the
    // same cycle once load and compute overlap, each needing its own
    // tile's slot value.
    input  logic [$clog2(NUM_ACC_SLOTS)-1:0] slot_sel,

    // Host read-port slot select -- independent of the above so a read of
    // an already-completed tile can't race a concurrently
    // prefetching/committing tile using a different slot.
    input  logic [$clog2(NUM_ACC_SLOTS)-1:0] rd_slot_sel,

    // act_col_vld from DMA: rising edge allocates a free tracker, which
    // starts its own streaming tick counter and latches slot_sel into its
    // own active_slot_r for the duration of that tile's capture.
    input  logic                             act_col_vld,

    // Partial sums from array_top bottom row
    input  logic [ACC_WIDTH-1:0]             psum_in [ARRAY_SIZE],

    // One-cycle pulse when a tile's capture window closes (its tracker's
    // S_r reaches S_MAX), in the same order tiles were issued.
    output logic                             done,

    // Read port -- host can read one complete row after done, from whichever
    // slot slot_sel currently selects. rd_data kept for compatibility with
    // older tests. Registered (multi-cycle latency, see read pipeline below):
    // a combinational read straight off buf_r[slot][row][col] indexes a
    // 4x16x16 array in one shot, which failed timing closure.
    input  logic [$clog2(ARRAY_SIZE)-1:0]    rd_row,
    input  logic [$clog2(ARRAY_SIZE)-1:0]    rd_col,
    output logic [ARRAY_SIZE*ACC_WIDTH-1:0]  rd_row_data,
    output logic [ACC_WIDTH-1:0]             rd_data,

    // All-slots read port: the same rd_row, all NUM_ACC_SLOTS slots' worth
    // of that row, in one read -- lets a host read a whole block's output
    // tiles by iterating rd_row once instead of once per slot.
    output logic [NUM_ACC_SLOTS*ARRAY_SIZE*ACC_WIDTH-1:0] rd_row_data_all
);

    localparam int S_MAX     = 4 * ARRAY_SIZE - 1;  // last tick with valid output
    localparam int S_BASE    = 2 * ARRAY_SIZE + 1;  // first tick col-0 output is valid
    localparam int S_W       = $clog2(S_MAX + 1) + 1;
    localparam int SLOT_W    = (NUM_ACC_SLOTS > 1) ? $clog2(NUM_ACC_SLOTS) : 1;
    // One tracker per possible simultaneously-open capture window.
    // MIN_TILE_GAP must be kept in sync with dma_ctrl.sv's MIN_GAP -- no
    // live parameter connection between the two modules.
    localparam int MIN_TILE_GAP = (3 * ARRAY_SIZE - 2 + 3) / 4;
    localparam int NUM_TRACKERS = (S_MAX + MIN_TILE_GAP - 1) / MIN_TILE_GAP;
    localparam int TRK_W        = (NUM_TRACKERS > 1) ? $clog2(NUM_TRACKERS) : 1;

    // ------------------------------------------------------------------
    // Accumulator array: buf_r[slot][row][col]
    // ------------------------------------------------------------------
    logic [ACC_WIDTH-1:0] buf_r [NUM_ACC_SLOTS][ARRAY_SIZE][ARRAY_SIZE];

    // ------------------------------------------------------------------
    // Parallel capture-window trackers.
    // ------------------------------------------------------------------
    logic [S_W-1:0]    S_r           [NUM_TRACKERS];
    logic               running_r     [NUM_TRACKERS];
    logic [SLOT_W-1:0] active_slot_r [NUM_TRACKERS];
    logic               act_vld_prev_r;

    // One-hot per-slot "this tracker is currently writing slot s" flags,
    // registered alongside active_slot_r instead of recomputed via
    // (active_slot_r[w]==s) at each of the NUM_ACC_SLOTS x ARRAY_SIZE x
    // ARRAY_SIZE write sites below.
    logic slot_active_r [NUM_TRACKERS][NUM_ACC_SLOTS];

    // Allocate the lowest-indexed free tracker to a newly-rising act_col_vld.
    // One allocation per cycle max (act_col_vld is a single signal), so a
    // priority encoder is sufficient -- all trackers are functionally
    // identical, no ordering guarantee needed beyond "some free tracker".
    logic [TRK_W-1:0] alloc_idx;
    logic             alloc_vld;

    always_comb begin
        alloc_vld = 1'b0;
        alloc_idx = '0;
        for (int w = 0; w < NUM_TRACKERS; w++) begin
            if (!running_r[w] && !alloc_vld) begin
                alloc_vld = 1'b1;
                alloc_idx = TRK_W'(w);
            end
        end
    end

    logic acc_vld_rise;
    assign acc_vld_rise = act_col_vld && !act_vld_prev_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            act_vld_prev_r <= 1'b0;
            for (int w = 0; w < NUM_TRACKERS; w++) begin
                S_r[w]           <= '0;
                running_r[w]     <= 1'b0;
                active_slot_r[w] <= '0;
                for (int s = 0; s < NUM_ACC_SLOTS; s++)
                    slot_active_r[w][s] <= 1'b0;
            end
        end else begin
            act_vld_prev_r <= act_col_vld;

            for (int w = 0; w < NUM_TRACKERS; w++) begin
                if (acc_vld_rise && alloc_vld && (TRK_W'(w) == alloc_idx)) begin
                    // Allocated this cycle: begin capture for this tile,
                    // latch which slot its partial sums belong to.
                    running_r[w]     <= 1'b1;
                    S_r[w]           <= S_W'(1);
                    active_slot_r[w] <= slot_sel;
                    for (int s = 0; s < NUM_ACC_SLOTS; s++)
                        slot_active_r[w][s] <= (SLOT_W'(s) == slot_sel);
                end else if (running_r[w]) begin
                    if (S_r[w] == S_W'(S_MAX)) begin
                        running_r[w] <= 1'b0;
                        S_r[w]       <= '0;
                        for (int s = 0; s < NUM_ACC_SLOTS; s++)
                            slot_active_r[w][s] <= 1'b0;
                    end else begin
                        S_r[w] <= S_r[w] + 1'b1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Per-column one-hot capture shift registers, mirroring array_top.sv's
    // skip_shift/commit_shift (1 cycle/column propagation). cap_col0_r[w]
    // loads bit 0 when this tracker's window reaches column 0's first
    // valid tick (S_r==S_BASE), then shifts one position per cycle.
    // cap_shift_r delays that pattern one extra cycle per column, so
    // cap_active(w,c)[t] is the row-t write-enable for column c.
    // ------------------------------------------------------------------
    logic [ARRAY_SIZE-1:0] cap_col0_r  [NUM_TRACKERS];
    logic [ARRAY_SIZE-1:0] cap_shift_r [NUM_TRACKERS][ARRAY_SIZE-1];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int w = 0; w < NUM_TRACKERS; w++) begin
                cap_col0_r[w] <= '0;
                for (int k = 0; k < ARRAY_SIZE - 1; k++)
                    cap_shift_r[w][k] <= '0;
            end
        end else begin
            for (int w = 0; w < NUM_TRACKERS; w++) begin
                // Trigger one cycle early: this register reflects the load
                // on the next cycle, so S_r[w]==S_BASE-1 makes bit 0
                // visible exactly when S_r[w]==S_BASE.
                if (running_r[w] && (S_r[w] == S_W'(S_BASE - 1)))
                    cap_col0_r[w] <= {{(ARRAY_SIZE-1){1'b0}}, 1'b1};  // load t=0
                else
                    cap_col0_r[w] <= cap_col0_r[w] << 1;              // advance t (or stay empty)

                cap_shift_r[w][0] <= cap_col0_r[w];
                for (int k = 1; k < ARRAY_SIZE - 1; k++)
                    cap_shift_r[w][k] <= cap_shift_r[w][k-1];
            end
        end
    end

    // done: OR across trackers closing this cycle. Windows share the same
    // S_MAX duration and trackers can only be allocated on different
    // cycles, so two trackers never close on the same cycle -- this stays
    // a clean one-cycle pulse.
    logic done_next;
    always_comb begin
        done_next = 1'b0;
        for (int w = 0; w < NUM_TRACKERS; w++)
            if (running_r[w] && (S_r[w] == S_W'(S_MAX))) done_next = 1'b1;
    end

    logic done_r;
    always_ff @(posedge clk) begin
        if (!rst_n) done_r <= 1'b0;
        else        done_r <= done_next;
    end

    // done_r2/r3/r4: three extra cycles matching the three write-side
    // retiming stages below, so `done` keeps trailing the true last write
    // by exactly one cycle regardless of write-path depth.
    logic done_r2;
    always_ff @(posedge clk) begin
        if (!rst_n) done_r2 <= 1'b0;
        else        done_r2 <= done_r;
    end

    logic done_r3;
    always_ff @(posedge clk) begin
        if (!rst_n) done_r3 <= 1'b0;
        else        done_r3 <= done_r2;
    end

    logic done_r4;
    always_ff @(posedge clk) begin
        if (!rst_n) done_r4 <= 1'b0;
        else        done_r4 <= done_r3;
    end
    assign done = done_r4;

    // ------------------------------------------------------------------
    // Write-side pipeline register: breaks the PE-flop -> buffer-fanout ->
    // accumulate-adder combinational path into two cycles (was the
    // dominant timing bottleneck, see OPTIMIZATION_LOG.md). Every signal
    // the accumulate write depends on (psum_in, slot_active_r, cap_col0_r,
    // cap_shift_r) gets an identical one-cycle-delayed shadow copy here,
    // used only in the write block below -- pure retiming, capture-window
    // timing above is untouched.
    // ------------------------------------------------------------------
    logic [ACC_WIDTH-1:0]  psum_in_acc_r       [ARRAY_SIZE];
    logic                  slot_active_acc_r   [NUM_TRACKERS][NUM_ACC_SLOTS];
    logic [ARRAY_SIZE-1:0] cap_col0_acc_r      [NUM_TRACKERS];
    logic [ARRAY_SIZE-1:0] cap_shift_acc_r     [NUM_TRACKERS][ARRAY_SIZE-1];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int c = 0; c < ARRAY_SIZE; c++)
                psum_in_acc_r[c] <= '0;
            for (int w = 0; w < NUM_TRACKERS; w++) begin
                cap_col0_acc_r[w] <= '0;
                for (int k = 0; k < ARRAY_SIZE - 1; k++)
                    cap_shift_acc_r[w][k] <= '0;
                for (int s = 0; s < NUM_ACC_SLOTS; s++)
                    slot_active_acc_r[w][s] <= 1'b0;
            end
        end else begin
            for (int c = 0; c < ARRAY_SIZE; c++)
                psum_in_acc_r[c] <= psum_in[c];
            for (int w = 0; w < NUM_TRACKERS; w++) begin
                cap_col0_acc_r[w] <= cap_col0_r[w];
                for (int k = 0; k < ARRAY_SIZE - 1; k++)
                    cap_shift_acc_r[w][k] <= cap_shift_r[w][k];
                for (int s = 0; s < NUM_ACC_SLOTS; s++)
                    slot_active_acc_r[w][s] <= slot_active_r[w][s];
            end
        end
    end

    // ------------------------------------------------------------------
    // Second write-side pipeline register: pre-computes and registers the
    // per-(slot,row,col) write enable one cycle before the accumulate, so
    // the final write cycle only does a flat enable check + add instead of
    // an OR-across-NUM_TRACKERS reduction plus the 32-bit add in the same
    // cycle. Mechanical transform of the accumulate loop below (same
    // nested loops/conditions, just setting a registered flag instead of
    // doing the add) -- write timing is preserved bit-for-bit, one cycle
    // later.
    // ------------------------------------------------------------------
    logic [ACC_WIDTH-1:0] psum_in_acc_r2 [ARRAY_SIZE];
    logic                 wr_en_r2       [NUM_ACC_SLOTS][ARRAY_SIZE][ARRAY_SIZE];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int c = 0; c < ARRAY_SIZE; c++)
                psum_in_acc_r2[c] <= '0;
            for (int s = 0; s < NUM_ACC_SLOTS; s++)
                for (int t = 0; t < ARRAY_SIZE; t++)
                    for (int c = 0; c < ARRAY_SIZE; c++)
                        wr_en_r2[s][t][c] <= 1'b0;
        end else begin
            for (int c = 0; c < ARRAY_SIZE; c++)
                psum_in_acc_r2[c] <= psum_in_acc_r[c];
            for (int s = 0; s < NUM_ACC_SLOTS; s++) begin
                for (int t = 0; t < ARRAY_SIZE; t++)
                    for (int c = 0; c < ARRAY_SIZE; c++)
                        wr_en_r2[s][t][c] <= 1'b0;
                for (int w = 0; w < NUM_TRACKERS; w++) begin
                    if (slot_active_acc_r[w][s]) begin
                        for (int t = 0; t < ARRAY_SIZE; t++)
                            if (cap_col0_acc_r[w][t])
                                wr_en_r2[s][t][0] <= 1'b1;
                        for (int c = 1; c < ARRAY_SIZE; c++)
                            for (int t = 0; t < ARRAY_SIZE; t++)
                                if (cap_shift_acc_r[w][c-1][t])
                                    wr_en_r2[s][t][c] <= 1'b1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Third write-side pipeline register: one more cycle of pure retiming
    // on wr_en_r2/psum_in_acc_r2, no new decode logic -- flop-to-flop copy
    // to give the accumulate adder a full clock period on its own hop.
    // ------------------------------------------------------------------
    logic [ACC_WIDTH-1:0] psum_in_acc_r3 [ARRAY_SIZE];
    logic                 wr_en_r3       [NUM_ACC_SLOTS][ARRAY_SIZE][ARRAY_SIZE];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int c = 0; c < ARRAY_SIZE; c++)
                psum_in_acc_r3[c] <= '0;
            for (int s = 0; s < NUM_ACC_SLOTS; s++)
                for (int t = 0; t < ARRAY_SIZE; t++)
                    for (int c = 0; c < ARRAY_SIZE; c++)
                        wr_en_r3[s][t][c] <= 1'b0;
        end else begin
            for (int c = 0; c < ARRAY_SIZE; c++)
                psum_in_acc_r3[c] <= psum_in_acc_r2[c];
            for (int s = 0; s < NUM_ACC_SLOTS; s++)
                for (int t = 0; t < ARRAY_SIZE; t++)
                    for (int c = 0; c < ARRAY_SIZE; c++)
                        wr_en_r3[s][t][c] <= wr_en_r2[s][t][c];
        end
    end

    // ------------------------------------------------------------------
    // Accumulation: buf_r[active_slot][t][c] += psum_in[c] wherever
    // wr_en_r3 says a tracker's window covered that position. For
    // multi-tile K the += accumulates across tiles as long as clear_accum
    // is not re-asserted between them.
    //
    // Looped per-slot (clear-or-accumulate decided independently per
    // slot), not as one priority mux over the whole buf_r array: a new
    // tile's buf_clear pulse (its own slot) can land the same cycle as a
    // different tracker's accumulate write to a different slot under
    // overlapped issuance -- a shared priority mux drops that other
    // slot's write on collision.
    //
    // buf_clear/clear_slot_sel are not delayed: clearing only needs to
    // happen before that slot's new tile starts writing (S_BASE+ cycles
    // later).
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int s = 0; s < NUM_ACC_SLOTS; s++)
                for (int r = 0; r < ARRAY_SIZE; r++)
                    for (int c = 0; c < ARRAY_SIZE; c++)
                        buf_r[s][r][c] <= '0;
        end else begin
            for (int s = 0; s < NUM_ACC_SLOTS; s++) begin
                if (buf_clear && (clear_slot_sel == SLOT_W'(s))) begin
                    for (int r = 0; r < ARRAY_SIZE; r++)
                        for (int c = 0; c < ARRAY_SIZE; c++)
                            buf_r[s][r][c] <= '0;
                end else begin
                    for (int t = 0; t < ARRAY_SIZE; t++)
                        for (int c = 0; c < ARRAY_SIZE; c++)
                            if (wr_en_r3[s][t][c])
                                buf_r[s][t][c] <= buf_r[s][t][c] + psum_in_acc_r3[c];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Read port -- multi-stage pipeline (address register, then data
    // registers) -- host reads after done asserts. Existing testbenches
    // already wait several cycles before sampling.
    // ------------------------------------------------------------------
    localparam int ROW_W = $clog2(ARRAY_SIZE);
    localparam int COL_W = $clog2(ARRAY_SIZE);

    // Read pipeline: 4 stages. buf_r[slot][row][col] indexed by slot (4-way)
    // and row (16-way) in one combinational hop was the critical path post-
    // route. Row-select is split across two stages (row-group, then
    // row-within-group) to keep each mux stage cheap. Extra read latency:
    // existing testbenches already wait 5-8 cycles before sampling reads.
    localparam int ROW_LO_W       = ROW_W / 2;
    localparam int ROW_HI_W       = ROW_W - ROW_LO_W;
    localparam int NUM_ROW_GROUPS = 1 << ROW_HI_W;

    logic [ROW_W-1:0]  rd_row_r1;
    logic [COL_W-1:0]  rd_col_r1, rd_col_r2, rd_col_r3;
    logic [SLOT_W-1:0] rd_slot_r1, rd_slot_r2, rd_slot_r3;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_row_r1  <= '0;
            rd_col_r1  <= '0;
            rd_slot_r1 <= '0;
        end else begin
            rd_row_r1  <= rd_row;
            rd_col_r1  <= rd_col;
            rd_slot_r1 <= rd_slot_sel;
        end
    end

    // Stage 2a: row-select within each of NUM_ROW_GROUPS row-groups, using
    // only rd_row_r1's low bits -- computed for every group in parallel,
    // so the group choice (rd_row_r1's high bits) is only needed next stage.
    logic [ROW_HI_W-1:0]  rd_row_hi_r2;
    logic [ACC_WIDTH-1:0] quad_sel_r [NUM_ROW_GROUPS][NUM_ACC_SLOTS][ARRAY_SIZE];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_col_r2    <= '0;
            rd_slot_r2   <= '0;
            rd_row_hi_r2 <= '0;
            for (int g = 0; g < NUM_ROW_GROUPS; g++)
                for (int s = 0; s < NUM_ACC_SLOTS; s++)
                    for (int c = 0; c < ARRAY_SIZE; c++)
                        quad_sel_r[g][s][c] <= '0;
        end else begin
            rd_col_r2    <= rd_col_r1;
            rd_slot_r2   <= rd_slot_r1;
            rd_row_hi_r2 <= rd_row_r1[ROW_W-1 -: ROW_HI_W];
            for (int g = 0; g < NUM_ROW_GROUPS; g++)
                for (int s = 0; s < NUM_ACC_SLOTS; s++)
                    for (int c = 0; c < ARRAY_SIZE; c++)
                        quad_sel_r[g][s][c] <= buf_r[s][{g[ROW_HI_W-1:0], rd_row_r1[ROW_LO_W-1:0]}][c];
        end
    end

    // Stage 2b: pick the row-group (cheap NUM_ROW_GROUPS-way mux), narrows
    // down to [slot][col].
    logic [ACC_WIDTH-1:0] row_sel_r [NUM_ACC_SLOTS][ARRAY_SIZE];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_col_r3  <= '0;
            rd_slot_r3 <= '0;
            for (int s = 0; s < NUM_ACC_SLOTS; s++)
                for (int c = 0; c < ARRAY_SIZE; c++)
                    row_sel_r[s][c] <= '0;
        end else begin
            rd_col_r3  <= rd_col_r2;
            rd_slot_r3 <= rd_slot_r2;
            for (int s = 0; s < NUM_ACC_SLOTS; s++)
                for (int c = 0; c < ARRAY_SIZE; c++)
                    row_sel_r[s][c] <= quad_sel_r[rd_row_hi_r2][s][c];
        end
    end

    // Stage 3: rd_row_data's slot-select (4-way mux) and rd_data's
    // col-select sub-stage. Splitting slot- and col-select into two stages
    // keeps each mux cheap; rd_row_data only does a 4-way mux and is
    // unaffected (a disjoint set of testbenches reads rd_row_data vs
    // rd_data, so they don't need to stay in lockstep).
    logic [ACC_WIDTH-1:0] col_sel_r [NUM_ACC_SLOTS];
    logic [SLOT_W-1:0]    rd_slot_r4;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_row_data      <= '0;
            rd_row_data_all  <= '0;
            rd_slot_r4       <= '0;
            for (int s = 0; s < NUM_ACC_SLOTS; s++)
                col_sel_r[s] <= '0;
        end else begin
            for (int c = 0; c < ARRAY_SIZE; c++)
                rd_row_data[c*ACC_WIDTH +: ACC_WIDTH] <= row_sel_r[rd_slot_r3][c];
            for (int s = 0; s < NUM_ACC_SLOTS; s++)
                for (int c = 0; c < ARRAY_SIZE; c++)
                    rd_row_data_all[(s*ARRAY_SIZE+c)*ACC_WIDTH +: ACC_WIDTH] <= row_sel_r[s][c];
            rd_slot_r4 <= rd_slot_r3;
            for (int s = 0; s < NUM_ACC_SLOTS; s++)
                col_sel_r[s] <= row_sel_r[s][rd_col_r3];
        end
    end

    // Stage 4: rd_data's final slot-select (cheap 4-way mux).
    always_ff @(posedge clk) begin
        if (!rst_n) rd_data <= '0;
        else        rd_data <= col_sel_r[rd_slot_r4];
    end

endmodule
