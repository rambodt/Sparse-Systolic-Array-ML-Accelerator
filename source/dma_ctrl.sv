//------------------------------------------------------------------------------
// dma_ctrl
//------------------------------------------------------------------------------
// Tile-level control for one ARRAY_SIZE x ARRAY_SIZE GEMM tile product. Two
// independent FSMs overlap load and compute:
//
//   compute FSM (state_r):     IDLE, RUN
//     Streams activations for the current tile. Draining and per-tile
//     completion tracking live in output_buffer, not here.
//
//   prefetch FSM (pf_state_r): IDLE, LOAD_WEIGHTS, LOAD_ACTS_SHADOW, READY
//     Accepts a new `start` whenever idle, loads the next tile's
//     weights/activations over the host bus, and shadow-preloads the array's
//     weight registers. LOAD_ACTS_SHADOW does both the act-row write (host
//     bus) and the weight shadow-preload (weight read port) concurrently --
//     disjoint resources, so no need to serialize them.
//
// The FSMs meet at `commit`: once the current tile's last activation row is
// presented (phase_cnt_r == ARRAY_SIZE) and the prefetch FSM is READY,
// commit_trigger pulses, phase_cnt_r restarts at 0, and array_top's per-PE
// staggered commit-wave swaps in the new weights as each PE finishes with
// the old ones.
//
// slot_sel/clear_accum are latched into the prefetch pipeline (slot_sel_pf_r)
// at accept time and only take effect at that tile's own commit --
// output_buffer's accumulate path must see the committed tile's slot, not
// whatever is currently prefetching. Host reads use their own path
// (accel_top wires rd_slot_sel from the host's live acc_slot) since a read
// can target a third, already-finished tile at the same time.
//------------------------------------------------------------------------------
module dma_ctrl #(
    parameter int ARRAY_SIZE    = 16,
    parameter int DATA_WIDTH    = 8,
    parameter int ACC_WIDTH     = 32,
    parameter int NUM_ACC_SLOTS = 4
)(
    input  logic clk,
    input  logic rst_n,

    // Host control
    input  logic  start,
    input  logic  reuse_weights,  // valid alongside start; skip weight reload for this tile
    input  logic  clear_accum,    // valid alongside start; zero this tile's accumulator slot
    input  logic [$clog2(NUM_ACC_SLOTS)-1:0] slot_sel, // valid alongside start
    // High only while the prefetch FSM is idle and will accept `start`.
    // A start pulse while a previous load/shadow-preload is still in
    // flight is dropped (no queue).
    output logic  ready_for_start,

    // Host write port. Host writes two ARRAY_SIZE-byte rows per cycle:
    // host_wr_addr is a row-pair index, host_wr_data's lower half is row
    // 2*host_wr_addr, upper half is row 2*host_wr_addr+1.
    input  logic                                         host_wr_en,
    input  logic [$clog2(ARRAY_SIZE/2)-1:0]              host_wr_addr,
    input  logic [2*ARRAY_SIZE*DATA_WIDTH-1:0]           host_wr_data,
    output logic                                         host_wr_rdy,

    // Scratchpad write port
    output logic                                         sp_wr_en,
    output logic                                         sp_wr_type,    // 0=weight  1=activation
    output logic [$clog2(ARRAY_SIZE/2)-1:0]              sp_wr_addr,
    output logic [2*ARRAY_SIZE*DATA_WIDTH-1:0]           sp_wr_data,

    // Scratchpad read control. Two weight-read addresses feed array_top's
    // two shadow shift-chain entry points, halving shadow-preload time.
    // Activation read is single/unwidened (see scratchpad.sv).
    output logic [$clog2(ARRAY_SIZE)-1:0]                sp_rd_weight_row_a,
    output logic [$clog2(ARRAY_SIZE)-1:0]                sp_rd_weight_row_b,
    output logic [$clog2(ARRAY_SIZE)-1:0]                sp_rd_act_row,
    output logic                                         sp_weight_bank_swap,
    output logic                                         sp_act_bank_swap,

    // Array control
    output logic                                         shadow_load_en,
    output logic [2:0]                                   shadow_load_sel,
    output logic                                         commit_trigger,
    output logic [2:0]                                   commit_sel,
    output logic                                         act_col_vld,

    // Output-buffer control. Separate from the host-driven read-slot
    // select, which accel_top wires directly.
    output logic                                         sp_buf_clear,
    output logic [$clog2(NUM_ACC_SLOTS)-1:0]              sp_clear_slot_sel,
    output logic [$clog2(NUM_ACC_SLOTS)-1:0]              sp_slot_sel
);

    localparam int ROW_W   = $clog2(ARRAY_SIZE);
    localparam int SLOT_W  = $clog2(NUM_ACC_SLOTS);
    localparam int PHASE_W = $clog2(ARRAY_SIZE) + 1;

    // ------------------------------------------------------------------
    // Compute FSM. Owns activation issuance only; draining/completion is
    // output_buffer's job.
    // ------------------------------------------------------------------
    typedef enum logic [0:0] {
        C_IDLE = 1'd0,
        C_RUN  = 1'd1
    } cstate_t;
    cstate_t state_r, state_next;

    // ------------------------------------------------------------------
    // Prefetch FSM
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {
        PF_IDLE             = 2'd0,
        PF_LOAD_WEIGHTS     = 2'd1,
        PF_LOAD_ACTS_SHADOW = 2'd2,
        PF_READY            = 2'd3
    } pstate_t;
    pstate_t pf_state_r, pf_state_next;

    logic [PHASE_W-1:0] phase_cnt_r;      // compute FSM: activation issuance progress
    logic [ROW_W-1:0]   pf_row_cnt_r;     // prefetch FSM: host write row progress
    logic [PHASE_W-1:0] pf_shadow_phase_r; // prefetch FSM: shadow-preload progress
    logic               pf_act_write_done_r;
    logic               pf_shadow_done_r;
    // Latches once the tile's last activation (row ARRAY_SIZE-1) has been
    // presented, so act_col_vld can't re-assert while phase_cnt_r holds at
    // ARRAY_SIZE waiting on prefetch.
    logic               act_presented_done_r;

    // Per-request metadata, latched on accept (PF_IDLE -> LOAD_*) and
    // consumed at commit.
    logic [SLOT_W-1:0] slot_sel_pf_r;
    logic              reuse_weights_pf_r;
    // Slot of the most recently committed tile -- what output_buffer's
    // accumulate path must see, independent of whatever is prefetching.
    logic [SLOT_W-1:0] committed_slot_sel_r;

    // 5-deep shadow buffer selector (pe.sv: shadow_a_r..shadow_e_r).
    // shadow_buf_sel_r advances once per tile accepted, so each tile's
    // shadow preload targets the buffer used four tile periods ago. N=5
    // (not 3) because the widened host-write/shadow-load ports shrink the
    // natural tile period below what N=3's own min_gap_met floor could
    // sustain.
    //
    // Read directly, with no extra latch, both as shadow_load_sel (this
    // tile's own shadow-load phase) and later as commit_sel (this same
    // tile's own commit) -- it cannot have advanced in between, since the
    // next tile is only accepted after ready_for_start goes high, one
    // cycle after this tile's commit.
    logic [2:0] shadow_buf_sel_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            shadow_buf_sel_r <= 3'd0;
        end else if (pf_state_r == PF_IDLE && start) begin
            shadow_buf_sel_r <= (shadow_buf_sel_r == 3'd4) ? 3'd0 : (shadow_buf_sel_r + 3'd1);
        end
    end

    // Minimum commit-to-commit spacing so N-buffering stays safe under any
    // prefetch schedule: with N=5, each of the N-1=4 tile periods needs
    // only ceil((3*ARRAY_SIZE-2)/4) cycles, well under the ~16-cycle
    // natural period. In the common (non-reuse) case this floor is already
    // satisfied before phase_cnt_r/PF_READY are, so it's a no-op.
    localparam int MIN_GAP = (3 * ARRAY_SIZE - 2 + 3) / 4;
    localparam int MG_W    = $clog2(MIN_GAP + 1);
    logic [MG_W-1:0] since_commit_cnt_r;
    logic            min_gap_met;

    assign min_gap_met = (since_commit_cnt_r == MG_W'(MIN_GAP));

    // Fires once the tile's last activation is presented, the prefetch FSM
    // is READY, and min_gap_met has elapsed. phase_cnt_r simply holds at
    // ARRAY_SIZE until both conditions are met.
    logic commit;
    assign commit = (pf_state_r == PF_READY) && min_gap_met &&
                    ((state_r == C_IDLE) ||
                     (state_r == C_RUN && phase_cnt_r == PHASE_W'(ARRAY_SIZE)));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            since_commit_cnt_r <= '0;
        end else if (commit) begin
            since_commit_cnt_r <= '0;
        end else if (since_commit_cnt_r != MG_W'(MIN_GAP)) begin
            since_commit_cnt_r <= since_commit_cnt_r + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // State registers
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) state_r <= C_IDLE;
        else        state_r <= state_next;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) pf_state_r <= PF_IDLE;
        else        pf_state_r <= pf_state_next;
    end

    // ------------------------------------------------------------------
    // Compute FSM next-state
    // ------------------------------------------------------------------
    always_comb begin
        state_next = state_r;
        case (state_r)
            C_IDLE: if (pf_state_r == PF_READY) state_next = C_RUN;
            C_RUN:  state_next = C_RUN;  // issuance is continuous once started
            default: state_next = C_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Prefetch FSM next-state
    // ------------------------------------------------------------------
    always_comb begin
        pf_state_next = pf_state_r;
        case (pf_state_r)
            PF_IDLE:
                if (start)
                    pf_state_next = reuse_weights ? PF_LOAD_ACTS_SHADOW : PF_LOAD_WEIGHTS;
            PF_LOAD_WEIGHTS:
                if (host_wr_en && pf_row_cnt_r == ROW_W'(ARRAY_SIZE/2 - 1))
                    pf_state_next = PF_LOAD_ACTS_SHADOW;
            PF_LOAD_ACTS_SHADOW:
                if (pf_act_write_done_r && pf_shadow_done_r)
                    pf_state_next = PF_READY;
            PF_READY:
                if (commit)
                    pf_state_next = PF_IDLE;
            default:
                pf_state_next = PF_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Compute FSM counter. 0..ARRAY_SIZE-1: request rows 0..ARRAY_SIZE-1
    // (one-cycle-ahead addressing). At ARRAY_SIZE the last row's data is
    // valid; holds there until commit, then restarts at 0.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            phase_cnt_r <= '0;
        end else begin
            case (state_r)
                C_IDLE: phase_cnt_r <= '0;
                C_RUN: begin
                    if (commit) phase_cnt_r <= '0;
                    else if (phase_cnt_r != PHASE_W'(ARRAY_SIZE))
                        phase_cnt_r <= phase_cnt_r + 1'b1;
                    // else: hold at ARRAY_SIZE, waiting for pf_state_r==PF_READY
                end
                default: phase_cnt_r <= '0;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            act_presented_done_r <= 1'b0;
        end else if (commit) begin
            act_presented_done_r <= 1'b0;
        end else if (state_r == C_RUN && phase_cnt_r == PHASE_W'(ARRAY_SIZE)) begin
            act_presented_done_r <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Prefetch FSM counters
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pf_row_cnt_r        <= '0;
            pf_shadow_phase_r   <= '0;
            pf_act_write_done_r <= 1'b0;
            pf_shadow_done_r    <= 1'b0;
        end else begin
            case (pf_state_r)
                PF_LOAD_WEIGHTS: begin
                    if (host_wr_en) begin
                        if (pf_row_cnt_r == ROW_W'(ARRAY_SIZE/2 - 1)) pf_row_cnt_r <= '0;
                        else                                          pf_row_cnt_r <= pf_row_cnt_r + 1'b1;
                    end
                    pf_shadow_phase_r   <= '0;
                    pf_act_write_done_r <= 1'b0;
                    pf_shadow_done_r    <= 1'b0;
                end
                PF_LOAD_ACTS_SHADOW: begin
                    if (host_wr_en && !pf_act_write_done_r) begin
                        if (pf_row_cnt_r == ROW_W'(ARRAY_SIZE/2 - 1)) begin
                            pf_row_cnt_r        <= '0;
                            pf_act_write_done_r <= 1'b1;
                        end else begin
                            pf_row_cnt_r <= pf_row_cnt_r + 1'b1;
                        end
                    end
                    // pf_shadow_phase_r saturates at ARRAY_SIZE/2 but this
                    // state can dwell past that waiting on the activation
                    // write. Latch done explicitly so shadow_load_en can't
                    // re-fire on the extra cycles.
                    if (!pf_shadow_done_r) begin
                        if (pf_shadow_phase_r == PHASE_W'(ARRAY_SIZE/2))
                            pf_shadow_done_r <= 1'b1;
                        else
                            pf_shadow_phase_r <= pf_shadow_phase_r + 1'b1;
                    end
                end
                default: begin
                    pf_row_cnt_r        <= '0;
                    pf_shadow_phase_r   <= '0;
                    pf_act_write_done_r <= 1'b0;
                    pf_shadow_done_r    <= 1'b0;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Per-request metadata latch + commit hand-off
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            slot_sel_pf_r      <= '0;
            reuse_weights_pf_r <= 1'b0;
        end else if (pf_state_r == PF_IDLE && start) begin
            slot_sel_pf_r      <= slot_sel;
            reuse_weights_pf_r <= reuse_weights;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) committed_slot_sel_r <= '0;
        else if (commit) committed_slot_sel_r <= slot_sel_pf_r;
    end

    // ------------------------------------------------------------------
    // Output logic — host write passthrough (prefetch FSM only)
    // ------------------------------------------------------------------
    assign host_wr_rdy = (pf_state_r == PF_LOAD_WEIGHTS) ||
                          (pf_state_r == PF_LOAD_ACTS_SHADOW && !pf_act_write_done_r);
    assign sp_wr_en    = host_wr_rdy && host_wr_en;
    assign sp_wr_type  = (pf_state_r == PF_LOAD_ACTS_SHADOW) ? 1'b1 : 1'b0;
    assign sp_wr_addr  = host_wr_addr;
    assign sp_wr_data  = host_wr_data;

    // Bank swaps -- independent per memory type, each firing once at the
    // end of its own write phase.
    assign sp_weight_bank_swap = (pf_state_r == PF_LOAD_WEIGHTS) &&
                                 host_wr_en && (pf_row_cnt_r == ROW_W'(ARRAY_SIZE/2 - 1));
    assign sp_act_bank_swap    = (pf_state_r == PF_LOAD_ACTS_SHADOW) &&
                                 host_wr_en && !pf_act_write_done_r &&
                                 (pf_row_cnt_r == ROW_W'(ARRAY_SIZE/2 - 1));

    // buf_clear fires on accept using that request's own slot_sel/clear_accum
    // -- only needs to land sometime before that tile's accumulation starts.
    // sp_clear_slot_sel and sp_slot_sel are separate ports rather than one
    // muxed port: a new tile's buf_clear and an already-computing tile's
    // act_col_vld rising edge can land on the same cycle once load and
    // compute overlap, each needing a different tile's slot value.
    assign sp_buf_clear      = (pf_state_r == PF_IDLE) && start && clear_accum;
    assign sp_clear_slot_sel = slot_sel;
    assign sp_slot_sel       = committed_slot_sel_r;

    // ------------------------------------------------------------------
    // Shadow weight preload read addresses. Same one-cycle-ahead,
    // reversed-order addressing as a single chain, applied independently
    // per half: chain A (rows 0..ARRAY_SIZE/2-1) requests row
    // (ARRAY_SIZE/2-1-phase); chain B (rows ARRAY_SIZE/2..ARRAY_SIZE-1)
    // requests row (ARRAY_SIZE-1-phase). Both complete at the same phase
    // (ARRAY_SIZE/2), so every row in both chains becomes correct
    // simultaneously, in half the cycles (see array_top.sv).
    // ------------------------------------------------------------------
    always_comb begin
        if (pf_state_r == PF_LOAD_ACTS_SHADOW && !pf_shadow_done_r && pf_shadow_phase_r < PHASE_W'(ARRAY_SIZE/2)) begin
            sp_rd_weight_row_a = ROW_W'(ARRAY_SIZE/2 - 1) - ROW_W'(pf_shadow_phase_r[ROW_W-1:0]);
            sp_rd_weight_row_b = ROW_W'(ARRAY_SIZE - 1)   - ROW_W'(pf_shadow_phase_r[ROW_W-1:0]);
        end else begin
            sp_rd_weight_row_a = '0;
            sp_rd_weight_row_b = '0;
        end
    end

    // Gated on !pf_shadow_done_r, not just the phase level -- this state
    // can dwell past ARRAY_SIZE/2 waiting on the activation write, and a
    // level check alone would re-fire shadow_load_en on those extra cycles.
    assign shadow_load_en = (pf_state_r == PF_LOAD_ACTS_SHADOW) &&
                             (pf_shadow_phase_r >= 1) &&
                             !pf_shadow_done_r;

    // Buffer this tile's shadow preload writes into.
    assign shadow_load_sel = shadow_buf_sel_r;

    // commit_trigger feeds array_top's per-PE commit-wave network as a
    // clean one-cycle pulse. commit_sel rides the same delay network so it
    // arrives at each PE synchronized with its own weight_commit.
    assign commit_trigger = commit;
    assign commit_sel     = shadow_buf_sel_r;

    // ------------------------------------------------------------------
    // Activation streaming read address, on the compute FSM's phase_cnt_r.
    // ------------------------------------------------------------------
    always_comb begin
        if (state_r == C_RUN && phase_cnt_r < PHASE_W'(ARRAY_SIZE))
            sp_rd_act_row = ROW_W'(phase_cnt_r[ROW_W-1:0]);
        else
            sp_rd_act_row = '0;
    end

    // Gated on !act_presented_done_r for the same reason as shadow_load_en:
    // phase_cnt_r can hold at ARRAY_SIZE waiting on prefetch, and
    // act_col_vld must not stay asserted through those extra cycles.
    assign act_col_vld = (state_r == C_RUN) && (phase_cnt_r >= 1) && !act_presented_done_r;

    assign ready_for_start = (pf_state_r == PF_IDLE);

endmodule
