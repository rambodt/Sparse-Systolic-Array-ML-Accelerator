`timescale 1ns/1ps

//------------------------------------------------------------------------------
// accel_benchmark_tb
//------------------------------------------------------------------------------
// Tiled matrix-multiply benchmark for accel_top.
//
// Runtime plusargs:
//   +N=<64|128|256>       square matrix dimension, default 64
//   +MODE=<dense|sparse50|sparse75|sparse90>, default dense
//
// The accelerator computes one 16x16 tile product per run and keeps the
// output-buffer partial sums on chip across the K tile loop. This testbench
// tiles C = A * B around the DUT:
//   for tile_i, tile_j, tile_k:
//     run DUT on A[tile_i,tile_k] and B[tile_k,tile_j]
//   read final 16x16 C tile once
//------------------------------------------------------------------------------

module accel_benchmark_tb;
    timeunit 1ps;
    timeprecision 1ps;

    localparam int ARRAY_SIZE = 16;
    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;
    localparam int MAX_N      = 256;
    localparam int ROW_W      = $clog2(ARRAY_SIZE);
    localparam int PAIR_W     = $clog2(ARRAY_SIZE/2);       // host_wr_addr is a row-pair index
    localparam time TB_SAMPLE_DELAY = 2000ps;
    localparam longint unsigned CLK_PERIOD_PS = 5000;

    logic                   clk, rst_n, start, clear_accum, done, ready_for_start;
    logic                   host_wr_en, host_wr_rdy;
    logic [PAIR_W-1:0]      host_wr_addr;
    logic [2*ARRAY_SIZE*DATA_WIDTH-1:0] host_wr_data;
    logic [ROW_W-1:0]       rd_row, rd_col;
    logic [ARRAY_SIZE*ACC_WIDTH-1:0] rd_row_data;
    logic [ACC_WIDTH-1:0]   rd_data;
    logic [31:0]            total_mac_cycles, skipped_mac_cycles;
    // This benchmark runs one GEMM per invocation (no K-tiling across
    // multiple accumulator slots), so always target slot 0.
    logic [1:0]              acc_slot = 2'b00;
    // No weight-reuse scheduling exercised here — every tile does a full load.
    logic                    reuse_weights = 1'b0;

    logic [DATA_WIDTH-1:0] A [MAX_N][MAX_N];
    logic [DATA_WIDTH-1:0] B [MAX_N][MAX_N];
    logic [DATA_WIDTH-1:0] tile_a [ARRAY_SIZE][ARRAY_SIZE];
    logic [DATA_WIDTH-1:0] tile_b [ARRAY_SIZE][ARRAY_SIZE];
    logic [ACC_WIDTH-1:0]  C_hw [MAX_N][MAX_N];
    logic [ACC_WIDTH-1:0]  C_ref[MAX_N][MAX_N];

    int bench_n;
    int sparse_percent;
    string mode;
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
    longint unsigned total_macs;
    longint unsigned total_ops;

    accel_top #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) dut (.*);

    initial clk = 0;
    always #2500 clk = ~clk;

    always_ff @(posedge clk) begin
        if (!rst_n)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    function automatic logic [DATA_WIDTH-1:0] dense_a(input int r, input int c);
        dense_a = DATA_WIDTH'(((r * 13 + c * 7 + 1) % 15) + 1);
    endfunction

    function automatic logic [DATA_WIDTH-1:0] dense_b(input int r, input int c);
        dense_b = DATA_WIDTH'(((r * 5 + c * 11 + 3) % 15) + 1);
    endfunction

    // Deterministic pseudo-random sparsity pattern. This keeps benchmark
    // results reproducible while avoiding a trivial all-zero block structure.
    function automatic bit make_sparse_zero(input int r, input int c, input int pct);
        int hash;
        begin
            hash = (r * 131 + c * 17 + r * c * 7) % 100;
            make_sparse_zero = (hash < pct);
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
            repeat (5) @(posedge clk);
            #(TB_SAMPLE_DELAY);
            for (int c = 0; c < ARRAY_SIZE; c++)
                C_hw[base_r + r][base_c + c] = rd_row_data[c*ACC_WIDTH +: ACC_WIDTH];
        end
        read_done_cycle = cycle_count;
        read_cycles += read_done_cycle - read_start_cycle;
    endtask

    // Executes one hardware 16x16 tile multiply. clear_tile is asserted for the
    // first K tile so the output buffer starts a new C tile; later K tiles
    // accumulate into the same output buffer entries.
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

    task init_matrices();
        for (int r = 0; r < MAX_N; r++) begin
            for (int c = 0; c < MAX_N; c++) begin
                if ((r < bench_n) && (c < bench_n)) begin
                    A[r][c] = make_sparse_zero(r, c, sparse_percent) ? '0 : dense_a(r, c);
                    B[r][c] = dense_b(r, c);
                end else begin
                    A[r][c] = '0;
                    B[r][c] = '0;
                end
                C_hw[r][c]  = '0;
                C_ref[r][c] = '0;
            end
        end
    endtask

    task compute_reference();
        logic [ACC_WIDTH-1:0] sum;
        for (int i = 0; i < bench_n; i++) begin
            for (int j = 0; j < bench_n; j++) begin
                sum = '0;
                for (int k = 0; k < bench_n; k++) begin
                    sum += ACC_WIDTH'(A[i][k]) * ACC_WIDTH'(B[k][j]);
                end
                C_ref[i][j] = sum;
            end
        end
    endtask

    task check_result();
        mismatches = 0;
        for (int i = 0; i < bench_n; i++) begin
            for (int j = 0; j < bench_n; j++) begin
                if (C_hw[i][j] !== C_ref[i][j]) begin
                    if (mismatches < 16) begin
                        $display("BENCH_MISMATCH C[%0d][%0d] got=%0d exp=%0d",
                                 i, j, C_hw[i][j], C_ref[i][j]);
                    end
                    mismatches++;
                end
            end
        end
    endtask

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

    initial begin
        bench_n = 64;
        mode = "dense";
        if (!$value$plusargs("N=%d", bench_n))
            bench_n = 64;
        if (!$value$plusargs("MODE=%s", mode))
            mode = "dense";

        if ((bench_n != 64) && (bench_n != 128) && (bench_n != 256)) begin
            $display("BENCH_FAIL N must be one of 64, 128, or 256. Got %0d", bench_n);
            $finish;
        end

        sparse_percent = parse_sparse_percent(mode);
        accel_cycles = 0;
        read_cycles = 0;
        tile_runs = 0;

        $display("=== accel tiled benchmark N=%0d MODE=%s ===", bench_n, mode);
        apply_reset();
        init_matrices();
        compute_reference();

        bench_start_cycle = cycle_count;
        for (int ti = 0; ti < bench_n / ARRAY_SIZE; ti++) begin
            for (int tj = 0; tj < bench_n / ARRAY_SIZE; tj++) begin
                for (int tk = 0; tk < bench_n / ARRAY_SIZE; tk++) begin
                    run_accel_tile(ti, tj, tk, tk == 0);
                end
                repeat (3 * ARRAY_SIZE) @(posedge clk);
                #(TB_SAMPLE_DELAY);
                read_final_tile(ti * ARRAY_SIZE, tj * ARRAY_SIZE);
            end
        end
        bench_end_cycle = cycle_count;

        check_result();

        total_macs = longint'(bench_n) * longint'(bench_n) * longint'(bench_n);
        total_ops = 2 * total_macs;

        $display("BENCH_RESULT status=%s", (mismatches == 0) ? "PASS" : "FAIL");
        $display("BENCH_RESULT n=%0d mode=%s tile_runs=%0d", bench_n, mode, tile_runs);
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
        $display("BENCH_RESULT mismatches=%0d", mismatches);

        if (mismatches == 0)
            $display("ALL BENCHMARK CHECKS PASSED");
        else
            $display("BENCHMARK CHECKS FAILED");
        $finish;
    end

endmodule
