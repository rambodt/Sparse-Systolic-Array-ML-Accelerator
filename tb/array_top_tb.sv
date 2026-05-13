`timescale 1ns/1ps

// Timing relationship (derived from pipeline trace):
//   At streaming tick S (1-indexed from first act_col_in presentation):
//     psum_out_row[c] = C[t][c]  where  S = t + c + ARRAY_SIZE + 1
//
// Weight preload order (reverse rows so shift chain lands correctly):
//   Preload cycle k (0-indexed):  weight_load_in[col] = B[ARRAY_SIZE-1-k][col]
//   After ARRAY_SIZE preload cycles: PE[r][col].weight_r = B[r][col]

module array_top_tb;

    localparam int ARRAY_SIZE = 4;
    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;

    // Total streaming ticks needed to drain last output:
    // Last output C[ARRAY_SIZE-1][ARRAY_SIZE-1] at S = (ARRAY_SIZE-1)+(ARRAY_SIZE-1)+ARRAY_SIZE+1 = 3*ARRAY_SIZE-1
    localparam int TOTAL_TICKS = 3*ARRAY_SIZE - 1;

    // ------------------------------------------------------------------ ports
    logic                   clk;
    logic                   rst_n;
    logic [DATA_WIDTH-1:0]  act_col_in    [ARRAY_SIZE];
    logic                   act_col_vld;
    logic [DATA_WIDTH-1:0]  weight_load_in [ARRAY_SIZE];
    logic                   weight_load_en;
    logic [ARRAY_SIZE-1:0]  skip_en_col;
    logic [ACC_WIDTH-1:0]   psum_out_row  [ARRAY_SIZE];
    logic                   psum_out_vld;

    array_top #(.ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;

    int pass_count = 0;
    int fail_count = 0;

    // ------------------------------------------------------------------
    task apply_reset();
        rst_n          = 0;
        act_col_vld    = 0;
        weight_load_en = 0;
        skip_en_col    = '0;
        for (int i = 0; i < ARRAY_SIZE; i++) begin
            act_col_in[i]      = '0;
            weight_load_in[i]  = '0;
        end
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;
    endtask

    // Preload weights: reverse row order so shift chain places B[r][c] in PE[r][c]
    task preload_weights(input logic [DATA_WIDTH-1:0] B [ARRAY_SIZE][ARRAY_SIZE]);
        weight_load_en = 1;
        for (int k = 0; k < ARRAY_SIZE; k++) begin
            for (int c = 0; c < ARRAY_SIZE; c++)
                weight_load_in[c] = B[ARRAY_SIZE-1-k][c];
            @(posedge clk); #1;
        end
        weight_load_en = 0;
        for (int c = 0; c < ARRAY_SIZE; c++) weight_load_in[c] = '0;
    endtask

    // Stream A and capture full C = A×B result
    // At tick S (1-indexed): psum_out_row[c] = C[t][c] where S = t+c+ARRAY_SIZE+1
    task stream_and_capture(
        input  logic [DATA_WIDTH-1:0] A [ARRAY_SIZE][ARRAY_SIZE],
        output logic [ACC_WIDTH-1:0]  C [ARRAY_SIZE][ARRAY_SIZE]
    );
        for (int c = 0; c < ARRAY_SIZE; c++)
            for (int r = 0; r < ARRAY_SIZE; r++)
                C[r][c] = '0;

        act_col_vld = 1;

        for (int S = 1; S <= TOTAL_TICKS; S++) begin
            // Present row (S-1) of A if still within streaming window
            if (S <= ARRAY_SIZE) begin
                for (int r = 0; r < ARRAY_SIZE; r++)
                    act_col_in[r] = A[S-1][r];
            end else begin
                act_col_vld = 0;
                for (int r = 0; r < ARRAY_SIZE; r++)
                    act_col_in[r] = '0;
            end

            @(posedge clk); #1;

            // Capture: S = t + c + ARRAY_SIZE + 1 → t = S - c - ARRAY_SIZE - 1
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                automatic int t = S - c - ARRAY_SIZE - 1;
                if (t >= 0 && t < ARRAY_SIZE)
                    C[t][c] = psum_out_row[c];
            end
        end

        act_col_vld = 0;
    endtask

    // Golden model: C[i][j] = sum_k A[i][k] * B[k][j]
    function automatic logic [ACC_WIDTH-1:0] golden
        (input logic [DATA_WIDTH-1:0] A [ARRAY_SIZE][ARRAY_SIZE],
         input logic [DATA_WIDTH-1:0] B [ARRAY_SIZE][ARRAY_SIZE],
         input int row, col);
        automatic logic [ACC_WIDTH-1:0] s = '0;
        for (int k = 0; k < ARRAY_SIZE; k++)
            s += ACC_WIDTH'(A[row][k]) * ACC_WIDTH'(B[k][col]);
        return s;
    endfunction

    task check_matrix(
        input string test_name,
        input logic [ACC_WIDTH-1:0] got      [ARRAY_SIZE][ARRAY_SIZE],
        input logic [DATA_WIDTH-1:0] A [ARRAY_SIZE][ARRAY_SIZE],
        input logic [DATA_WIDTH-1:0] B [ARRAY_SIZE][ARRAY_SIZE]
    );
        automatic int ok = 1;
        for (int i = 0; i < ARRAY_SIZE; i++)
            for (int j = 0; j < ARRAY_SIZE; j++) begin
                automatic logic [ACC_WIDTH-1:0] exp = golden(A, B, i, j);
                if (got[i][j] !== exp) begin
                    $display("FAIL  %s  C[%0d][%0d]  got=%0d  expected=%0d",
                             test_name, i, j, got[i][j], exp);
                    ok = 0;
                    fail_count++;
                end
            end
        if (ok) begin
            $display("PASS  %s", test_name);
            pass_count++;
        end
    endtask

    // ------------------------------------------------------------------ test data
    logic [DATA_WIDTH-1:0] A [ARRAY_SIZE][ARRAY_SIZE];
    logic [DATA_WIDTH-1:0] B [ARRAY_SIZE][ARRAY_SIZE];
    logic [ACC_WIDTH-1:0]  C [ARRAY_SIZE][ARRAY_SIZE];

    initial begin
        $display("=== array_top testbench (ARRAY_SIZE=%0d) ===", ARRAY_SIZE);

        // ---------------------------------------------------
        // TEST 1: Identity A × B = B
        // ---------------------------------------------------
        apply_reset();
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                A[r][c] = (r == c) ? 8'd1 : 8'd0;
                B[r][c] = DATA_WIDTH'(r * ARRAY_SIZE + c + 1);
            end
        preload_weights(B);
        stream_and_capture(A, C);
        check_matrix("identity A × B = B", C, A, B);

        // ---------------------------------------------------
        // TEST 2: All-ones A × All-ones B → every entry = ARRAY_SIZE
        // ---------------------------------------------------
        apply_reset();
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                A[r][c] = 8'd1;
                B[r][c] = 8'd1;
            end
        preload_weights(B);
        stream_and_capture(A, C);
        check_matrix("all-ones A × all-ones B", C, A, B);

        // ---------------------------------------------------
        // TEST 3: All-zero A → C = 0 (100% sparsity)
        // ---------------------------------------------------
        apply_reset();
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                A[r][c] = 8'd0;
                B[r][c] = 8'd7;
            end
        preload_weights(B);
        stream_and_capture(A, C);
        check_matrix("zero A × B = 0", C, A, B);

        // ---------------------------------------------------
        // TEST 4: A × Identity B = A
        // ---------------------------------------------------
        apply_reset();
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                A[r][c] = DATA_WIDTH'(r * ARRAY_SIZE + c + 1);
                B[r][c] = (r == c) ? 8'd1 : 8'd0;
            end
        preload_weights(B);
        stream_and_capture(A, C);
        check_matrix("A × identity B = A", C, A, B);

        // ---------------------------------------------------
        // TEST 5: Random-ish known values
        // A[r][c] = r+1, B[r][c] = c+1 → C[i][j] = (j+1)*sum_k(A[i][k])
        // ---------------------------------------------------
        apply_reset();
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                A[r][c] = DATA_WIDTH'(r + 1);
                B[r][c] = DATA_WIDTH'(c + 1);
            end
        preload_weights(B);
        stream_and_capture(A, C);
        check_matrix("A[r][c]=r+1  B[r][c]=c+1", C, A, B);

        // ---------------------------------------------------
        $display("=== Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("SOME TESTS FAILED");
        $finish;
    end

endmodule
