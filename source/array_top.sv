module array_top #(
    parameter int ARRAY_SIZE = 16,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32
)(
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [DATA_WIDTH-1:0]   act_col_in    [ARRAY_SIZE],
    input  logic                    act_col_vld,

    input  logic [DATA_WIDTH-1:0]   weight_load_in [ARRAY_SIZE],
    input  logic                    weight_load_en,

    input  logic [ARRAY_SIZE-1:0]   skip_en_col,

    output logic [ACC_WIDTH-1:0]    psum_out_row [ARRAY_SIZE],
    output logic                    psum_out_vld
);

    // ------------------------------------------------------------------
    // Stagger shift registers → left-column activation inputs
    // Row 0: 1-cycle delay (one register).
    // Row r: r+1 cycles delay (stagger_sr has r stages, plus one register to act_stagger).
    // Relative delay between consecutive rows = 1 cycle.
    // ------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] stagger_sr  [ARRAY_SIZE][ARRAY_SIZE-1];
    logic [DATA_WIDTH-1:0] act_stagger [ARRAY_SIZE];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                act_stagger[r] <= '0;
                for (int s = 0; s < ARRAY_SIZE-1; s++)
                    stagger_sr[r][s] <= '0;
            end
        end else begin
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                if (r == 0) begin
                    act_stagger[0] <= act_col_in[0];
                end else begin
                    stagger_sr[r][0] <= act_col_in[r];
                    for (int s = 1; s < r; s++)
                        stagger_sr[r][s] <= stagger_sr[r][s-1];
                    act_stagger[r] <= stagger_sr[r][r-1];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // PE-to-PE interconnect — separate signals avoid multiple-driver issues
    // ------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] act_right [ARRAY_SIZE][ARRAY_SIZE];   // act_out of PE[r][c]
    logic [DATA_WIDTH-1:0] wgt_down  [ARRAY_SIZE][ARRAY_SIZE];   // weight_out of PE[r][c]
    logic [ACC_WIDTH-1:0]  psum_down [ARRAY_SIZE+1][ARRAY_SIZE]; // psum between rows

    // Top row psum boundary = 0
    genvar c, i, j;
    generate
        for (c = 0; c < ARRAY_SIZE; c++) begin : psum_top
            assign psum_down[0][c] = '0;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Per-column skip alignment.
    // skip_en_col[r] from sparsity_unit is staggered r+1 cycles, which
    // aligns with when the activation reaches act_bus[r][0] (column 0).
    // PE[r][c] sees the same activation c cycles later, so its skip must
    // also be delayed c cycles.
    //
    // skip_col0[r]      = skip_en_col[r]          (no extra delay, col 0)
    // skip_shift[k][r]  = skip_en_col[r] delayed k+1 cycles (cols 1..N-1)
    // ------------------------------------------------------------------
    logic [ARRAY_SIZE-1:0] skip_col0;                    // wire, col 0
    logic [ARRAY_SIZE-1:0] skip_shift [ARRAY_SIZE-1];    // regs, cols 1..N-1

    assign skip_col0 = skip_en_col;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int k = 0; k < ARRAY_SIZE-1; k++)
                skip_shift[k] <= '0;
        end else begin
            skip_shift[0] <= skip_en_col;                // col 1: 1 cycle delay
            for (int k = 1; k < ARRAY_SIZE-1; k++)
                skip_shift[k] <= skip_shift[k-1];        // col k+1: k+1 cycles delay
        end
    end

    // ------------------------------------------------------------------
    // PE grid
    // ------------------------------------------------------------------
    generate
        for (i = 0; i < ARRAY_SIZE; i++) begin : row_gen
            for (j = 0; j < ARRAY_SIZE; j++) begin : col_gen
                pe #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) u_pe (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    // activation: left boundary from stagger, otherwise from left neighbor
                    .act_in         (j == 0 ? act_stagger[i] : act_right[i][j-1]),
                    // weight: top boundary from weight_load_in, otherwise from row above
                    .weight_in      (i == 0 ? weight_load_in[j] : wgt_down[i-1][j]),
                    .psum_in        (psum_down[i][j]),
                    .weight_load_en (weight_load_en),
                    // col 0: direct; col j: skip_en_col delayed j cycles
                    .skip_en        (j == 0 ? skip_col0[i] : skip_shift[j-1][i]),
                    .act_out        (act_right[i][j]),
                    .weight_out     (wgt_down[i][j]),
                    .psum_out       (psum_down[i+1][j])
                );
            end
        end
    endgenerate

    // Bottom row → outputs
    generate
        for (c = 0; c < ARRAY_SIZE; c++) begin : psum_out_con
            assign psum_out_row[c] = psum_down[ARRAY_SIZE][c];
        end
    endgenerate

    // ------------------------------------------------------------------
    // psum_out_vld: delay act_col_vld by ARRAY_SIZE+ARRAY_SIZE-1 cycles.
    // C[t][c] is valid at S_tick = t + c + ARRAY_SIZE + 1 from streaming start,
    // so the first valid output appears ARRAY_SIZE+1 ticks after the first vld.
    // psum_out_vld asserts for the window when bottom-row data is meaningful.
    // ------------------------------------------------------------------
    localparam int PIPE = 2*ARRAY_SIZE - 1;
    logic [PIPE-1:0] vld_sr;

    always_ff @(posedge clk) begin
        if (!rst_n)
            vld_sr <= '0;
        else
            vld_sr <= {vld_sr[PIPE-2:0], act_col_vld};
    end

    assign psum_out_vld = vld_sr[PIPE-1];

endmodule
