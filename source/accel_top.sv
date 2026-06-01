//------------------------------------------------------------------------------
// accel_top
//------------------------------------------------------------------------------
// Top-level accelerator integration wrapper.
//
// This module connects the host/testbench interface, DMA-style tile controller,
// ping-pong scratchpad, activation sparsity detector, 16x16 systolic array, and
// output accumulation buffer. The host writes one 16-element row per cycle for
// the B tile followed by the A tile. The controller then preloads weights,
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
    parameter int NUM_BANKS        = 2
)(
    input  logic clk,
    input  logic rst_n,

    // Host control
    input  logic  start,
    input  logic  clear_accum,
    output logic  done,

    // Host tile-write port — one complete 16-byte row per cycle.
    input  logic                                         host_wr_en,
    input  logic [$clog2(ARRAY_SIZE)-1:0]                host_wr_addr,
    input  logic [ARRAY_SIZE*DATA_WIDTH-1:0]             host_wr_data,
    output logic                                         host_wr_rdy,

    // Output buffer read port — valid after done asserts
    input  logic [$clog2(ARRAY_SIZE)-1:0]                rd_row,
    input  logic [$clog2(ARRAY_SIZE)-1:0]                rd_col,
    output logic [ARRAY_SIZE*ACC_WIDTH-1:0]              rd_row_data,
    output logic [ACC_WIDTH-1:0]                         rd_data,

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
    logic                                         host_wr_en_r;
    logic [$clog2(ARRAY_SIZE)-1:0]                host_wr_addr_r;
    logic [ARRAY_SIZE*DATA_WIDTH-1:0]             host_wr_data_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            start_r        <= 1'b0;
            clear_accum_r  <= 1'b0;
            host_wr_en_r   <= 1'b0;
            host_wr_addr_r <= '0;
            host_wr_data_r <= '0;
        end else begin
            start_r        <= start;
            clear_accum_r  <= clear_accum;
            host_wr_en_r   <= host_wr_en;
            host_wr_addr_r <= host_wr_addr;
            host_wr_data_r <= host_wr_data;
        end
    end

    // DMA → scratchpad (write port)
    logic                                         sp_wr_en;
    logic                                         sp_wr_type;
    logic [$clog2(ARRAY_SIZE)-1:0]                sp_wr_addr;
    logic [ARRAY_SIZE*DATA_WIDTH-1:0]             sp_wr_data;

    // DMA → scratchpad (read control)
    logic [$clog2(ARRAY_SIZE)-1:0]                sp_rd_weight_row;
    logic [$clog2(ARRAY_SIZE)-1:0]                sp_rd_act_row;
    logic                                         sp_bank_swap;

    // DMA → array_top (control)
    logic                                         weight_load_en;
    logic                                         act_col_vld;
    logic                                         weight_load_en_sp;
    logic                                         act_col_vld_sp;

    // Scratchpad → sparsity_unit (raw activations)
    logic [DATA_WIDTH-1:0]                        sp_act_data    [ARRAY_SIZE];

    // sparsity_unit → array_top (filtered activations + skip enables)
    logic [DATA_WIDTH-1:0]                        act_col_in     [ARRAY_SIZE];
    logic [ARRAY_SIZE-1:0]                        skip_en_col;

    // Scratchpad → array_top (weights)
    logic [DATA_WIDTH-1:0]                        weight_load_in [ARRAY_SIZE];

    // array_top → output_buffer
    logic [ACC_WIDTH-1:0]                         psum_out_row [ARRAY_SIZE];
    logic                                         psum_out_vld;

    // ------------------------------------------------------------------
    // DMA tiling controller
    // ------------------------------------------------------------------
    dma_ctrl #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_dma (
        .clk             (clk),
        .rst_n           (rst_n),
        .start           (start_r),
        .done            (done),
        .host_wr_en      (host_wr_en_r),
        .host_wr_addr    (host_wr_addr_r),
        .host_wr_data    (host_wr_data_r),
        .host_wr_rdy     (host_wr_rdy),
        .sp_wr_en        (sp_wr_en),
        .sp_wr_type      (sp_wr_type),
        .sp_wr_addr      (sp_wr_addr),
        .sp_wr_data      (sp_wr_data),
        .sp_rd_weight_row(sp_rd_weight_row),
        .sp_rd_act_row   (sp_rd_act_row),
        .sp_bank_swap    (sp_bank_swap),
        .weight_load_en  (weight_load_en),
        .act_col_vld     (act_col_vld)
    );

    // ------------------------------------------------------------------
    // Ping-pong scratchpad SRAM
    // ------------------------------------------------------------------
    scratchpad #(
        .ARRAY_SIZE       (ARRAY_SIZE),
        .DATA_WIDTH       (DATA_WIDTH),
        .SCRATCHPAD_DEPTH (SCRATCHPAD_DEPTH),
        .NUM_BANKS        (NUM_BANKS)
    ) u_scratchpad (
        .clk            (clk),
        .rst_n          (rst_n),
        .bank_swap      (sp_bank_swap),
        .wr_en          (sp_wr_en),
        .wr_type        (sp_wr_type),
        .wr_addr        (sp_wr_addr),
        .wr_data        (sp_wr_data),
        .rd_weight_row  (sp_rd_weight_row),
        .rd_weight_data (weight_load_in),
        .rd_act_row     (sp_rd_act_row),
        .rd_act_data    (sp_act_data)
    );

    // The scratchpad registers SRAM command pins before the macros, adding
    // one cycle beyond the synchronous SRAM read latency.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            weight_load_en_sp <= 1'b0;
            act_col_vld_sp    <= 1'b0;
        end else begin
            weight_load_en_sp <= weight_load_en;
            act_col_vld_sp    <= act_col_vld;
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
        .weight_load_in(weight_load_in),
        .weight_load_en(weight_load_en_sp),
        .skip_en_col   (skip_en_col),
        .psum_out_row  (psum_out_row),
        .psum_out_vld  (psum_out_vld)
    );

    // ------------------------------------------------------------------
    // Output accumulation buffer
    // clear_accum lets tiled benchmarks keep partial sums across K tiles.
    // ------------------------------------------------------------------
    output_buffer #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_obuf (
        .clk         (clk),
        .rst_n       (rst_n),
        .buf_clear   (start_r && clear_accum_r),
        .act_col_vld (act_col_vld_sp),
        .psum_in     (psum_out_row),
        .rd_row      (rd_row),
        .rd_col      (rd_col),
        .rd_row_data (rd_row_data),
        .rd_data     (rd_data)
    );

endmodule
