`timescale 1ns/1ps

//------------------------------------------------------------------------------
// accel_rect_benchmark_tb
//------------------------------------------------------------------------------
// Rectangular tiled matrix-multiply benchmark for accel_top.
//
// Runtime plusargs:
//   +N=<64|128|256>                 legacy square mode, default 64
//   +M=<multiple of 16> +K=<...> +N=<...>
//                                   rectangular GEMM C[M,N] = A[M,K] * B[K,N]
//   +ROWS=<...> +INNER=<...> +COLS=<...>
//                                   aliases for M/K/N to avoid N ambiguity
//   +MODE=<dense|sparse50|sparse75|sparse90>, default dense
//   +CHECK=<full|sample|checksum|none>, default full
//   +DUMP_VCD=<path>                 optional DUT-only VCD activity dump for
//                                    the measured benchmark window
//   +DUMP_START_CYCLE=<cycles>       optional offset from benchmark start
//   +DUMP_CYCLES=<cycles>            optional dump length; default dumps until
//                                    benchmark end
//
// The DUT computes one 16x16 tile product per run. This benchmark keeps the
// output-buffer partial sums on chip across the K tile loop:
//   for tile_i in M/16, tile_j in N/16, tile_k in K/16:
//     run DUT on A[tile_i,tile_k] and B[tile_k,tile_j]
//   read final 16x16 C tile once
//------------------------------------------------------------------------------

module accel_rect_benchmark_tb;
    timeunit 1ps;
    timeprecision 1ps;

    localparam int ARRAY_SIZE = 16;
    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;
    localparam int MAX_M      = 1024;
    localparam int MAX_K      = 3072;
    localparam int MAX_N      = 3072;
    localparam int ROW_W      = $clog2(ARRAY_SIZE);
    localparam int PAIR_W     = $clog2(ARRAY_SIZE/2);       // host_wr_addr is a row-pair index
    localparam int NUM_ACC_SLOTS_TOP = 4;                    // must match accel_top's default
    localparam time TB_SAMPLE_DELAY = 2000ps;
    localparam longint unsigned CLK_PERIOD_PS = 6000;

    logic                   clk, rst_n, start, clear_accum, done, ready_for_start;
    logic                   host_wr_en, host_wr_rdy;
    logic [PAIR_W-1:0]      host_wr_addr;
    logic [2*ARRAY_SIZE*DATA_WIDTH-1:0] host_wr_data;
    logic [ROW_W-1:0]       rd_row, rd_col;
    logic [ARRAY_SIZE*ACC_WIDTH-1:0] rd_row_data;
    logic [ACC_WIDTH-1:0]   rd_data;
    // All-slots read port -- see output_buffer.sv/accel_top.sv. Auto-wired
    // to accel_top's new rd_row_data_all output via the DUT's `.*`.
    logic [NUM_ACC_SLOTS_TOP*ARRAY_SIZE*ACC_WIDTH-1:0] rd_row_data_all;
    logic [31:0]            total_mac_cycles, skipped_mac_cycles;
    // Which of the 4 output-buffer accumulator slots the in-flight tile
    // targets. The original ti/tj/tk loop (run_accel_tile) always uses slot
    // 0 -- one output tile fully finishes before the next starts, so a
    // single slot is sufficient. The weight-stationary blocked loop
    // (run_accel_tile_blocked) drives this per up-to-4 concurrently-open
    // row-tiles.
    logic [1:0]              acc_slot = 2'b00;
    // Set for one cycle alongside start when the incoming weight tile
    // matches what the array already holds (weight-stationary blocked
    // schedule only) -- lets dma_ctrl skip the weight reload/preload.
    logic                     reuse_weights = 1'b0;

    logic [DATA_WIDTH-1:0] A [MAX_M][MAX_K];
    logic [DATA_WIDTH-1:0] B [MAX_K][MAX_N];
    logic [DATA_WIDTH-1:0] tile_a [ARRAY_SIZE][ARRAY_SIZE];
    logic [DATA_WIDTH-1:0] tile_b [ARRAY_SIZE][ARRAY_SIZE];
    logic [ACC_WIDTH-1:0]  C_hw [MAX_M][MAX_N];
    logic [ACC_WIDTH-1:0]  C_ref[MAX_M][MAX_N];

    int bench_m;
    int bench_k;
    int bench_n;
    int sparse_percent;
    string mode;
    string check_mode;
    string dump_vcd_file;
    bit dump_vcd;
    bit dump_done;
    longint unsigned dump_start_cycles;
    longint unsigned dump_cycles;
    longint unsigned cycle_count;
    longint unsigned accel_cycles;
    longint unsigned read_cycles;
    longint unsigned bench_start_cycle;
    longint unsigned bench_end_cycle;
    longint unsigned tile_start_cycle;
    longint unsigned tile_done_cycle;
    longint unsigned read_start_cycle;
    longint unsigned read_done_cycle;
    longint unsigned tile_runs;
    longint unsigned mismatches;
    longint unsigned checked_outputs;
    longint unsigned hw_checksum;
    longint unsigned ref_checksum;
    longint unsigned total_macs;
    longint unsigned total_ops;

    accel_top #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) dut (.*);

    initial clk = 0;
    always #3000 clk = ~clk;

    always_ff @(posedge clk) begin
        if (!rst_n)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    // Background done-pulse counter for the pipelined schedule: tiles are
    // issued without waiting for their own done, so a simple "poll for the
    // next done" would miss one that already fired. Counting continuously
    // from reset lets wait_done_count(N) answer "has at least N tiles
    // finished" regardless of when it's called.
    longint unsigned done_count;
    longint unsigned pipeline_last_done_cycle;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            done_count               <= 0;
            pipeline_last_done_cycle <= 0;
        end else if (done) begin
            done_count               <= done_count + 1;
            pipeline_last_done_cycle <= cycle_count;
        end
    end

    task wait_done_count(input longint unsigned target, input int timeout_cycles);
        for (int i = 0; i < timeout_cycles; i++) begin
            if (done_count >= target)
                return;
            @(posedge clk);
        end
        $display("BENCH_FAIL timeout waiting for done_count=%0d (have %0d)", target, done_count);
        $finish;
    endtask

    function automatic logic [DATA_WIDTH-1:0] dense_a(input int r, input int c);
        dense_a = DATA_WIDTH'(((r * 13 + c * 7 + 1) % 15) + 1);
    endfunction

    function automatic logic [DATA_WIDTH-1:0] dense_b(input int r, input int c);
        dense_b = DATA_WIDTH'(((r * 5 + c * 11 + 3) % 15) + 1);
    endfunction

    // Deterministic pseudo-random sparsity pattern applied to A and B. The fixed
    // hash makes dense/sparse runs comparable across simulators and reruns.
    function automatic bit make_sparse_zero(input int r, input int c, input int pct);
        int hash;
        begin
            hash = (r * 131 + c * 17 + r * c * 7) % 100;
            make_sparse_zero = (hash < pct);
        end
    endfunction

    // Independent hash (different coefficients) so B's zero pattern isn't a
    // trivial copy of A's -- exercises pe.sv's weight-side zero gate
    // (weight_r == '0) at the same target density as the activation side.
    function automatic bit make_sparse_zero_b(input int r, input int c, input int pct);
        int hash;
        begin
            hash = (r * 47 + c * 89 + r * c * 3 + 41) % 100;
            make_sparse_zero_b = (hash < pct);
        end
    endfunction

    function automatic int parse_sparse_percent(input string mode_arg);
        if (mode_arg == "dense")
            parse_sparse_percent = 0;
        else if (mode_arg == "sparse50")
            parse_sparse_percent = 50;
        else if (mode_arg == "sparse75")
            parse_sparse_percent = 75;
        else if (mode_arg == "sparse90")
            parse_sparse_percent = 90;
        else begin
            $display("BENCH_FAIL unsupported MODE=%s", mode_arg);
            $finish;
        end
    endfunction

    // CHECK controls how much software comparison work is done after the
    // hardware run. This lets large ML-style cases report hardware timing
    // without spending most wall-clock time in the reference checker.
    task validate_check_mode(input string check_arg);
        if ((check_arg != "full") && (check_arg != "sample") &&
            (check_arg != "checksum") && (check_arg != "none")) begin
            $display("BENCH_FAIL unsupported CHECK=%s", check_arg);
            $finish;
        end
    endtask

    function automatic logic [ACC_WIDTH-1:0] expected_value(input int row, input int col);
        logic [ACC_WIDTH-1:0] sum;
        begin
            sum = '0;
            for (int k = 0; k < bench_k; k++)
                sum += ACC_WIDTH'(A[row][k]) * ACC_WIDTH'(B[k][col]);
            expected_value = sum;
        end
    endfunction

    task apply_reset();
        rst_n = 0;
        start = 0;
        clear_accum = 0;
        host_wr_en = 0;
        host_wr_addr = '0;
        host_wr_data = '0;
        rd_row = '0;
        rd_col = '0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    // TWO rows per cycle: host_wr_addr is a row-pair index; host_wr_data's
    // lower half is row 2*addr, upper half row 2*addr+1.
    task write_tile(input logic [DATA_WIDTH-1:0] data [ARRAY_SIZE][ARRAY_SIZE]);
        while (!host_wr_rdy) begin
            @(posedge clk);
        end
        @(negedge clk);
        for (int p = 0; p < ARRAY_SIZE/2; p++) begin
            host_wr_en   = 1'b1;
            host_wr_addr = PAIR_W'(p);
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                host_wr_data[c*DATA_WIDTH +: DATA_WIDTH] = data[2*p][c];
                host_wr_data[(ARRAY_SIZE+c)*DATA_WIDTH +: DATA_WIDTH] = data[2*p+1][c];
            end
            @(posedge clk);
            @(negedge clk);
        end
        host_wr_en = 1'b0;
    endtask

    task wait_done(input int timeout_cycles);
        for (int i = 0; i < timeout_cycles; i++) begin
            if (done)
                return;
            @(posedge clk);
        end
        $display("BENCH_FAIL timeout waiting for done after %0d cycles", timeout_cycles);
        $finish;
    endtask

    task read_final_tile(input int base_r, input int base_c);
        read_start_cycle = cycle_count;
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            @(negedge clk);
            rd_row = ROW_W'(r);
            rd_col = '0;
            repeat (8) @(posedge clk);
            #(TB_SAMPLE_DELAY);
            for (int c = 0; c < ARRAY_SIZE; c++)
                C_hw[base_r + r][base_c + c] = rd_row_data[c*ACC_WIDTH +: ACC_WIDTH];
        end
        read_done_cycle = cycle_count;
        read_cycles += read_done_cycle - read_start_cycle;
    endtask

    // Executes one hardware 16x16 tile multiply. clear_tile is asserted only on
    // the first K tile of a C tile so the output buffer can accumulate partial
    // sums across the remaining K tiles.
    task run_accel_tile(input int tile_i, input int tile_j, input int tile_k, input bit clear_tile);
        int base_i;
        int base_j;
        int base_k;
        begin
            base_i = tile_i * ARRAY_SIZE;
            base_j = tile_j * ARRAY_SIZE;
            base_k = tile_k * ARRAY_SIZE;

            for (int r = 0; r < ARRAY_SIZE; r++) begin
                for (int c = 0; c < ARRAY_SIZE; c++) begin
                    tile_a[r][c] = A[base_i + r][base_k + c];
                    tile_b[r][c] = B[base_k + r][base_j + c];
                end
            end

            tile_start_cycle = cycle_count;
            @(negedge clk);
            clear_accum = clear_tile;
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
            clear_accum = 1'b0;
            write_tile(tile_b);
            write_tile(tile_a);
            wait_done(1000);
            tile_done_cycle = cycle_count;
            accel_cycles += tile_done_cycle - tile_start_cycle;
            tile_runs++;
        end
    endtask

    // Weight-stationary variant of run_accel_tile: targets accumulator slot
    // `slot` instead of always slot 0, so up to NUM_ACC_SLOTS row-tiles can
    // stay open at once, reusing the weight tile B[tile_k,tile_j] across
    // all of them. `reuse` assumes B[tile_k,tile_j] is already loaded and
    // skips write_tile for the weight half -- dma_ctrl doesn't assert
    // host_wr_rdy for weights in this mode, so writing them would hang.
    task run_accel_tile_blocked(input int tile_i, input int tile_j, input int tile_k,
                                 input bit clear_tile, input int slot, input bit reuse);
        int base_i;
        int base_j;
        int base_k;
        begin
            base_i = tile_i * ARRAY_SIZE;
            base_j = tile_j * ARRAY_SIZE;
            base_k = tile_k * ARRAY_SIZE;

            for (int r = 0; r < ARRAY_SIZE; r++) begin
                for (int c = 0; c < ARRAY_SIZE; c++) begin
                    tile_a[r][c] = A[base_i + r][base_k + c];
                    tile_b[r][c] = B[base_k + r][base_j + c];
                end
            end

            tile_start_cycle = cycle_count;
            @(negedge clk);
            clear_accum = clear_tile;
            acc_slot = 2'(slot);
            reuse_weights = reuse;
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
            clear_accum = 1'b0;
            reuse_weights = 1'b0;
            if (!reuse)
                write_tile(tile_b);
            write_tile(tile_a);
            wait_done(1000);
            tile_done_cycle = cycle_count;
            accel_cycles += tile_done_cycle - tile_start_cycle;
            tile_runs++;
        end
    endtask

    task read_final_tile_blocked(input int base_r, input int base_c, input int slot);
        read_start_cycle = cycle_count;
        acc_slot = 2'(slot);
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            @(negedge clk);
            rd_row = ROW_W'(r);
            rd_col = '0;
            repeat (8) @(posedge clk);
            #(TB_SAMPLE_DELAY);
            for (int c = 0; c < ARRAY_SIZE; c++)
                C_hw[base_r + r][base_c + c] = rd_row_data[c*ACC_WIDTH +: ACC_WIDTH];
        end
        read_done_cycle = cycle_count;
        read_cycles += read_done_cycle - read_start_cycle;
    endtask

    // Weight-stationary blocked schedule: for each column-tile tj, process
    // row-tiles in blocks of up to NUM_ACC_SLOTS. Outer loop tk, inner loop
    // row-tile within the block, so each weight tile B[tk,tj] loads once
    // and is reused across the block -- opposite reuse pattern from
    // run_accel_tile's output-stationary loop. Requires bench_m to be a
    // multiple of NUM_ACC_SLOTS*ARRAY_SIZE (no partial-block handling).
    task run_gemm_blocked();
        localparam int NUM_ACC_SLOTS = 4;
        int row_tiles;
        int col_tiles;
        int k_tiles;
        begin
            row_tiles = bench_m / ARRAY_SIZE;
            col_tiles = bench_n / ARRAY_SIZE;
            k_tiles   = bench_k / ARRAY_SIZE;

            if ((row_tiles % NUM_ACC_SLOTS) != 0) begin
                $display("BENCH_FAIL run_gemm_blocked requires M to be a multiple of %0d*%0d, got M=%0d",
                          NUM_ACC_SLOTS, ARRAY_SIZE, bench_m);
                $finish;
            end

            for (int tj = 0; tj < col_tiles; tj++) begin
                for (int ti_block = 0; ti_block < row_tiles; ti_block += NUM_ACC_SLOTS) begin
                    for (int tk = 0; tk < k_tiles; tk++) begin
                        for (int s = 0; s < NUM_ACC_SLOTS; s++) begin
                            run_accel_tile_blocked(ti_block + s, tj, tk, (tk == 0), s, (s != 0));
                        end
                    end
                    for (int s = 0; s < NUM_ACC_SLOTS; s++) begin
                        read_final_tile_blocked((ti_block + s) * ARRAY_SIZE, tj * ARRAY_SIZE, s);
                    end
                end
            end
        end
    endtask

    // Issues one tile's start+writes and returns immediately without
    // waiting for done, letting the host overlap issuing tile N+1 with
    // tile N still computing (host_wr_rdy backpressure paces issuance).
    // issued_count tracks how many tiles have been issued so callers can
    // map a done_count value to a given tile's completion.
    longint unsigned issued_count;
    bit               pipeline_started;
    longint unsigned pipeline_first_start_cycle;

    task run_accel_tile_pipelined(input int tile_i, input int tile_j, input int tile_k,
                                   input bit clear_tile, input int slot);
        int base_i;
        int base_j;
        int base_k;
        begin
            base_i = tile_i * ARRAY_SIZE;
            base_j = tile_j * ARRAY_SIZE;
            base_k = tile_k * ARRAY_SIZE;

            for (int r = 0; r < ARRAY_SIZE; r++) begin
                for (int c = 0; c < ARRAY_SIZE; c++) begin
                    tile_a[r][c] = A[base_i + r][base_k + c];
                    tile_b[r][c] = B[base_k + r][base_j + c];
                end
            end

            if (!pipeline_started) begin
                pipeline_started           = 1'b1;
                pipeline_first_start_cycle = cycle_count;
            end

            // Must wait for this, not just for the previous write_tile
            // calls to return: those only confirm the previous tile's
            // host-bus transfers finished, not that its prefetch has
            // vacated PF_IDLE (shadow preload can still be running a
            // cycle or two longer). Asserting start before ready_for_start
            // gets it silently dropped -- dma_ctrl only samples start
            // while idle, with no queue.
            while (!ready_for_start) @(posedge clk);

            @(negedge clk);
            clear_accum = clear_tile;
            acc_slot    = 2'(slot);
            start       = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start       = 1'b0;
            clear_accum = 1'b0;
            write_tile(tile_b);
            write_tile(tile_a);
            issued_count++;
            tile_runs++;
        end
    endtask

    // Same non-blocking issuance as run_accel_tile_pipelined, plus a
    // `reuse` flag (same semantics as run_accel_tile_blocked's): skip the
    // weight-tile host-bus write when B[tile_k,tile_j] is unchanged from
    // the preceding issued tile. Safe with pipelining: reuse_weights only
    // skips PF_LOAD_WEIGHTS, not the shadow-register shift, so the shadow
    // buffer still refreshes every tile.
    task run_accel_tile_pipelined_reuse(input int tile_i, input int tile_j, input int tile_k,
                                         input bit clear_tile, input int slot, input bit reuse);
        int base_i;
        int base_j;
        int base_k;
        begin
            base_i = tile_i * ARRAY_SIZE;
            base_j = tile_j * ARRAY_SIZE;
            base_k = tile_k * ARRAY_SIZE;

            for (int r = 0; r < ARRAY_SIZE; r++) begin
                for (int c = 0; c < ARRAY_SIZE; c++) begin
                    tile_a[r][c] = A[base_i + r][base_k + c];
                    tile_b[r][c] = B[base_k + r][base_j + c];
                end
            end

            if (!pipeline_started) begin
                pipeline_started           = 1'b1;
                pipeline_first_start_cycle = cycle_count;
            end

            while (!ready_for_start) @(posedge clk);
            // Extra margin beyond ready_for_start, reuse tiles only:
            // dma_ctrl's MIN_GAP is not sufficient once reuse_weights lets
            // tiles commit back-to-back at ~17 cycles apart -- verified
            // empirically that 3+ extra cycles is clean, using 4 for slack.
            // Testbench-side mitigation; the real fix belongs in dma_ctrl's
            // MIN_GAP.
            if (reuse) repeat (4) @(posedge clk);

            @(negedge clk);
            clear_accum   = clear_tile;
            acc_slot      = 2'(slot);
            reuse_weights = reuse;
            start         = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start         = 1'b0;
            clear_accum   = 1'b0;
            reuse_weights = 1'b0;
            if (!reuse)
                write_tile(tile_b);
            write_tile(tile_a);
            issued_count++;
            tile_runs++;
        end
    endtask

    // Weight-stationary tiling order (same as run_gemm_blocked) combined
    // with non-blocking pipelined issuance (same as run_gemm_pipelined).
    task run_gemm_pipelined_reuse();
        localparam int NUM_ACC_SLOTS = 4;
        int row_tiles;
        int col_tiles;
        int k_tiles;
        longint unsigned slot_done_target [NUM_ACC_SLOTS];
        begin
            row_tiles = bench_m / ARRAY_SIZE;
            col_tiles = bench_n / ARRAY_SIZE;
            k_tiles   = bench_k / ARRAY_SIZE;

            if ((row_tiles % NUM_ACC_SLOTS) != 0) begin
                $display("BENCH_FAIL run_gemm_pipelined_reuse requires M to be a multiple of %0d*%0d, got M=%0d",
                          NUM_ACC_SLOTS, ARRAY_SIZE, bench_m);
                $finish;
            end

            for (int tj = 0; tj < col_tiles; tj++) begin
                for (int ti_block = 0; ti_block < row_tiles; ti_block += NUM_ACC_SLOTS) begin
                    for (int tk = 0; tk < k_tiles; tk++) begin
                        for (int s = 0; s < NUM_ACC_SLOTS; s++) begin
                            run_accel_tile_pipelined_reuse(ti_block + s, tj, tk, (tk == 0), s, (s != 0));
                            if (tk == k_tiles - 1)
                                slot_done_target[s] = issued_count;
                        end
                    end
                    for (int s = 0; s < NUM_ACC_SLOTS; s++) begin
                        wait_done_count(slot_done_target[s], 100000);
                        read_final_tile_blocked((ti_block + s) * ARRAY_SIZE, tj * ARRAY_SIZE, s);
                    end
                end
            end

            accel_cycles = pipeline_last_done_cycle - pipeline_first_start_cycle;
        end
    endtask

    // Semaphore protecting the single shared acc_slot wire: a multi-cycle
    // host read (holds acc_slot steady) and a new tile's brief
    // acc_slot+start pulse must never drive that wire in the same cycle.
    semaphore acc_slot_sem = new(1);

    // Same as read_final_tile_blocked, but re-acquires acc_slot_sem once
    // per row instead of once for the whole tile, so a pending tile-issue
    // can interleave between rows instead of being locked out for the
    // whole read.
    task read_final_tile_blocked_ovl(input int base_r, input int base_c, input int slot);
        read_start_cycle = cycle_count;
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            acc_slot_sem.get(1);
            acc_slot = 2'(slot);
            @(negedge clk);
            rd_row = ROW_W'(r);
            rd_col = '0;
            repeat (8) @(posedge clk);
            #(TB_SAMPLE_DELAY);
            for (int c = 0; c < ARRAY_SIZE; c++)
                C_hw[base_r + r][base_c + c] = rd_row_data[c*ACC_WIDTH +: ACC_WIDTH];
            acc_slot_sem.put(1);
        end
        read_done_cycle = cycle_count;
        read_cycles += read_done_cycle - read_start_cycle;
    endtask

    // Same as run_accel_tile_pipelined_reuse, but only holds acc_slot_sem
    // for the brief acc_slot+start pulse window -- write_tile's host-write
    // bus is independent of acc_slot, so it runs outside the semaphore.
    task run_accel_tile_pipelined_reuse_ovl(input int tile_i, input int tile_j, input int tile_k,
                                             input bit clear_tile, input int slot, input bit reuse);
        int base_i;
        int base_j;
        int base_k;
        begin
            base_i = tile_i * ARRAY_SIZE;
            base_j = tile_j * ARRAY_SIZE;
            base_k = tile_k * ARRAY_SIZE;

            for (int r = 0; r < ARRAY_SIZE; r++) begin
                for (int c = 0; c < ARRAY_SIZE; c++) begin
                    tile_a[r][c] = A[base_i + r][base_k + c];
                    tile_b[r][c] = B[base_k + r][base_j + c];
                end
            end

            if (!pipeline_started) begin
                pipeline_started           = 1'b1;
                pipeline_first_start_cycle = cycle_count;
            end

            while (!ready_for_start) @(posedge clk);
            if (reuse) repeat (4) @(posedge clk);

            acc_slot_sem.get(1);
            @(negedge clk);
            clear_accum   = clear_tile;
            acc_slot      = 2'(slot);
            reuse_weights = reuse;
            start         = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start         = 1'b0;
            clear_accum   = 1'b0;
            reuse_weights = 1'b0;
            acc_slot_sem.put(1);
            if (!reuse)
                write_tile(tile_b);
            write_tile(tile_a);
            issued_count++;
            tile_runs++;
        end
    endtask

    // Same schedule as run_gemm_pipelined_reuse, but overlaps each block's
    // read-out with the next block's tile issuance (software-pipelined one
    // block deep) instead of fully serializing them. Safe because the
    // hazard is per-slot, not per-block: a new tile only needs its own
    // target slot's previous occupant read first. slot_read_done[]
    // enforces that per-slot gate; acc_slot_sem enforces the remaining
    // constraint that a read and an issue-pulse can't drive the shared
    // acc_slot wire in the same cycle.
    task run_gemm_pipelined_reuse_ovl();
        localparam int NUM_ACC_SLOTS = 4;
        int row_tiles;
        int col_tiles;
        int k_tiles;
        longint unsigned slot_done_target [NUM_ACC_SLOTS];
        longint unsigned prev_slot_done_target [NUM_ACC_SLOTS];
        bit slot_read_done [NUM_ACC_SLOTS];
        bit have_prev_block;
        int prev_base_r, cur_base_c;
        begin
            row_tiles = bench_m / ARRAY_SIZE;
            col_tiles = bench_n / ARRAY_SIZE;
            k_tiles   = bench_k / ARRAY_SIZE;

            if ((row_tiles % NUM_ACC_SLOTS) != 0) begin
                $display("BENCH_FAIL run_gemm_pipelined_reuse_ovl requires M to be a multiple of %0d*%0d, got M=%0d",
                          NUM_ACC_SLOTS, ARRAY_SIZE, bench_m);
                $finish;
            end

            for (int tj = 0; tj < col_tiles; tj++) begin
                have_prev_block = 1'b0;
                for (int s = 0; s < NUM_ACC_SLOTS; s++) slot_read_done[s] = 1'b1;
                cur_base_c = tj * ARRAY_SIZE;

                for (int ti_block = 0; ti_block < row_tiles; ti_block += NUM_ACC_SLOTS) begin
                    if (have_prev_block)
                        for (int s = 0; s < NUM_ACC_SLOTS; s++) slot_read_done[s] = 1'b0;

                    fork
                        begin : issue_blk
                            for (int tk = 0; tk < k_tiles; tk++) begin
                                for (int s = 0; s < NUM_ACC_SLOTS; s++) begin
                                    if (tk == 0)
                                        wait (slot_read_done[s] == 1'b1);
                                    run_accel_tile_pipelined_reuse_ovl(ti_block + s, tj, tk, (tk == 0), s, (s != 0));
                                    if (tk == k_tiles - 1)
                                        slot_done_target[s] = issued_count;
                                end
                            end
                        end : issue_blk
                        begin : read_prev_blk
                            if (have_prev_block) begin
                                for (int s = 0; s < NUM_ACC_SLOTS; s++) begin
                                    wait_done_count(prev_slot_done_target[s], 100000);
                                    read_final_tile_blocked_ovl(prev_base_r + s * ARRAY_SIZE, cur_base_c, s);
                                    slot_read_done[s] = 1'b1;
                                end
                            end
                        end : read_prev_blk
                    join

                    prev_base_r = ti_block * ARRAY_SIZE;
                    for (int s = 0; s < NUM_ACC_SLOTS; s++)
                        prev_slot_done_target[s] = slot_done_target[s];
                    have_prev_block = 1'b1;
                end

                for (int s = 0; s < NUM_ACC_SLOTS; s++) begin
                    wait_done_count(prev_slot_done_target[s], 100000);
                    read_final_tile_blocked_ovl(prev_base_r + s * ARRAY_SIZE, cur_base_c, s);
                end
            end

            accel_cycles = pipeline_last_done_cycle - pipeline_first_start_cycle;
        end
    endtask

    // Reads all NUM_ACC_SLOTS slots' data for a whole row-tile block in one
    // pass over rd_row=0..15, using output_buffer's rd_row_data_all port
    // instead of NUM_ACC_SLOTS separate per-slot passes -- collapses
    // NUM_ACC_SLOTS*ARRAY_SIZE row-reads into ARRAY_SIZE row-reads.
    task read_final_block_multiport(input int ti_block, input int base_c);
        localparam int NUM_ACC_SLOTS = 4;
        begin
            read_start_cycle = cycle_count;
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                @(negedge clk);
                rd_row = ROW_W'(r);
                rd_col = '0;
                repeat (8) @(posedge clk);
                #(TB_SAMPLE_DELAY);
                for (int s = 0; s < NUM_ACC_SLOTS; s++)
                    for (int c = 0; c < ARRAY_SIZE; c++)
                        C_hw[(ti_block + s) * ARRAY_SIZE + r][base_c + c] =
                            rd_row_data_all[(s*ARRAY_SIZE+c)*ACC_WIDTH +: ACC_WIDTH];
            end
            read_done_cycle = cycle_count;
            read_cycles += read_done_cycle - read_start_cycle;
        end
    endtask

    // Same schedule/tiling as run_gemm_pipelined_reuse (block-boundary
    // reads still block the next block's issuance) but replacing the
    // per-slot read loop with one read_final_block_multiport call per
    // block boundary.
    task run_gemm_pipelined_reuse_multiport();
        localparam int NUM_ACC_SLOTS = 4;
        int row_tiles;
        int col_tiles;
        int k_tiles;
        longint unsigned slot_done_target [NUM_ACC_SLOTS];
        begin
            row_tiles = bench_m / ARRAY_SIZE;
            col_tiles = bench_n / ARRAY_SIZE;
            k_tiles   = bench_k / ARRAY_SIZE;

            if ((row_tiles % NUM_ACC_SLOTS) != 0) begin
                $display("BENCH_FAIL run_gemm_pipelined_reuse_multiport requires M to be a multiple of %0d*%0d, got M=%0d",
                          NUM_ACC_SLOTS, ARRAY_SIZE, bench_m);
                $finish;
            end

            for (int tj = 0; tj < col_tiles; tj++) begin
                for (int ti_block = 0; ti_block < row_tiles; ti_block += NUM_ACC_SLOTS) begin
                    for (int tk = 0; tk < k_tiles; tk++) begin
                        for (int s = 0; s < NUM_ACC_SLOTS; s++) begin
                            run_accel_tile_pipelined_reuse(ti_block + s, tj, tk, (tk == 0), s, (s != 0));
                            if (tk == k_tiles - 1)
                                slot_done_target[s] = issued_count;
                        end
                    end
                    wait_done_count(slot_done_target[NUM_ACC_SLOTS-1], 100000);
                    read_final_block_multiport(ti_block, tj * ARRAY_SIZE);
                end
            end

            accel_cycles = pipeline_last_done_cycle - pipeline_first_start_cycle;
        end
    endtask

    // Pipelined output-stationary schedule: same tiling order as the
    // default SCHED=output loop, but issuance is decoupled from completion
    // via run_accel_tile_pipelined so the next tile's load/shadow-preload
    // can overlap the current tile's compute. Output tiles round-robin
    // across all NUM_ACC_SLOTS slots rather than always slot 0; a slot is
    // only reused once its previous occupant's done has been observed and
    // read out.
    task run_gemm_pipelined();
        localparam int NUM_SLOTS_TB = 4;
        int row_tiles;
        int col_tiles;
        int k_tiles;
        int slot_ti [NUM_SLOTS_TB];
        int slot_tj [NUM_SLOTS_TB];
        longint unsigned slot_done_target [NUM_SLOTS_TB];
        bit slot_busy [NUM_SLOTS_TB];
        int idx;
        int slot;
        begin
            row_tiles = bench_m / ARRAY_SIZE;
            col_tiles = bench_n / ARRAY_SIZE;
            k_tiles   = bench_k / ARRAY_SIZE;

            for (int s = 0; s < NUM_SLOTS_TB; s++)
                slot_busy[s] = 1'b0;

            idx = 0;
            for (int ti = 0; ti < row_tiles; ti++) begin
                for (int tj = 0; tj < col_tiles; tj++) begin
                    slot = idx % NUM_SLOTS_TB;
                    if (slot_busy[slot]) begin
                        wait_done_count(slot_done_target[slot], 100000);
                        read_final_tile_blocked(slot_ti[slot] * ARRAY_SIZE, slot_tj[slot] * ARRAY_SIZE, slot);
                    end
                    for (int tk = 0; tk < k_tiles; tk++)
                        run_accel_tile_pipelined(ti, tj, tk, (tk == 0), slot);
                    slot_ti[slot]          = ti;
                    slot_tj[slot]          = tj;
                    slot_done_target[slot] = issued_count;
                    slot_busy[slot]        = 1'b1;
                    idx++;
                end
            end

            for (int s = 0; s < NUM_SLOTS_TB; s++) begin
                if (slot_busy[s]) begin
                    wait_done_count(slot_done_target[s], 100000);
                    read_final_tile_blocked(slot_ti[s] * ARRAY_SIZE, slot_tj[s] * ARRAY_SIZE, s);
                end
            end

            // Wall-clock span for the whole batch -- NOT a sum of
            // per-tile latencies, which would double-count overlapped
            // time now that tiles genuinely overlap.
            accel_cycles = pipeline_last_done_cycle - pipeline_first_start_cycle;
        end
    endtask

    task init_matrices();
        for (int r = 0; r < bench_m; r++)
            for (int c = 0; c < bench_k; c++)
                A[r][c] = !make_sparse_zero(r, c, sparse_percent) ? dense_a(r, c) : '0;

        for (int r = 0; r < bench_k; r++)
            for (int c = 0; c < bench_n; c++)
                B[r][c] = !make_sparse_zero_b(r, c, sparse_percent) ? dense_b(r, c) : '0;

        for (int r = 0; r < bench_m; r++) begin
            for (int c = 0; c < bench_n; c++) begin
                C_hw[r][c] = '0;
                C_ref[r][c] = '0;
            end
        end
    endtask

    task compute_reference();
        logic [ACC_WIDTH-1:0] sum;
        for (int i = 0; i < bench_m; i++) begin
            for (int j = 0; j < bench_n; j++) begin
                sum = '0;
                for (int k = 0; k < bench_k; k++)
                    sum += ACC_WIDTH'(A[i][k]) * ACC_WIDTH'(B[k][j]);
                C_ref[i][j] = sum;
            end
        end
    endtask

    task check_result();
        int row_step;
        int col_step;
        logic [ACC_WIDTH-1:0] exp;
        mismatches = 0;
        checked_outputs = 0;
        hw_checksum = 0;
        ref_checksum = 0;

        if (check_mode == "none") begin
            $display("BENCH_CHECK skipped CHECK=none");
            return;
        end

        if (check_mode == "checksum") begin
            for (int i = 0; i < bench_m; i++) begin
                for (int j = 0; j < bench_n; j++) begin
                    exp = expected_value(i, j);
                    hw_checksum += longint'(C_hw[i][j]);
                    ref_checksum += longint'(exp);
                    checked_outputs++;
                end
            end
            if (hw_checksum != ref_checksum) begin
                mismatches = 1;
                $display("BENCH_MISMATCH checksum got=%0d exp=%0d",
                         hw_checksum, ref_checksum);
            end
            return;
        end

        row_step = (bench_m > 8) ? (bench_m / 8) : 1;
        col_step = (bench_n > 8) ? (bench_n / 8) : 1;

        for (int i = 0; i < bench_m; i++) begin
            for (int j = 0; j < bench_n; j++) begin
                if ((check_mode == "full") ||
                    (i == 0) || (i == bench_m - 1) ||
                    (j == 0) || (j == bench_n - 1) ||
                    (((i % row_step) == 0) && ((j % col_step) == 0))) begin
                    exp = (check_mode == "full") ? C_ref[i][j] : expected_value(i, j);
                    checked_outputs++;
                    if (C_hw[i][j] !== exp) begin
                        if (mismatches < 16) begin
                            $display("BENCH_MISMATCH C[%0d][%0d] got=%0d exp=%0d",
                                     i, j, C_hw[i][j], exp);
                        end
                        mismatches++;
                    end
                end
            end
        end
    endtask

    task validate_dim(input string name, input int value, input int max_value);
        if ((value < ARRAY_SIZE) || (value > max_value) || ((value % ARRAY_SIZE) != 0)) begin
            $display("BENCH_FAIL %s must be a multiple of %0d in [%0d,%0d]. Got %0d",
                     name, ARRAY_SIZE, ARRAY_SIZE, max_value, value);
            $finish;
        end
    endtask

    // Parse both legacy square mode (+N only) and explicit rectangular mode.
    // ROWS/INNER/COLS aliases avoid ambiguity when scripts already use N for a
    // square dimension.
    task parse_dimensions();
        bit has_m;
        bit has_k;
        bit has_n;
        bit has_rows;
        bit has_inner;
        bit has_cols;
        int legacy_n;
        begin
            bench_m = 64;
            bench_k = 64;
            bench_n = 64;
            legacy_n = 64;

            has_n     = $value$plusargs("N=%d", legacy_n);
            has_m     = $value$plusargs("M=%d", bench_m);
            has_k     = $value$plusargs("K=%d", bench_k);
            has_rows  = $value$plusargs("ROWS=%d", bench_m);
            has_inner = $value$plusargs("INNER=%d", bench_k);
            has_cols  = $value$plusargs("COLS=%d", bench_n);

            if (has_cols) begin
                // COLS explicitly owns bench_n.
            end else if (has_m || has_k || has_rows || has_inner) begin
                if (has_n)
                    bench_n = legacy_n;
            end else if (has_n) begin
                bench_m = legacy_n;
                bench_k = legacy_n;
                bench_n = legacy_n;
            end

            validate_dim("M/ROWS", bench_m, MAX_M);
            validate_dim("K/INNER", bench_k, MAX_K);
            validate_dim("N/COLS", bench_n, MAX_N);
        end
    endtask

    string sched_mode;

    initial begin
        mode = "dense";
        if (!$value$plusargs("MODE=%s", mode))
            mode = "dense";
        check_mode = "full";
        if (!$value$plusargs("CHECK=%s", check_mode))
            check_mode = "full";
        sched_mode = "output";
        if (!$value$plusargs("SCHED=%s", sched_mode))
            sched_mode = "output";
        if ((sched_mode != "output") && (sched_mode != "weight") && (sched_mode != "pipelined") &&
            (sched_mode != "pipelined_reuse") && (sched_mode != "pipelined_reuse_ovl") &&
            (sched_mode != "pipelined_reuse_multiport")) begin
            $display("BENCH_FAIL unsupported SCHED=%s", sched_mode);
            $finish;
        end
        dump_vcd = $value$plusargs("DUMP_VCD=%s", dump_vcd_file);
        if (!$value$plusargs("DUMP_START_CYCLE=%d", dump_start_cycles))
            dump_start_cycles = 0;
        if (!$value$plusargs("DUMP_CYCLES=%d", dump_cycles))
            dump_cycles = 0;

        parse_dimensions();
        sparse_percent = parse_sparse_percent(mode);
        validate_check_mode(check_mode);
        accel_cycles = 0;
        read_cycles = 0;
        tile_runs = 0;

        $display("=== accel rectangular tiled benchmark M=%0d K=%0d N=%0d MODE=%s CHECK=%s ===",
                 bench_m, bench_k, bench_n, mode, check_mode);
        apply_reset();
        init_matrices();
        if (check_mode == "full")
            compute_reference();

        bench_start_cycle = cycle_count;
        if (dump_vcd) begin
            // Activity dump is limited to the measured benchmark window so
            // downstream power analysis does not include reset/setup cycles.
            $dumpfile(dump_vcd_file);
            $dumpvars(0, dut);
            $dumpoff;
            dump_done = 0;
            fork
                begin
                    repeat (dump_start_cycles) @(posedge clk);
                    $dumpon;
                    $display("POWER_WINDOW_START cycle=%0d time_ns=%0.3f",
                             cycle_count, real'($time) / 1000.0);
                    if (dump_cycles != 0) begin
                        repeat (dump_cycles) @(posedge clk);
                        $display("POWER_WINDOW_END cycle=%0d time_ns=%0.3f",
                                 cycle_count, real'($time) / 1000.0);
                        $dumpoff;
                        dump_done = 1;
                    end
                end
            join_none
        end
        if (sched_mode == "weight") begin
            run_gemm_blocked();
        end else if (sched_mode == "pipelined") begin
            run_gemm_pipelined();
        end else if (sched_mode == "pipelined_reuse") begin
            run_gemm_pipelined_reuse();
        end else if (sched_mode == "pipelined_reuse_ovl") begin
            run_gemm_pipelined_reuse_ovl();
        end else if (sched_mode == "pipelined_reuse_multiport") begin
            run_gemm_pipelined_reuse_multiport();
        end else begin
            for (int ti = 0; ti < bench_m / ARRAY_SIZE; ti++) begin
                for (int tj = 0; tj < bench_n / ARRAY_SIZE; tj++) begin
                    for (int tk = 0; tk < bench_k / ARRAY_SIZE; tk++)
                        run_accel_tile(ti, tj, tk, tk == 0);
                    repeat (3 * ARRAY_SIZE) @(posedge clk);
                    #(TB_SAMPLE_DELAY);
                    read_final_tile(ti * ARRAY_SIZE, tj * ARRAY_SIZE);
                end
            end
        end
        bench_end_cycle = cycle_count;
        if (dump_vcd && !dump_done) begin
            $display("POWER_WINDOW_END cycle=%0d time_ns=%0.3f",
                     cycle_count, real'($time) / 1000.0);
            $dumpoff;
            dump_done = 1;
        end

        check_result();

        total_macs = longint'(bench_m) * longint'(bench_k) * longint'(bench_n);
        total_ops = 2 * total_macs;

        $display("BENCH_RESULT status=%s", (mismatches == 0) ? "PASS" : "FAIL");
        $display("BENCH_RESULT m=%0d k=%0d n=%0d mode=%s check=%s tile_runs=%0d",
                 bench_m, bench_k, bench_n, mode, check_mode, tile_runs);
        if ((bench_m == bench_k) && (bench_k == bench_n))
            $display("BENCH_RESULT legacy_n=%0d", bench_n);
        $display("BENCH_RESULT accel_cycles=%0d", accel_cycles);
        $display("BENCH_RESULT read_cycles=%0d", read_cycles);
        $display("BENCH_RESULT end_to_end_cycles=%0d", bench_end_cycle - bench_start_cycle);
        $display("BENCH_RESULT cycle_time_ps=%0d", CLK_PERIOD_PS);
        $display("BENCH_RESULT accel_time_ns=%0.3f", real'(accel_cycles * CLK_PERIOD_PS) / 1000.0);
        $display("BENCH_RESULT end_to_end_time_ns=%0.3f", real'((bench_end_cycle - bench_start_cycle) * CLK_PERIOD_PS) / 1000.0);
        $display("BENCH_RESULT macs=%0d ops=%0d", total_macs, total_ops);
        $display("BENCH_RESULT accel_gmac_s=%0.6f", real'(total_macs) / (real'(accel_cycles * CLK_PERIOD_PS) * 1.0e-3));
        $display("BENCH_RESULT accel_gops_s=%0.6f", real'(total_ops) / (real'(accel_cycles * CLK_PERIOD_PS) * 1.0e-3));
        $display("BENCH_RESULT end_to_end_gmac_s=%0.6f", real'(total_macs) / (real'((bench_end_cycle - bench_start_cycle) * CLK_PERIOD_PS) * 1.0e-3));
        $display("BENCH_RESULT end_to_end_gops_s=%0.6f", real'(total_ops) / (real'((bench_end_cycle - bench_start_cycle) * CLK_PERIOD_PS) * 1.0e-3));
        $display("BENCH_RESULT checked_outputs=%0d", checked_outputs);
        if (check_mode == "checksum")
            $display("BENCH_RESULT hw_checksum=%0d ref_checksum=%0d", hw_checksum, ref_checksum);
        $display("BENCH_RESULT mismatches=%0d", mismatches);

        if (mismatches == 0)
            $display("ALL BENCHMARK CHECKS PASSED");
        else
            $display("BENCHMARK CHECKS FAILED");
        $finish;
    end

endmodule
