`timescale 1ns/1ps

//------------------------------------------------------------------------------
// dma_ctrl_tb
//------------------------------------------------------------------------------
// Directed FSM testbench for dma_ctrl. The checks walk through a complete tile
// transaction and verify externally visible protocol signals at each phase:
// host write readiness, scratchpad write type, bank-swap pulse, weight preload
// address order, activation streaming order, drain latency, and done pulse.
//
// Timing reference (ARRAY_SIZE=4):
//   LOAD_WEIGHTS : 4 row writes
//   LOAD_ACTS    : 4 row writes; sp_bank_swap fires on the last one
//   PRELOAD_PE   : ARRAY_SIZE+1 cycles (phase 0..ARRAY_SIZE)
//                  phase 0         : weight_load_en=0, rd_weight_row=ARRAY_SIZE-1
//                  phase 1..N      : weight_load_en=1, rd_weight_row counts down
//   COMPUTE      : ARRAY_SIZE+1 cycles (same latency pattern for activations)
//   DRAIN        : 3*ARRAY_SIZE cycles; all enables low
//   ACCUMULATE   : 1 cycle; done=0
//   DONE         : 1 cycle; done=1  -> IDLE
//------------------------------------------------------------------------------

module dma_ctrl_tb;

    localparam int ARRAY_SIZE = 4;
    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;
    localparam int ROW_W      = $clog2(ARRAY_SIZE);       // 2

    // ------------------------------------------------------------------ ports
    logic                   clk, rst_n, start, done;
    logic                   host_wr_en, host_wr_rdy;
    logic [ROW_W-1:0]       host_wr_addr;
    logic [ARRAY_SIZE*DATA_WIDTH-1:0] host_wr_data;
    logic                   sp_wr_en, sp_wr_type, sp_bank_swap;
    logic [ROW_W-1:0]       sp_wr_addr;
    logic [ARRAY_SIZE*DATA_WIDTH-1:0] sp_wr_data;
    logic [ROW_W-1:0]       sp_rd_weight_row, sp_rd_act_row;
    logic                   weight_load_en, act_col_vld;

    dma_ctrl #(.ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;   // 100 MHz

    int pass_count = 0;
    int fail_count = 0;

    // ------------------------------------------------------------------
    task check(input string name, input logic got, input logic exp);
        if (got === exp) begin
            $display("PASS  %s", name);
            pass_count++;
        end else begin
            $display("FAIL  %s  got=%0b  exp=%0b", name, got, exp);
            fail_count++;
        end
    endtask

    task check_int(input string name, input int got, input int exp);
        if (got == exp) begin
            $display("PASS  %s  (=%0d)", name, got);
            pass_count++;
        end else begin
            $display("FAIL  %s  got=%0d  exp=%0d", name, got, exp);
            fail_count++;
        end
    endtask

    // ------------------------------------------------------------------
    task apply_reset();
        rst_n = 0; start = 0; host_wr_en = 0;
        host_wr_addr = '0; host_wr_data = '0;
        repeat (2) @(posedge clk);
        #1; rst_n = 1;
        @(posedge clk); #1;
    endtask

    // ------------------------------------------------------------------
    initial begin
        $display("=== dma_ctrl testbench  ARRAY_SIZE=%0d ===", ARRAY_SIZE);
        apply_reset();

        // ----------------------------------------------------------------
        // 1. After reset: all enables low, done=0, host_wr_rdy=0
        // ----------------------------------------------------------------
        check("reset: done=0",            done,           1'b0);
        check("reset: host_wr_rdy=0",     host_wr_rdy,    1'b0);
        check("reset: sp_wr_en=0",        sp_wr_en,       1'b0);
        check("reset: sp_bank_swap=0",    sp_bank_swap,   1'b0);
        check("reset: weight_load_en=0",  weight_load_en, 1'b0);
        check("reset: act_col_vld=0",     act_col_vld,    1'b0);

        // ----------------------------------------------------------------
        // 2. IDLE: no start → stays idle
        // ----------------------------------------------------------------
        @(posedge clk); #1;
        check("idle no start: host_wr_rdy=0", host_wr_rdy, 1'b0);

        // ----------------------------------------------------------------
        // 3. Start pulse → LOAD_WEIGHTS
        // ----------------------------------------------------------------
        start = 1; @(posedge clk); #1; start = 0;
        check("LOAD_WEIGHTS: host_wr_rdy=1",    host_wr_rdy,    1'b1);
        check("LOAD_WEIGHTS: done=0",            done,           1'b0);
        check("LOAD_WEIGHTS: weight_load_en=0",  weight_load_en, 1'b0);
        check("LOAD_WEIGHTS: sp_bank_swap=0",    sp_bank_swap,   1'b0);

        // ----------------------------------------------------------------
        // 4. LOAD_WEIGHTS: sp_wr_en mirrors host_wr_en; sp_wr_type forced to 0
        // ----------------------------------------------------------------
        // Drive host_wr_en=1, clock, then check after settling (#1)
        host_wr_en = 1; host_wr_addr = '0; host_wr_data = {ARRAY_SIZE{8'hAA}};
        @(posedge clk); #1;
        check("LOAD_WEIGHTS: sp_wr_en=1 (host_wr_en=1)", sp_wr_en,  1'b1);
        check("LOAD_WEIGHTS: sp_wr_type=0 (weight)",      sp_wr_type, 1'b0);
        check("LOAD_WEIGHTS: sp_bank_swap=0",              sp_bank_swap, 1'b0);
        host_wr_en = 0; @(posedge clk); #1;
        check("LOAD_WEIGHTS: sp_wr_en=0 (host_wr_en=0)", sp_wr_en, 1'b0);

        // Write remaining ARRAY_SIZE-2 rows (first was above; last handled below)
        for (int i = 1; i < ARRAY_SIZE - 1; i++) begin
            host_wr_en = 1; host_wr_addr = ROW_W'(i); host_wr_data = {ARRAY_SIZE{DATA_WIDTH'(i)}};
            @(posedge clk); #1; host_wr_en = 0;
        end

        // ----------------------------------------------------------------
        // 5. Last write of LOAD_WEIGHTS → no bank_swap, transitions to LOAD_ACTS
        // ----------------------------------------------------------------
        host_wr_en = 1; host_wr_addr = ROW_W'(ARRAY_SIZE-1); host_wr_data = {ARRAY_SIZE{8'hBB}};
        check("LOAD_WEIGHTS last: sp_bank_swap=0 (swap only on LOAD_ACTS)", sp_bank_swap, 1'b0);
        @(posedge clk); #1; host_wr_en = 0;

        check("LOAD_ACTS: host_wr_rdy=1",          host_wr_rdy, 1'b1);
        check("LOAD_ACTS: sp_wr_type=1 (act)",     sp_wr_type,  1'b1);

        // ----------------------------------------------------------------
        // 6. LOAD_ACTS: sp_wr_type=1 for all writes
        // ----------------------------------------------------------------
        host_wr_en = 1; host_wr_addr = '0; host_wr_data = {ARRAY_SIZE{8'hCC}};
        check("LOAD_ACTS first: sp_wr_type=1",    sp_wr_type,   1'b1);
        check("LOAD_ACTS first: sp_bank_swap=0",  sp_bank_swap, 1'b0);
        @(posedge clk); #1; host_wr_en = 0;

        // Write remaining ARRAY_SIZE-2 rows
        for (int i = 1; i < ARRAY_SIZE - 1; i++) begin
            host_wr_en = 1; host_wr_addr = ROW_W'(i); host_wr_data = {ARRAY_SIZE{DATA_WIDTH'(i + 20)}};
            @(posedge clk); #1; host_wr_en = 0;
        end

        // ----------------------------------------------------------------
        // 7. Last write of LOAD_ACTS → sp_bank_swap=1 (combinational, before clock)
        // ----------------------------------------------------------------
        host_wr_en = 1; host_wr_addr = ROW_W'(ARRAY_SIZE-1); host_wr_data = {ARRAY_SIZE{8'hDD}};
        check("LOAD_ACTS last: sp_bank_swap=1", sp_bank_swap, 1'b1);
        check("LOAD_ACTS last: sp_wr_type=1",   sp_wr_type,   1'b1);
        @(posedge clk); #1; host_wr_en = 0;

        // ----------------------------------------------------------------
        // 8. PRELOAD_PE entry (phase=0):
        //    weight_load_en=0 (data not yet valid), rd_weight_row=ARRAY_SIZE-1
        // ----------------------------------------------------------------
        check("PRELOAD_PE entry: sp_bank_swap=0",    sp_bank_swap,   1'b0);
        check("PRELOAD_PE entry: host_wr_rdy=0",     host_wr_rdy,    1'b0);
        check("PRELOAD_PE entry: weight_load_en=0",  weight_load_en, 1'b0);
        check("PRELOAD_PE entry: act_col_vld=0",     act_col_vld,    1'b0);
        check_int("PRELOAD_PE phase0: rd_weight_row=ARRAY_SIZE-1",
                  int'(sp_rd_weight_row), ARRAY_SIZE - 1);

        // Clock through PRELOAD_PE phases 1..ARRAY_SIZE
        // weight_load_en=1 throughout; rd_weight_row counts down ARRAY_SIZE-2 to 0
        for (int ph = 1; ph <= ARRAY_SIZE; ph++) begin
            @(posedge clk); #1;
            check("PRELOAD_PE: weight_load_en=1", weight_load_en, 1'b1);
            if (ph < ARRAY_SIZE) begin
                check_int($sformatf("PRELOAD_PE phase%0d: rd_weight_row", ph),
                          int'(sp_rd_weight_row), ARRAY_SIZE - 1 - ph);
            end
        end

        // One more clock to enter COMPUTE (phase_cnt=ARRAY_SIZE triggers transition)
        @(posedge clk); #1;

        // ----------------------------------------------------------------
        // 9. COMPUTE entry (phase=0):
        //    act_col_vld=0, weight_load_en=0, rd_act_row=0
        // ----------------------------------------------------------------
        check("COMPUTE entry: act_col_vld=0",    act_col_vld,    1'b0);
        check("COMPUTE entry: weight_load_en=0", weight_load_en, 1'b0);
        check("COMPUTE entry: host_wr_rdy=0",    host_wr_rdy,    1'b0);
        check_int("COMPUTE phase0: rd_act_row=0", int'(sp_rd_act_row), 0);

        // Clock through COMPUTE phases 1..ARRAY_SIZE
        // act_col_vld=1 throughout; rd_act_row counts up 1..ARRAY_SIZE-1
        for (int ph = 1; ph <= ARRAY_SIZE; ph++) begin
            @(posedge clk); #1;
            check("COMPUTE: act_col_vld=1", act_col_vld, 1'b1);
            if (ph < ARRAY_SIZE) begin
                check_int($sformatf("COMPUTE phase%0d: rd_act_row", ph),
                          int'(sp_rd_act_row), ph);
            end
        end

        // One more clock to enter DRAIN
        @(posedge clk); #1;

        // ----------------------------------------------------------------
        // 10. DRAIN: all enables low, runs 3*ARRAY_SIZE cycles
        // ----------------------------------------------------------------
        check("DRAIN entry: act_col_vld=0",    act_col_vld,    1'b0);
        check("DRAIN entry: weight_load_en=0", weight_load_en, 1'b0);
        check("DRAIN entry: host_wr_rdy=0",    host_wr_rdy,    1'b0);

        // Clock through remaining DRAIN cycles (already checked cycle 0 above)
        for (int i = 1; i <= 3 * ARRAY_SIZE; i++) @(posedge clk);
        #1;
        check("DRAIN last: act_col_vld=0",    act_col_vld,    1'b0);
        check("DRAIN last: weight_load_en=0", weight_load_en, 1'b0);

        // ----------------------------------------------------------------
        // 11. ACCUMULATE → DONE → IDLE
        // ----------------------------------------------------------------
        @(posedge clk); #1;
        check("ACCUMULATE: done=0",        done,        1'b0);
        check("ACCUMULATE: act_col_vld=0", act_col_vld, 1'b0);

        @(posedge clk); #1;
        check("DONE: done=1",           done,        1'b1);
        check("DONE: host_wr_rdy=0",    host_wr_rdy, 1'b0);

        @(posedge clk); #1;
        check("IDLE: done=0",           done,        1'b0);
        check("IDLE: host_wr_rdy=0",    host_wr_rdy, 1'b0);
        check("IDLE: act_col_vld=0",    act_col_vld, 1'b0);
        check("IDLE: weight_load_en=0", weight_load_en, 1'b0);

        // ----------------------------------------------------------------
        // 12. Re-trigger: start again from IDLE
        // ----------------------------------------------------------------
        start = 1; @(posedge clk); #1; start = 0;
        check("re-trigger: host_wr_rdy=1", host_wr_rdy, 1'b1);
        check("re-trigger: sp_wr_type=0",  sp_wr_type,  1'b0);
        check("re-trigger: done=0",        done,        1'b0);

        // ----------------------------------------------------------------
        $display("=== Results: %0d passed  %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("SOME TESTS FAILED");
        $finish;
    end

endmodule
