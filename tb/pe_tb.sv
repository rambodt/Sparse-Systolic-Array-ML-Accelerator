`timescale 1ns/1ps

//------------------------------------------------------------------------------
// pe_tb
//------------------------------------------------------------------------------
// Directed unit testbench for a single processing element. It verifies reset,
// weight preload, two-stage MAC latency, activation forwarding, sparse skip
// behavior, weight hold behavior, and mid-run reset clearing of pipeline state.
//------------------------------------------------------------------------------

module pe_tb;

    // ------------------------------------------------------------------ params
    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;

    // ------------------------------------------------------------------ DUT ports
    logic                   clk;
    logic                   rst_n;
    logic [DATA_WIDTH-1:0]  weight_in;
    logic [DATA_WIDTH-1:0]  act_in;
    logic [ACC_WIDTH-1:0]   psum_in;
    logic                   weight_load_en;
    logic                   skip_en;
    logic [DATA_WIDTH-1:0]  act_out;
    logic [DATA_WIDTH-1:0]  weight_out;
    logic [ACC_WIDTH-1:0]   psum_out;

    // ------------------------------------------------------------------ DUT
    pe #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) dut (.*);

    // ------------------------------------------------------------------ clock
    initial clk = 0;
    always #5 clk = ~clk;   // 100 MHz

    // Shared scoreboard counters used by every check task.
    int pass_count = 0;
    int fail_count = 0;

    task apply_reset();
        rst_n          = 0;
        weight_in      = '0;
        act_in         = '0;
        psum_in        = '0;
        weight_load_en = 0;
        skip_en        = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;
    endtask

    task check(
        input string       test_name,
        input logic [ACC_WIDTH-1:0]  got,
        input logic [ACC_WIDTH-1:0]  expected
    );
        if (got === expected) begin
            $display("PASS  %s  (got=%0d)", test_name, got);
            pass_count++;
        end else begin
            $display("FAIL  %s  (got=%0d  expected=%0d)", test_name, got, expected);
            fail_count++;
        end
    endtask

    // ------------------------------------------------------------------ tests
    initial begin
        $display("=== pe directed testbench (2-stage pipeline) ===");

        // -----------------------------------------------
        // 1. Reset: all outputs must be 0
        // -----------------------------------------------
        apply_reset();
        check("reset psum_out==0", psum_out, '0);
        check("reset act_out==0",  act_out,  '0);

        // -----------------------------------------------
        // 2. Weight preload
        //    Load weight=7, verify weight_out==7 after 1 cycle
        // -----------------------------------------------
        weight_in      = 8'd7;
        weight_load_en = 1;
        skip_en        = 0;
        act_in         = '0;
        psum_in        = '0;
        @(posedge clk); #1;
        weight_load_en = 0;
        check("weight preload weight_out", weight_out, 8'd7);

        // -----------------------------------------------
        // 3. Single MAC (2-stage pipeline: 2 clocks needed)
        //    weight=7, act=3, psum_in=10  →  psum_out = 10 + 7*3 = 31
        // -----------------------------------------------
        act_in  = 8'd3;
        psum_in = 32'd10;
        skip_en = 0;
        @(posedge clk); #1;   // stage 1: mult_r=21, psum_in_r=10
        @(posedge clk); #1;   // stage 2: psum_out = 10+21 = 31
        check("single MAC", psum_out, 32'd31);

        // -----------------------------------------------
        // 4. act_out passthrough (1-cycle register; act_in=3 held for both clocks above)
        // -----------------------------------------------
        check("act_out passthrough", act_out, 8'd3);

        // -----------------------------------------------
        // 5. Accumulated MACs (2 clocks per computation)
        //    A: weight=7, act=1, psum_in=0  → psum_out=7
        //    B: weight=7, act=2, psum_in=7  → psum_out=21
        //    C: weight=7, act=3, psum_in=21 → psum_out=42
        // -----------------------------------------------
        psum_in = 32'd0; act_in = 8'd1;
        @(posedge clk); #1; @(posedge clk); #1;
        check("accum cycle A", psum_out, 32'd7);

        psum_in = 32'd7; act_in = 8'd2;
        @(posedge clk); #1; @(posedge clk); #1;
        check("accum cycle B", psum_out, 32'd21);

        psum_in = 32'd21; act_in = 8'd3;
        @(posedge clk); #1; @(posedge clk); #1;
        check("accum cycle C", psum_out, 32'd42);

        // -----------------------------------------------
        // 6. Skip logic: skip_en=1 → psum_out = psum_in (no accumulation)
        //    weight=7, act=5, psum_in=100, skip_en=1 → psum_out=100
        // -----------------------------------------------
        skip_en = 1;
        act_in  = 8'd5;
        psum_in = 32'd100;
        @(posedge clk); #1; @(posedge clk); #1;
        check("skip passthrough", psum_out, 32'd100);

        // -----------------------------------------------
        // 7. Skip off again: normal MAC resumes
        //    weight=7, act=4, psum_in=0, skip_en=0 → psum_out=28
        // -----------------------------------------------
        skip_en = 0;
        act_in  = 8'd4;
        psum_in = 32'd0;
        @(posedge clk); #1; @(posedge clk); #1;
        check("MAC after skip", psum_out, 32'd28);

        // -----------------------------------------------
        // 8. Weight does NOT change when weight_load_en=0
        //    weight_out should still be 7
        // -----------------------------------------------
        check("weight held", weight_out, 8'd7);

        // -----------------------------------------------
        // 9. Max values (no overflow): 127*127 + 0 = 16129
        // -----------------------------------------------
        weight_in      = 8'd127;
        weight_load_en = 1;
        @(posedge clk); #1;
        weight_load_en = 0;
        act_in  = 8'd127;
        psum_in = 32'd0;
        skip_en = 0;
        @(posedge clk); #1; @(posedge clk); #1;
        check("max values no overflow", psum_out, 32'd16129);

        // -----------------------------------------------
        // 10. Mid-run reset clears all registers including pipeline stages
        // -----------------------------------------------
        act_in  = 8'd99;
        psum_in = 32'd999;
        @(posedge clk); #1;
        apply_reset();
        check("mid-run reset psum_out",   psum_out,   '0);
        check("mid-run reset act_out",    act_out,    '0);
        check("mid-run reset weight_out", weight_out, '0);

        // -----------------------------------------------
        // Summary
        // -----------------------------------------------
        $display("=== Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

endmodule
