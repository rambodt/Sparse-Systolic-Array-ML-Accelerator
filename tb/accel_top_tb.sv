`timescale 1ns/1ps

// End-to-end integration test for accel_top.
// Flow per test:
//   1. Assert start (clears output buffer, DMA → LOAD_WEIGHTS)
//   2. write_tile(B) — stream weight words while host_wr_rdy=1
//   3. write_tile(A) — stream activation rows
//   4. DMA runs PRELOAD_PE → COMPUTE → DRAIN → ACCUMULATE → DONE autonomously
//   5. Poll done, then read output buffer and compare to golden C = A×B

module accel_top_tb;
    timeunit 1ps;
    timeprecision 1ps;

    localparam int ARRAY_SIZE = 16;
    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;
    localparam int ROW_W      = $clog2(ARRAY_SIZE);        // 4
    localparam time TB_SAMPLE_DELAY = 2000ps;

    // ------------------------------------------------------------------ ports
    logic                   clk, rst_n, start, clear_accum, done;
    logic                   host_wr_en, host_wr_rdy;
    logic [ROW_W-1:0]       host_wr_addr;
    logic [ARRAY_SIZE*DATA_WIDTH-1:0] host_wr_data;
    logic [ROW_W-1:0]       rd_row, rd_col;
    logic [ARRAY_SIZE*ACC_WIDTH-1:0] rd_row_data;
    logic [ACC_WIDTH-1:0]   rd_data;
    logic [31:0]            total_mac_cycles, skipped_mac_cycles;

    accel_top #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) dut (.*);

    initial clk = 0;
    always #2500 clk = ~clk;   // 5 ns period, matching the ASIC constraint

    int pass_count = 0;
    int fail_count = 0;

    // ------------------------------------------------------------------
    task apply_reset();
        rst_n = 0; start = 0; clear_accum = 0; host_wr_en = 0;
        host_wr_addr = '0; host_wr_data = '0;
        rd_row = '0; rd_col = '0;
        repeat (2) @(posedge clk);
        @(negedge clk); rst_n = 1;
        @(posedge clk);
    endtask

    // Write ARRAY_SIZE rows back-to-back (host_wr_en stays high throughout).
    // Waits for host_wr_rdy before starting — safe to call immediately after start.
    // Memory layout: addr = row*ARRAY_SIZE + col → data[row][col]
    task write_tile(input logic [DATA_WIDTH-1:0] data [ARRAY_SIZE][ARRAY_SIZE]);
        while (!host_wr_rdy) begin @(posedge clk); end
        @(negedge clk);
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            host_wr_en   = 1;
            host_wr_addr = ROW_W'(r);
            for (int c = 0; c < ARRAY_SIZE; c++)
                host_wr_data[c*DATA_WIDTH +: DATA_WIDTH] = data[r][c];
            @(posedge clk);
            @(negedge clk);
        end
        host_wr_en = 0;
    endtask

    // Poll done with a cycle timeout.
    task wait_done(input int timeout);
        for (int i = 0; i < timeout; i++) begin
            if (done) return;
            @(posedge clk);
        end
        $display("FAIL  TIMEOUT: done never asserted after %0d cycles", timeout);
        fail_count++;
    endtask

    // Golden model: C[i][j] = sum_k A[i][k] * B[k][j]
    function automatic logic [ACC_WIDTH-1:0] golden(
        input logic [DATA_WIDTH-1:0] A [ARRAY_SIZE][ARRAY_SIZE],
        input logic [DATA_WIDTH-1:0] B [ARRAY_SIZE][ARRAY_SIZE],
        input int row, col);
        automatic logic [ACC_WIDTH-1:0] s = '0;
        for (int k = 0; k < ARRAY_SIZE; k++)
            s += ACC_WIDTH'(A[row][k]) * ACC_WIDTH'(B[k][col]);
        return s;
    endfunction

    // Read output buffer and compare every element to golden model.
    task check_result(
        input string                  test_name,
        input logic [DATA_WIDTH-1:0]  A [ARRAY_SIZE][ARRAY_SIZE],
        input logic [DATA_WIDTH-1:0]  B [ARRAY_SIZE][ARRAY_SIZE]);
        automatic int ok = 1;
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                automatic logic [ACC_WIDTH-1:0] exp_val = golden(A, B, r, c);
                @(negedge clk);
                rd_row = ROW_W'(r);
                rd_col = ROW_W'(c);
                repeat (5) @(posedge clk);
                #(TB_SAMPLE_DELAY);   // sample after post-route output delay settles
                if (rd_data !== exp_val) begin
                    $display("FAIL  %s  C[%0d][%0d]  got=%0d  exp=%0d",
                             test_name, r, c, rd_data, exp_val);
                    ok = 0;
                    fail_count++;
                end
            end
        end
        if (ok) begin
            $display("PASS  %s", test_name);
            pass_count++;
        end
    endtask

    // Full GEMM run: start → write tiles → wait done → check.
    task run_gemm(
        input string                 test_name,
        input logic [DATA_WIDTH-1:0] A [ARRAY_SIZE][ARRAY_SIZE],
        input logic [DATA_WIDTH-1:0] B [ARRAY_SIZE][ARRAY_SIZE]);
        @(negedge clk);
        clear_accum = 1;
        start = 1;
        @(posedge clk);
        @(negedge clk);
        start = 0;
        clear_accum = 0;
        write_tile(B);   // LOAD_WEIGHTS
        write_tile(A);   // LOAD_ACTS
        wait_done(200);
        repeat (3 * ARRAY_SIZE) @(posedge clk);
        #(TB_SAMPLE_DELAY);
        check_result(test_name, A, B);
    endtask

    // ------------------------------------------------------------------ matrices
    logic [DATA_WIDTH-1:0] A [ARRAY_SIZE][ARRAY_SIZE];
    logic [DATA_WIDTH-1:0] B [ARRAY_SIZE][ARRAY_SIZE];

    // ------------------------------------------------------------------
    initial begin
        $display("=== accel_top integration testbench  ARRAY_SIZE=%0d ===", ARRAY_SIZE);
        apply_reset();

        // -------------------------------------------------------
        // TEST 1: Identity A × B = B
        // -------------------------------------------------------
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                A[r][c] = (r == c) ? 8'd1 : 8'd0;
                B[r][c] = DATA_WIDTH'(r * ARRAY_SIZE + c + 1);
            end
        run_gemm("identity A × B = B", A, B);

        // -------------------------------------------------------
        // TEST 2: All-ones × All-ones → every entry = ARRAY_SIZE
        // -------------------------------------------------------
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                A[r][c] = 8'd1;
                B[r][c] = 8'd1;
            end
        run_gemm("all-ones × all-ones", A, B);

        // -------------------------------------------------------
        // TEST 3: Zero A × B = 0  (100% sparsity)
        // -------------------------------------------------------
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                A[r][c] = 8'd0;
                B[r][c] = 8'd7;
            end
        run_gemm("zero A × B = 0", A, B);

        // -------------------------------------------------------
        // TEST 4: A × Identity B = A
        // -------------------------------------------------------
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                A[r][c] = DATA_WIDTH'(r * ARRAY_SIZE + c + 1);
                B[r][c] = (r == c) ? 8'd1 : 8'd0;
            end
        run_gemm("A × identity B = A", A, B);

        // -------------------------------------------------------
        // TEST 5: A[r][c]=r+1  B[r][c]=c+1
        //         C[i][j] = (j+1) * ARRAY_SIZE*(i+1)
        // -------------------------------------------------------
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                A[r][c] = DATA_WIDTH'(r + 1);
                B[r][c] = DATA_WIDTH'(c + 1);
            end
        run_gemm("A[r][c]=r+1  B[r][c]=c+1", A, B);

        // -------------------------------------------------------
        $display("=== Results: %0d passed  %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("SOME TESTS FAILED");
        $finish;
    end

endmodule
