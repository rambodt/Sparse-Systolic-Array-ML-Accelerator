`timescale 1ns/1ps

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
    localparam time TB_SAMPLE_DELAY = 2000ps;
    localparam longint unsigned CLK_PERIOD_PS = 5000;

    logic                   clk, rst_n, start, clear_accum, done;
    logic                   host_wr_en, host_wr_rdy;
    logic [ROW_W-1:0]       host_wr_addr;
    logic [ARRAY_SIZE*DATA_WIDTH-1:0] host_wr_data;
    logic [ROW_W-1:0]       rd_row, rd_col;
    logic [ARRAY_SIZE*ACC_WIDTH-1:0] rd_row_data;
    logic [ACC_WIDTH-1:0]   rd_data;
    logic [31:0]            total_mac_cycles, skipped_mac_cycles;

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

    function automatic bit make_sparse_zero(input int r, input int c, input int pct);
        int hash;
        begin
            hash = (r * 131 + c * 17 + r * c * 7) % 100;
            make_sparse_zero = (hash < pct);
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

    task write_tile(input logic [DATA_WIDTH-1:0] data [ARRAY_SIZE][ARRAY_SIZE]);
        while (!host_wr_rdy) begin
            @(posedge clk);
        end
        @(negedge clk);
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            host_wr_en   = 1'b1;
            host_wr_addr = ROW_W'(r);
            for (int c = 0; c < ARRAY_SIZE; c++)
                host_wr_data[c*DATA_WIDTH +: DATA_WIDTH] = data[r][c];
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
        for (int r = 0; r < bench_m; r++)
            for (int c = 0; c < bench_k; c++)
                A[r][c] = !make_sparse_zero(r, c, sparse_percent) ? dense_a(r, c) : '0;

        for (int r = 0; r < bench_k; r++)
            for (int c = 0; c < bench_n; c++)
                B[r][c] = dense_b(r, c);

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

    initial begin
        mode = "dense";
        if (!$value$plusargs("MODE=%s", mode))
            mode = "dense";
        check_mode = "full";
        if (!$value$plusargs("CHECK=%s", check_mode))
            check_mode = "full";
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
        for (int ti = 0; ti < bench_m / ARRAY_SIZE; ti++) begin
            for (int tj = 0; tj < bench_n / ARRAY_SIZE; tj++) begin
                for (int tk = 0; tk < bench_k / ARRAY_SIZE; tk++)
                    run_accel_tile(ti, tj, tk, tk == 0);
                repeat (3 * ARRAY_SIZE) @(posedge clk);
                #(TB_SAMPLE_DELAY);
                read_final_tile(ti * ARRAY_SIZE, tj * ARRAY_SIZE);
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
