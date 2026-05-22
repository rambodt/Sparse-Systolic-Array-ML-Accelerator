module pe #(
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
)(
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [DATA_WIDTH-1:0]   weight_in,
    input  logic [DATA_WIDTH-1:0]   act_in,
    input  logic [ACC_WIDTH-1:0]    psum_in,

    input  logic                    weight_load_en,
    input  logic                    skip_en,

    output logic [DATA_WIDTH-1:0]   act_out,
    output logic [DATA_WIDTH-1:0]   weight_out,
    output logic [ACC_WIDTH-1:0]    psum_out
);

    logic [DATA_WIDTH-1:0]   weight_r;

    // Pipeline stage 1 → 2: break multiply + accumulate critical path
    logic [2*DATA_WIDTH-1:0] mult_r;
    logic [ACC_WIDTH-1:0]    psum_in_r;
    logic                    skip_en_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            weight_r   <= '0;
            act_out    <= '0;
            psum_out   <= '0;
            mult_r     <= '0;
            psum_in_r  <= '0;
            skip_en_r  <= '0;
        end else begin
            act_out <= act_in;

            if (weight_load_en)
                weight_r <= weight_in;

            // Stage 1: register multiply output and delay control signals.
            // Gate the multiplier operands on skipped activations so sparse
            // inputs reduce datapath switching instead of only bypassing the
            // accumulator in stage 2.
            if (skip_en)
                mult_r <= '0;
            else
                mult_r <= weight_r * act_in;
            psum_in_r <= psum_in;
            skip_en_r <= skip_en;

            // Stage 2: accumulate using registered multiply result
            if (skip_en_r)
                psum_out <= psum_in_r;
            else
                psum_out <= psum_in_r + ACC_WIDTH'(mult_r);
        end
    end

    // weight_out passes weight_r downward during the preload shift chain
    assign weight_out = weight_r;

endmodule
