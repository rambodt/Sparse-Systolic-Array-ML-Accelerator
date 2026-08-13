//------------------------------------------------------------------------------
// pe
//------------------------------------------------------------------------------
// Processing element for the weight-stationary systolic array.
//
// Each PE stores one INT8 weight, forwards activations to the right, and
// accumulates a 16-bit product into a 32-bit partial sum. Weights are
// loaded exclusively via the shadow-buffer preload/commit chain below,
// there is no direct/live weight-load path. Multiplier and adder are
// separated by a register to shorten the post-route critical path.
// Zero-skip gates the multiplier input for skipped activations (skip_en)
// and for a zero held weight (weight_r=='0, checked for the PE's whole
// tile lifetime) -- power-only, doesn't affect cycle count.
//
// Weight quintuple buffering: five shadow weight registers (shadow_a..e)
// let the next tile's weights shift in on an independent chain while
// weight_r is still live, and let tiles further ahead start shifting too,
// without waiting for the in-flight per-PE commit wave to drain. With N
// buffers, a new tile's preload targets the buffer used (N-1) tile periods
// ago; dma_ctrl enforces a minimum commit-to-commit spacing
// (ceil((3*ARRAY_SIZE-2)/(N-1))) so that's provably safe under any
// prefetch schedule. N=5 (not 3) because the widened host/shadow-load
// ports shrink the natural tile period to ~16 cycles, below N=3's own
// margin requirement (23 cycles). shadow_load_sel is global (the whole
// shift chain must agree on target register); commit_sel arrives staggered
// per-PE in lockstep with weight_commit, telling each PE which buffer to
// read at its own commit moment.
//------------------------------------------------------------------------------
module pe #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
)(
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [DATA_WIDTH-1:0]   act_in,
    input  logic [ACC_WIDTH-1:0]    psum_in,

    input  logic                    skip_en,

    // Shadow (next-tile) weight preload chain -- independent of the live
    // weight_in/weight_load_en/weight_out chain above. shadow_load_sel
    // picks shadow_a..e (0..4) as this cycle's shift target --
    // global/undelayed, since the whole shift chain must agree on which
    // physical register it's currently loading.
    input  logic [DATA_WIDTH-1:0]   shadow_in,
    input  logic                    shadow_load_en,
    input  logic [2:0]              shadow_load_sel,
    // One-cycle pulse: commit the SELECTED shadow buffer into the live
    // weight_r. commit_sel must arrive already staggered to match
    // weight_commit's own per-PE timing (array_top.sv propagates both
    // through identical delay networks).
    input  logic                    weight_commit,
    input  logic [2:0]              commit_sel,

    output logic [DATA_WIDTH-1:0]   act_out,
    output logic [DATA_WIDTH-1:0]   shadow_out,
    output logic [ACC_WIDTH-1:0]    psum_out
);

    logic [DATA_WIDTH-1:0]   weight_r;
    logic [DATA_WIDTH-1:0]   shadow_a_r;
    logic [DATA_WIDTH-1:0]   shadow_b_r;
    logic [DATA_WIDTH-1:0]   shadow_c_r;
    logic [DATA_WIDTH-1:0]   shadow_d_r;
    logic [DATA_WIDTH-1:0]   shadow_e_r;

    // Pipeline stage 1 → 2: break multiply + accumulate critical path
    logic [2*DATA_WIDTH-1:0] mult_r;
    logic [ACC_WIDTH-1:0]    psum_in_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            weight_r   <= '0;
            shadow_a_r <= '0;
            shadow_b_r <= '0;
            shadow_c_r <= '0;
            shadow_d_r <= '0;
            shadow_e_r <= '0;
            act_out    <= '0;
            psum_out   <= '0;
            mult_r     <= '0;
            psum_in_r  <= '0;
        end else begin
            act_out <= act_in;

            if (weight_commit) begin
                case (commit_sel)
                    3'd0:    weight_r <= shadow_a_r;
                    3'd1:    weight_r <= shadow_b_r;
                    3'd2:    weight_r <= shadow_c_r;
                    3'd3:    weight_r <= shadow_d_r;
                    default: weight_r <= shadow_e_r;
                endcase
            end

            if (shadow_load_en) begin
                case (shadow_load_sel)
                    3'd0:    shadow_a_r <= shadow_in;
                    3'd1:    shadow_b_r <= shadow_in;
                    3'd2:    shadow_c_r <= shadow_in;
                    3'd3:    shadow_d_r <= shadow_in;
                    default: shadow_e_r <= shadow_in;
                endcase
            end

            // Stage 1: register multiply output, gated on skip_en or a
            // zero held weight.
            if (skip_en || (weight_r == '0))
                mult_r <= '0;
            else
                mult_r <= weight_r * act_in;
            psum_in_r <= psum_in;

            // Stage 2: accumulate. No separate skip/zero bypass needed --
            // mult_r is already forced to 0 above in those cases.
            psum_out <= psum_in_r + ACC_WIDTH'(mult_r);
        end
    end

    // shadow_out passes the buffer selected by shadow_load_sel downward
    // during the preload shift chain, so the row below sees the same
    // buffer this row is loading.
    always_comb begin
        case (shadow_load_sel)
            3'd0:    shadow_out = shadow_a_r;
            3'd1:    shadow_out = shadow_b_r;
            3'd2:    shadow_out = shadow_c_r;
            3'd3:    shadow_out = shadow_d_r;
            default: shadow_out = shadow_e_r;
        endcase
    end

endmodule
