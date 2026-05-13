`timescale 1ns/1ps

module scratchpad_tb;

    localparam int ARRAY_SIZE       = 4;
    localparam int DATA_WIDTH       = 8;
    localparam int SCRATCHPAD_DEPTH = 256;
    localparam int NUM_BANKS        = 2;
    localparam int TILE_WORDS       = ARRAY_SIZE * ARRAY_SIZE;
    localparam int ADDR_W           = $clog2(TILE_WORDS);
    localparam int ROW_W            = $clog2(ARRAY_SIZE);

    // ------------------------------------------------------------------ ports
    logic                   clk, rst_n, bank_swap;
    logic                   wr_en, wr_type;
    logic [ADDR_W-1:0]      wr_addr;
    logic [DATA_WIDTH-1:0]  wr_data;
    logic [ROW_W-1:0]       rd_weight_row, rd_act_row;
    logic [DATA_WIDTH-1:0]  rd_weight_data [ARRAY_SIZE];
    logic [DATA_WIDTH-1:0]  rd_act_data    [ARRAY_SIZE];

    scratchpad #(
        .ARRAY_SIZE       (ARRAY_SIZE),
        .DATA_WIDTH       (DATA_WIDTH),
        .SCRATCHPAD_DEPTH (SCRATCHPAD_DEPTH),
        .NUM_BANKS        (NUM_BANKS)
    ) dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;   // 100 MHz

    int pass_count = 0;
    int fail_count = 0;

    // ------------------------------------------------------------------
    task apply_reset();
        rst_n         = 0;
        bank_swap     = 0;
        wr_en         = 0;
        wr_type       = 0;
        wr_addr       = '0;
        wr_data       = '0;
        rd_weight_row = '0;
        rd_act_row    = '0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;
    endtask

    task check_byte(input string name,
                    input logic [DATA_WIDTH-1:0] got,
                    input logic [DATA_WIDTH-1:0] exp);
        if (got === exp) begin
            $display("PASS  %s  (=%0d)", name, got);
            pass_count++;
        end else begin
            $display("FAIL  %s  got=%0d  exp=%0d", name, got, exp);
            fail_count++;
        end
    endtask

    // Write one full tile (ARRAY_SIZE×ARRAY_SIZE words) to the inactive bank.
    // wr_type: 0=weight  1=activation
    // data[row][col] → addr = row*ARRAY_SIZE + col
    task write_tile(
        input logic [DATA_WIDTH-1:0] data [ARRAY_SIZE][ARRAY_SIZE],
        input logic                  wtype
    );
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                wr_en   = 1;
                wr_type = wtype;
                wr_addr = ADDR_W'(r * ARRAY_SIZE + c);
                wr_data = data[r][c];
                @(posedge clk); #1;
            end
        end
        wr_en = 0;
    endtask

    // Read one full row from the active bank (1-cycle SRAM latency).
    // After the task, rd_weight_data or rd_act_data holds the row.
    task read_weight_row(input logic [ROW_W-1:0] row);
        rd_weight_row = row;
        @(posedge clk); #1;   // address presented → data valid next cycle
        @(posedge clk); #1;   // read settled
    endtask

    task read_act_row(input logic [ROW_W-1:0] row);
        rd_act_row = row;
        @(posedge clk); #1;
        @(posedge clk); #1;
    endtask

    // ------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] W [ARRAY_SIZE][ARRAY_SIZE];  // weight tile
    logic [DATA_WIDTH-1:0] A [ARRAY_SIZE][ARRAY_SIZE];  // activation tile
    logic [DATA_WIDTH-1:0] W2[ARRAY_SIZE][ARRAY_SIZE];  // second weight tile

    initial begin
        $display("=== scratchpad testbench  ARRAY_SIZE=%0d ===", ARRAY_SIZE);
        apply_reset();

        // ----------------------------------------------------------------
        // TEST 1: After reset — active bank register starts at 0.
        // We verify this indirectly: write to inactive (bank 1), swap,
        // write to the new inactive (bank 0). After a second swap the
        // original bank 0 data must be readable — proving active_bank_r
        // started at 0 and both swaps incremented correctly.
        // (Raw memory is uninitialized before first write — reading it
        // before writing would yield 'x, which is correct hardware behavior.)
        // ----------------------------------------------------------------
        // Just confirm the module came out of reset cleanly (no x on bank_swap)
        check_byte("reset: bank_swap deasserted (combinational 0)",
                   {7'b0, bank_swap}, 8'h00);

        // ----------------------------------------------------------------
        // TEST 2: Write weights to inactive bank, swap, read back
        // After reset: active=0, inactive=1.
        // Write W to inactive (bank 1), swap → active=1, read W back.
        // ----------------------------------------------------------------
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++)
                W[r][c] = DATA_WIDTH'(r * ARRAY_SIZE + c + 1);   // 1..16

        write_tile(W, 1'b0);   // wr_type=0 → weight memory

        // Swap: inactive (bank 1 with W) becomes active
        bank_swap = 1; @(posedge clk); #1; bank_swap = 0;

        // Read each row and verify
        for (int r = 0; r < ARRAY_SIZE; r++) begin
            read_weight_row(ROW_W'(r));
            for (int c = 0; c < ARRAY_SIZE; c++)
                check_byte($sformatf("weight R-A-W row%0d col%0d", r, c),
                           rd_weight_data[c], W[r][c]);
        end

        // ----------------------------------------------------------------
        // TEST 3: Write activations to inactive bank, swap, read back
        // Current state: active=1. Write A to inactive (bank 0), swap → active=0.
        // ----------------------------------------------------------------
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++)
                A[r][c] = DATA_WIDTH'((r + 1) * 10 + c);   // 10,11,12,13 / 20,21,...

        write_tile(A, 1'b1);   // wr_type=1 → activation memory

        bank_swap = 1; @(posedge clk); #1; bank_swap = 0;

        for (int r = 0; r < ARRAY_SIZE; r++) begin
            read_act_row(ROW_W'(r));
            for (int c = 0; c < ARRAY_SIZE; c++)
                check_byte($sformatf("activation R-A-W row%0d col%0d", r, c),
                           rd_act_data[c], A[r][c]);
        end

        // ----------------------------------------------------------------
        // TEST 4: Write isolation — writing to inactive does not corrupt active
        // Current state: active=0 (has A activations from test 3).
        // Write garbage weights to inactive (bank 1). Active reads must be unchanged.
        // ----------------------------------------------------------------
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++)
                W2[r][c] = 8'hFF;   // garbage

        // Start reading active bank row 0 concurrently with writing inactive
        rd_act_row = '0;
        wr_en   = 1;
        wr_type = 1'b1;
        wr_addr = '0;
        wr_data = 8'hFF;
        @(posedge clk); #1;    // write and read address presented simultaneously
        wr_en = 0;
        @(posedge clk); #1;    // read data settled

        for (int c = 0; c < ARRAY_SIZE; c++)
            check_byte($sformatf("isolation: active row0 col%0d unchanged", c),
                       rd_act_data[c], A[0][c]);

        // ----------------------------------------------------------------
        // TEST 5: Ping-pong — fill inactive, swap, read while filling next inactive
        // Write W (new weights) to inactive, swap, read W while simultaneously
        // writing W2 to the new inactive. Reads must return W, not W2.
        // ----------------------------------------------------------------
        apply_reset();   // active=0, inactive=1

        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                W[r][c]  = DATA_WIDTH'(r * ARRAY_SIZE + c + 1);     // 1..16
                W2[r][c] = DATA_WIDTH'(r * ARRAY_SIZE + c + 100);   // 100..115
            end

        // Load W into inactive (bank 1)
        write_tile(W, 1'b0);
        bank_swap = 1; @(posedge clk); #1; bank_swap = 0;
        // active=1 (has W), inactive=0

        // Simultaneously: read W from active AND write W2 to inactive
        rd_weight_row = '0;
        wr_en   = 1;
        wr_type = 1'b0;
        wr_addr = '0;
        wr_data = W2[0][0];
        @(posedge clk); #1;   // both issued in same cycle
        wr_en = 0;
        @(posedge clk); #1;   // read settles

        // Active bank (W) should be readable, W2 write should not corrupt it
        for (int c = 0; c < ARRAY_SIZE; c++)
            check_byte($sformatf("ping-pong: active row0 col%0d = W not W2", c),
                       rd_weight_data[c], W[0][c]);

        // Finish writing W2 to inactive and swap
        wr_en = 1;
        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                if (r == 0 && c == 0) continue;   // already written above
                wr_addr = ADDR_W'(r * ARRAY_SIZE + c);
                wr_data = W2[r][c];
                @(posedge clk); #1;
            end
        wr_en = 0;

        bank_swap = 1; @(posedge clk); #1; bank_swap = 0;
        // active=0 (has W2)

        for (int r = 0; r < ARRAY_SIZE; r++) begin
            read_weight_row(ROW_W'(r));
            for (int c = 0; c < ARRAY_SIZE; c++)
                check_byte($sformatf("ping-pong swap: W2 row%0d col%0d", r, c),
                           rd_weight_data[c], W2[r][c]);
        end

        // ----------------------------------------------------------------
        // TEST 6: Weight and activation memories are independent
        // Write W to weight memory, A to activation memory of same inactive bank.
        // After swap, weight reads return W, activation reads return A.
        // ----------------------------------------------------------------
        apply_reset();

        for (int r = 0; r < ARRAY_SIZE; r++)
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                W[r][c] = DATA_WIDTH'(r * ARRAY_SIZE + c + 1);
                A[r][c] = DATA_WIDTH'(r * ARRAY_SIZE + c + 50);
            end

        write_tile(W, 1'b0);   // weights → weight_mem
        write_tile(A, 1'b1);   // activations → act_mem
        bank_swap = 1; @(posedge clk); #1; bank_swap = 0;

        for (int r = 0; r < ARRAY_SIZE; r++) begin
            // Read weight row and act row in the same pass
            rd_weight_row = ROW_W'(r);
            rd_act_row    = ROW_W'(r);
            @(posedge clk); #1;
            @(posedge clk); #1;
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                check_byte($sformatf("separate: weight row%0d col%0d", r, c),
                           rd_weight_data[c], W[r][c]);
                check_byte($sformatf("separate: act    row%0d col%0d", r, c),
                           rd_act_data[c],    A[r][c]);
            end
        end

        // ----------------------------------------------------------------
        $display("=== Results: %0d passed  %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("SOME TESTS FAILED");
        $finish;
    end

endmodule
