//------------------------------------------------------------------------------
// accel_top
//------------------------------------------------------------------------------
// Top-level accelerator integration wrapper.
//
// This module connects the host/testbench interface, DMA-style tile controller,
// ping-pong scratchpad, activation sparsity detector, 16x16 systolic array, and
// output accumulation buffer. The host writes TWO 16-element rows per cycle
// (packed into host_wr_data, addressed as a row pair by host_wr_addr) for the
// B tile followed by the A tile. The controller then preloads weights,
// streams activations, drains the array pipeline, and exposes the completed
// output tile through the registered readback port.
//
// Design note:
//   Top-level host inputs are registered before entering the internal fabric.
//   This intentionally spends one cycle at the boundary to improve post-route
//   timing closure for the ASIC implementation.
//------------------------------------------------------------------------------
module accel_top #(
    parameter int ARRAY_SIZE       = 16,
    parameter int DATA_WIDTH       = 8,
    parameter int ACC_WIDTH        = 32,
    parameter int SCRATCHPAD_DEPTH = 4096,
    parameter int NUM_BANKS        = 2,
    parameter int NUM_ACC_SLOTS    = 4
)(
    input  logic clk,
    input  logic rst_n,

    // Host control
    input  logic  start,
    input  logic  clear_accum,
    input  logic  reuse_weights,  // valid alongside start; skip weight reload for this tile
    output logic  done,
    // True when a new tile's start will actually be accepted. A host
    // issuing back-to-back tiles without waiting for done (to exploit
    // preload-while-computing) must wait for this before asserting start,
    // or the pulse can arrive while the previous tile's load/shadow-preload
    // is still in flight and get silently dropped.
    output logic  ready_for_start,

    // Selects which of NUM_ACC_SLOTS independent output-buffer accumulators
    // this operation targets -- lets a weight tile be reused across several
    // activation tiles (different output row-tiles) before being evicted,
    // instead of forcing one output tile to fully finish before the next
    // starts. Must be held stable across a tile's start->write->done sequence;
    // for host reads, hold it stable while presenting rd_row/rd_col.
    input  logic [$clog2(NUM_ACC_SLOTS)-1:0] acc_slot,

    // Host tile-write port — TWO complete 16-byte rows per cycle. host_wr_addr
    // is a row-PAIR index (rows 2*host_wr_addr and 2*host_wr_addr+1);
    // host_wr_data's lower half is the first row, upper half the second.
    input  logic                                         host_wr_en,
    input  logic [$clog2(ARRAY_SIZE/2)-1:0]              host_wr_addr,
    input  logic [2*ARRAY_SIZE*DATA_WIDTH-1:0]           host_wr_data,
    output logic                                         host_wr_rdy,

    // Output buffer read port — valid after done asserts
    input  logic [$clog2(ARRAY_SIZE)-1:0]                rd_row,
    input  logic [$clog2(ARRAY_SIZE)-1:0]                rd_col,
    output logic [ARRAY_SIZE*ACC_WIDTH-1:0]              rd_row_data,
    output logic [ACC_WIDTH-1:0]                         rd_data,
    // All-slots readback: same rd_row, every NUM_ACC_SLOTS slot's data at
    // once -- see output_buffer.sv header for why this is free (already
    // computed pre-mux on the way to rd_row_data).
    output logic [NUM_ACC_SLOTS*ARRAY_SIZE*ACC_WIDTH-1:0] rd_row_data_all,

    // Sparsity counters — readable after done asserts
    output logic [31:0]                                  total_mac_cycles,
    output logic [31:0]                                  skipped_mac_cycles
);

    // ------------------------------------------------------------------
    // Internal wires
    // ------------------------------------------------------------------

    // Register top-level control/data inputs before they drive the internal
    // control fabric. This gives ASIC timing a full internal cycle instead of
    // closing host input delay plus DMA/scratchpad logic in one cycle.
    logic                                         start_r;
    logic                                         clear_accum_r;
    logic                                         reuse_weights_r;
    logic                                         host_wr_en_r;
    logic [$clog2(ARRAY_SIZE/2)-1:0]               host_wr_addr_r;
    logic [2*ARRAY_SIZE*DATA_WIDTH-1:0]            host_wr_data_r;
    logic [$clog2(NUM_ACC_SLOTS)-1:0]             acc_slot_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            start_r         <= 1'b0;
            clear_accum_r   <= 1'b0;
            reuse_weights_r <= 1'b0;
            host_wr_en_r    <= 1'b0;
            host_wr_addr_r  <= '0;
            host_wr_data_r  <= '0;
            acc_slot_r      <= '0;
        end else begin
            start_r         <= start;
            clear_accum_r   <= clear_accum;
            reuse_weights_r <= reuse_weights;
            host_wr_en_r    <= host_wr_en;
            host_wr_addr_r  <= host_wr_addr;
            host_wr_data_r  <= host_wr_data;
            acc_slot_r      <= acc_slot;
        end
    end

    // DMA → scratchpad (write port)
    logic                                         sp_wr_en;
    logic                                         sp_wr_type;
    logic [$clog2(ARRAY_SIZE/2)-1:0]               sp_wr_addr;
    logic [2*ARRAY_SIZE*DATA_WIDTH-1:0]            sp_wr_data;

    // DMA → scratchpad (read control). Two independent weight-read
    // addresses/data paths (chain A: array rows 0..ARRAY_SIZE/2-1, chain B:
    // rows ARRAY_SIZE/2..ARRAY_SIZE-1 -- see array_top.sv/scratchpad.sv);
    // activation read stays single.
    logic [$clog2(ARRAY_SIZE)-1:0]                sp_rd_weight_row_a;
    logic [$clog2(ARRAY_SIZE)-1:0]                sp_rd_weight_row_b;
    logic [$clog2(ARRAY_SIZE)-1:0]                sp_rd_act_row;
    logic                                         sp_weight_bank_swap;
    logic                                         sp_act_bank_swap;

    // DMA → array_top (control). shadow_load_en/act_col_vld are issued one
    // cycle ahead of scratchpad data validity; scratchpad adds one more
    // cycle of registration (address + data register), so accel_top adds a
    // matching one-cycle compensation stage below (shadow_load_en_sp/
    // act_col_vld_sp). commit_trigger needs the same compensation: its
    // delay network is timed against act_col_vld_sp, not dma_ctrl's
    // un-compensated act_col_vld. shadow_load_sel/commit_sel need the same
    // compensation as their paired enable, since each pair must arrive at
    // array_top synchronized.
    logic                                         shadow_load_en;
    logic [2:0]                                   shadow_load_sel;
    logic                                         act_col_vld;
    logic                                         commit_trigger;
    logic [2:0]                                   commit_sel;
    logic                                         shadow_load_en_sp;
    logic [2:0]                                   shadow_load_sel_sp;
    logic                                         act_col_vld_sp;
    logic                                         commit_trigger_sp;
    logic [2:0]                                   commit_sel_sp;

    // DMA → output_buffer (clear/slot for whichever tile is currently
    // committed -- see output_buffer.sv and dma_ctrl.sv headers for why
    // this can't just be accel_top's registered acc_slot_r once loading
    // and computing overlap)
    logic                                         sp_buf_clear;
    logic [$clog2(NUM_ACC_SLOTS)-1:0]              sp_clear_slot_sel;
    logic [$clog2(NUM_ACC_SLOTS)-1:0]              sp_slot_sel;

    // Scratchpad → sparsity_unit (raw activations)
    logic [DATA_WIDTH-1:0]                        sp_act_data    [ARRAY_SIZE];

    // sparsity_unit → array_top (filtered activations + skip enables)
    logic [DATA_WIDTH-1:0]                        act_col_in     [ARRAY_SIZE];
    logic [ARRAY_SIZE-1:0]                        skip_en_col;

    // Scratchpad → array_top (weights, now feeding the two shadow preload
    // chain entry points)
    logic [DATA_WIDTH-1:0]                        shadow_load_in_a [ARRAY_SIZE];
    logic [DATA_WIDTH-1:0]                        shadow_load_in_b [ARRAY_SIZE];

    // array_top → output_buffer
    logic [ACC_WIDTH-1:0]                         psum_out_row [ARRAY_SIZE];
    logic                                         psum_out_vld;

    // ------------------------------------------------------------------
    // DMA tiling controller
    // ------------------------------------------------------------------
    dma_ctrl #(
        .ARRAY_SIZE    (ARRAY_SIZE),
        .DATA_WIDTH    (DATA_WIDTH),
        .ACC_WIDTH     (ACC_WIDTH),
        .NUM_ACC_SLOTS (NUM_ACC_SLOTS)
    ) u_dma (
        .clk                (clk),
        .rst_n              (rst_n),
        .start              (start_r),
        .reuse_weights      (reuse_weights_r),
        .clear_accum        (clear_accum_r),
        .slot_sel           (acc_slot_r),
        .ready_for_start    (ready_for_start),
        .host_wr_en         (host_wr_en_r),
        .host_wr_addr       (host_wr_addr_r),
        .host_wr_data       (host_wr_data_r),
        .host_wr_rdy        (host_wr_rdy),
        .sp_wr_en           (sp_wr_en),
        .sp_wr_type         (sp_wr_type),
        .sp_wr_addr         (sp_wr_addr),
        .sp_wr_data         (sp_wr_data),
        .sp_rd_weight_row_a (sp_rd_weight_row_a),
        .sp_rd_weight_row_b (sp_rd_weight_row_b),
        .sp_rd_act_row      (sp_rd_act_row),
        .sp_weight_bank_swap(sp_weight_bank_swap),
        .sp_act_bank_swap   (sp_act_bank_swap),
        .shadow_load_en     (shadow_load_en),
        .shadow_load_sel    (shadow_load_sel),
        .commit_trigger     (commit_trigger),
        .commit_sel         (commit_sel),
        .act_col_vld        (act_col_vld),
        .sp_buf_clear       (sp_buf_clear),
        .sp_clear_slot_sel  (sp_clear_slot_sel),
        .sp_slot_sel        (sp_slot_sel)
    );

    // ------------------------------------------------------------------
    // Ping-pong scratchpad
    // ------------------------------------------------------------------
    scratchpad #(
        .ARRAY_SIZE       (ARRAY_SIZE),
        .DATA_WIDTH       (DATA_WIDTH),
        .SCRATCHPAD_DEPTH (SCRATCHPAD_DEPTH),
        .NUM_BANKS        (NUM_BANKS)
    ) u_scratchpad (
        .clk                 (clk),
        .rst_n               (rst_n),
        .wr_weight_bank_swap (sp_weight_bank_swap),
        .wr_act_bank_swap    (sp_act_bank_swap),
        .wr_en               (sp_wr_en),
        .wr_type             (sp_wr_type),
        .wr_addr             (sp_wr_addr),
        .wr_data             (sp_wr_data),
        .rd_weight_row_a     (sp_rd_weight_row_a),
        .rd_weight_data_a    (shadow_load_in_a),
        .rd_weight_row_b     (sp_rd_weight_row_b),
        .rd_weight_data_b    (shadow_load_in_b),
        .rd_act_row          (sp_rd_act_row),
        .rd_act_data         (sp_act_data)
    );

    // The scratchpad registers its command pins before the storage array
    // (address register + data register), adding one cycle beyond the
    // latency dma_ctrl's addressing already accounts for.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            shadow_load_en_sp  <= 1'b0;
            shadow_load_sel_sp <= 3'b0;
            act_col_vld_sp     <= 1'b0;
            commit_trigger_sp  <= 1'b0;
            commit_sel_sp      <= 3'b0;
        end else begin
            shadow_load_en_sp  <= shadow_load_en;
            shadow_load_sel_sp <= shadow_load_sel;
            act_col_vld_sp     <= act_col_vld;
            commit_trigger_sp  <= commit_trigger;
            commit_sel_sp      <= commit_sel;
        end
    end

    // ------------------------------------------------------------------
    // Sparsity detection unit
    // Sits between scratchpad output and array left-column input.
    // Detects zero activations → asserts skip_en_col → PE skips MAC.
    // ------------------------------------------------------------------
    sparsity_unit #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_sparsity (
        .clk               (clk),
        .rst_n             (rst_n),
        .clear             (start_r),
        .act_in            (sp_act_data),
        .act_col_vld       (act_col_vld_sp),
        .act_out           (act_col_in),
        .skip_en_col       (skip_en_col),
        .total_mac_cycles  (total_mac_cycles),
        .skipped_mac_cycles(skipped_mac_cycles)
    );

    // ------------------------------------------------------------------
    // 16×16 systolic array
    // ------------------------------------------------------------------
    array_top #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_array (
        .clk           (clk),
        .rst_n         (rst_n),
        .act_col_in    (act_col_in),
        .act_col_vld   (act_col_vld_sp),
        .shadow_load_in_a(shadow_load_in_a),
        .shadow_load_in_b(shadow_load_in_b),
        .shadow_load_en  (shadow_load_en_sp),
        .shadow_load_sel (shadow_load_sel_sp),
        .commit_trigger  (commit_trigger_sp),
        .commit_sel      (commit_sel_sp),
        .skip_en_col     (skip_en_col),
        .psum_out_row    (psum_out_row),
        .psum_out_vld    (psum_out_vld)
    );

    // ------------------------------------------------------------------
    // Output accumulation buffer
    // clear_accum lets tiled benchmarks keep partial sums across K tiles.
    // buf_clear/slot_sel come from dma_ctrl (the currently-committed
    // tile's own values, safe under preload-while-computing overlap);
    // rd_slot_sel is wired directly from the host's live acc_slot input
    // since a read can target an unrelated, already-finished tile.
    // `done` now originates here, not from dma_ctrl -- with per-PE
    // staggered commit, multiple tiles can be mid-capture at once, so
    // completion is inherently output_buffer's own per-window event, not a
    // single dma_ctrl FSM state.
    // ------------------------------------------------------------------
    output_buffer #(
        .ARRAY_SIZE    (ARRAY_SIZE),
        .ACC_WIDTH     (ACC_WIDTH),
        .NUM_ACC_SLOTS (NUM_ACC_SLOTS)
    ) u_obuf (
        .clk            (clk),
        .rst_n          (rst_n),
        .buf_clear      (sp_buf_clear),
        .clear_slot_sel (sp_clear_slot_sel),
        .slot_sel       (sp_slot_sel),
        .rd_slot_sel    (acc_slot_r),
        .act_col_vld    (act_col_vld_sp),
        .psum_in        (psum_out_row),
        .done        (done),
        .rd_row      (rd_row),
        .rd_col      (rd_col),
        .rd_row_data (rd_row_data),
        .rd_data     (rd_data),
        .rd_row_data_all (rd_row_data_all)
    );

endmodule
