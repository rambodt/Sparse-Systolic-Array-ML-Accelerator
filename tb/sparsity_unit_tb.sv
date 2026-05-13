`timescale 1ns/1ps

// Directed testbench for sparsity_unit.
// skip_en_col[r] is staggered: a zero in act_in[r] at cycle T
// produces skip_en_col[r]=1 exactly r+1 cycles later (same delay
// as the array_top activation stagger).

module sparsity_unit_tb;

    localparam int ARRAY_SIZE = 4;
    localparam int DATA_WIDTH = 8;

    logic                   clk, rst_n, clear, act_col_vld;
    logic [DATA_WIDTH-1:0]  act_in  [ARRAY_SIZE];
    logic [DATA_WIDTH-1:0]  act_out [ARRAY_SIZE];
    logic [ARRAY_SIZE-1:0]  skip_en_col;
    logic [31:0]            total_mac_cycles, skipped_mac_cycles;

    sparsity_unit #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .DATA_WIDTH (DATA_WIDTH)
    ) dut (.*);

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
        rst_n = 0; clear = 0; act_col_vld = 0;
        for (int i = 0; i < ARRAY_SIZE; i++) act_in[i] = '0;
        repeat (2) @(posedge clk);
        #1; rst_n = 1;
        @(posedge clk); #1;
    endtask

    // ------------------------------------------------------------------
    initial begin
        $display("=== sparsity_unit testbench  ARRAY_SIZE=%0d ===", ARRAY_SIZE);
        apply_reset();

        // ----------------------------------------------------------------
        // 1. After reset: counters = 0, all skip_en low
        // ----------------------------------------------------------------
        act_col_vld = 0;
        for (int i = 0; i < ARRAY_SIZE; i++) act_in[i] = DATA_WIDTH'(i + 1);
        #1;
        check_int("reset: total_mac_cycles=0",   int'(total_mac_cycles),   0);
        check_int("reset: skipped_mac_cycles=0", int'(skipped_mac_cycles), 0);
        for (int i = 0; i < ARRAY_SIZE; i++)
            check($sformatf("reset: skip_en_col[%0d]=0", i), skip_en_col[i], 1'b0);

        // ----------------------------------------------------------------
        // 2. Pass-through: act_out must equal act_in (combinational)
        // ----------------------------------------------------------------
        for (int i = 0; i < ARRAY_SIZE; i++) act_in[i] = DATA_WIDTH'(i * 10 + 5);
        #1;
        for (int i = 0; i < ARRAY_SIZE; i++)
            if (act_out[i] !== act_in[i]) begin
                $display("FAIL  pass-through[%0d]  got=%0d  exp=%0d", i, act_out[i], act_in[i]);
                fail_count++;
            end else begin
                $display("PASS  pass-through[%0d]=%0d", i, act_out[i]);
                pass_count++;
            end

        // ----------------------------------------------------------------
        // 3. act_col_vld=0: skip_en stays low even with zero act_in
        //    (stagger registers are reset → skip_staggered stays 0)
        // ----------------------------------------------------------------
        act_col_vld = 0;
        for (int i = 0; i < ARRAY_SIZE; i++) act_in[i] = '0;
        @(posedge clk); #1;
        for (int i = 0; i < ARRAY_SIZE; i++)
            check($sformatf("vld=0: skip_en_col[%0d]=0 with zeros", i),
                  skip_en_col[i], 1'b0);
        check_int("vld=0: total=0", int'(total_mac_cycles), 0);

        // ----------------------------------------------------------------
        // 4. All-nonzero: no skip, counter increments by ARRAY_SIZE each cycle.
        //    Drive ARRAY_SIZE cycles of nonzero data and verify counter.
        // ----------------------------------------------------------------
        for (int i = 0; i < ARRAY_SIZE; i++) act_in[i] = DATA_WIDTH'(i + 1);
        act_col_vld = 1;
        repeat (ARRAY_SIZE) @(posedge clk);
        act_col_vld = 0; #1;
        check_int("nonzero: total after N cycles",
                  int'(total_mac_cycles), ARRAY_SIZE * ARRAY_SIZE);
        check_int("nonzero: skipped=0", int'(skipped_mac_cycles), 0);
        // All skip_en should still be 0 (nonzero acts)
        for (int i = 0; i < ARRAY_SIZE; i++)
            check($sformatf("nonzero: skip_en_col[%0d]=0", i), skip_en_col[i], 1'b0);

        // ----------------------------------------------------------------
        // 5. Stagger test: apply one cycle of all-zero acts with vld=1.
        //    skip_staggered[r] should go high exactly r+1 cycles later.
        //    Pattern: clear → one zero cycle → nonzero cycles → check.
        // ----------------------------------------------------------------
        // Clear first to reset counters and stagger chain
        clear = 1; @(posedge clk); #1; clear = 0;

        // One cycle of all-zero acts
        for (int i = 0; i < ARRAY_SIZE; i++) act_in[i] = '0;
        act_col_vld = 1;
        @(posedge clk); #1;   // T=0: zero_det all ones
        // Now drive nonzero to avoid further detections
        for (int i = 0; i < ARRAY_SIZE; i++) act_in[i] = DATA_WIDTH'(i + 1);
        // Row 0: skip arrives 1 cycle after T → already here
        check("stagger row 0: skip_en_col[0]=1 at T+1", skip_en_col[0], 1'b1);
        @(posedge clk); #1;   // T+1
        check("stagger row 1: skip_en_col[1]=1 at T+2", skip_en_col[1], 1'b1);
        check("stagger row 0: skip_en_col[0]=0 (back to nonzero)", skip_en_col[0], 1'b0);
        @(posedge clk); #1;   // T+2
        check("stagger row 2: skip_en_col[2]=1 at T+3", skip_en_col[2], 1'b1);
        @(posedge clk); #1;   // T+3
        check("stagger row 3: skip_en_col[3]=1 at T+4", skip_en_col[3], 1'b1);
        act_col_vld = 0;
        @(posedge clk); #1;
        for (int i = 0; i < ARRAY_SIZE; i++)
            check($sformatf("post-stagger: skip_en_col[%0d]=0", i), skip_en_col[i], 1'b0);

        // ----------------------------------------------------------------
        // 6. Mixed zero/nonzero: only zero rows skip.
        //    Drive: act_in[0]=0, [1]=nonzero, [2]=0, [3]=nonzero for 1 cycle.
        //    Check skip_en_col[0] at +1, [2] at +3; [1],[3] should stay 0.
        // ----------------------------------------------------------------
        clear = 1; @(posedge clk); #1; clear = 0;
        act_in[0] = '0;
        act_in[1] = 8'd5;
        act_in[2] = '0;
        act_in[3] = 8'd7;
        act_col_vld = 1;
        @(posedge clk); #1;   // T=0 detection
        // Skip for row 1 and row 3 from this: should be 0 (acts nonzero)
        check("mixed after T: skip_en_col[0]=1", skip_en_col[0], 1'b1);
        check("mixed after T: skip_en_col[1]=0", skip_en_col[1], 1'b0);
        // Drive nonzero for remaining checks
        for (int i = 0; i < ARRAY_SIZE; i++) act_in[i] = DATA_WIDTH'(i + 1);
        @(posedge clk); #1;
        check("mixed T+2: skip_en_col[1]=0", skip_en_col[1], 1'b0);
        check("mixed T+2: skip_en_col[0]=0", skip_en_col[0], 1'b0);
        @(posedge clk); #1;
        check("mixed T+3: skip_en_col[2]=1", skip_en_col[2], 1'b1);
        check("mixed T+3: skip_en_col[1]=0", skip_en_col[1], 1'b0);
        @(posedge clk); #1;
        check("mixed T+4: skip_en_col[3]=0", skip_en_col[3], 1'b0);
        act_col_vld = 0;

        // ----------------------------------------------------------------
        // 7. Counter: one cycle of 2 zeros → skipped_mac_cycles = 2
        // ----------------------------------------------------------------
        clear = 1; @(posedge clk); #1; clear = 0;
        check_int("counter clear: total=0",   int'(total_mac_cycles),   0);
        check_int("counter clear: skipped=0", int'(skipped_mac_cycles), 0);

        act_in[0] = '0;
        act_in[1] = 8'd5;
        act_in[2] = '0;
        act_in[3] = 8'd7;
        act_col_vld = 1;
        @(posedge clk); #1;
        act_col_vld = 0;
        check_int("counter: total=ARRAY_SIZE",    int'(total_mac_cycles),   ARRAY_SIZE);
        check_int("counter: skipped=2 (rows 0,2)", int'(skipped_mac_cycles), 2);

        // ----------------------------------------------------------------
        // 8. rst_n clears counters and stagger chain mid-run
        // ----------------------------------------------------------------
        act_col_vld = 1;
        for (int i = 0; i < ARRAY_SIZE; i++) act_in[i] = '0;
        @(posedge clk); #1;
        rst_n = 0; @(posedge clk); #1; rst_n = 1;
        act_col_vld = 0; #1;
        check_int("rst_n clears total",   int'(total_mac_cycles),   0);
        check_int("rst_n clears skipped", int'(skipped_mac_cycles), 0);
        for (int i = 0; i < ARRAY_SIZE; i++)
            check($sformatf("rst_n clears skip_en_col[%0d]", i), skip_en_col[i], 1'b0);

        // ----------------------------------------------------------------
        $display("=== Results: %0d passed  %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("SOME TESTS FAILED");
        $finish;
    end

endmodule
