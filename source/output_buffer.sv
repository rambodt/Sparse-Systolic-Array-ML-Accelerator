// Capture timing (derived from array_top pipeline analysis):
//   At streaming tick S (1-indexed from first act_col_vld rising edge),
//   psum_out_row[c] = C[t][c]  where  S = t + c + 2*ARRAY_SIZE + 1
//   -> t = S - c - 2*ARRAY_SIZE - 1
//   Valid when t in [0, ARRAY_SIZE-1],
//   i.e., S in [c + 2*ARRAY_SIZE + 1,  c + 3*ARRAY_SIZE]
//
//   All ARRAY_SIZE*ARRAY_SIZE elements arrive within S = 1..4*ARRAY_SIZE-1.
//   Outputs for different columns are staggered (diagonal pattern).

module output_buffer #(
    parameter int ARRAY_SIZE = 16,
    parameter int ACC_WIDTH  = 32
)(
    input  logic                            clk,
    input  logic                            rst_n,

    // Pulse from host (via accel_top start) — zeros the buffer before a new GEMM
    input  logic                            buf_clear,

    // act_col_vld from DMA: rising edge starts the streaming tick counter
    input  logic                            act_col_vld,

    // Partial sums from array_top bottom row
    input  logic [ACC_WIDTH-1:0]            psum_in [ARRAY_SIZE],

    // Read port — host can read one complete row after done. The scalar rd_data
    // port is kept for compatibility with older tests.
    input  logic [$clog2(ARRAY_SIZE)-1:0]   rd_row,
    input  logic [$clog2(ARRAY_SIZE)-1:0]   rd_col,
    output logic [ARRAY_SIZE*ACC_WIDTH-1:0] rd_row_data,
    output logic [ACC_WIDTH-1:0]            rd_data
);

    localparam int S_MAX  = 4 * ARRAY_SIZE - 1;    // last tick with valid output
    localparam int S_BASE = 2 * ARRAY_SIZE + 1;    // first tick col-0 output is valid
    localparam int S_W    = $clog2(S_MAX + 1) + 1;
    localparam int ROW_W  = $clog2(ARRAY_SIZE);

    // ------------------------------------------------------------------
    // Accumulator array: buf_r[row][col]
    // ------------------------------------------------------------------
    logic [ACC_WIDTH-1:0] buf_r [ARRAY_SIZE][ARRAY_SIZE];
    logic                 col_active_r [ARRAY_SIZE];
    logic [ROW_W-1:0]     col_row_r    [ARRAY_SIZE];

    // ------------------------------------------------------------------
    // Streaming tick counter — starts at 1 on rising edge of act_col_vld,
    // increments every cycle until S_MAX, then stops.
    // Multi-tile: restarts each tile without clearing buf_r (accumulation).
    // ------------------------------------------------------------------
    logic [S_W-1:0] S_r;
    logic           act_vld_prev_r;
    logic           running_r;
    logic [S_W-1:0] S_pipe_r;
    logic           running_pipe_r;
    logic [ACC_WIDTH-1:0] psum_pipe_r [ARRAY_SIZE];

    localparam int ACC_LO_W = ACC_WIDTH / 2;
    localparam int ACC_HI_W = ACC_WIDTH - ACC_LO_W;

    logic                 acc_req_valid [ARRAY_SIZE];
    logic [ROW_W-1:0]     acc_req_row   [ARRAY_SIZE];
    logic                 acc_req_valid_r [ARRAY_SIZE];
    logic [ROW_W-1:0]     acc_req_row_r   [ARRAY_SIZE];
    logic [ACC_WIDTH-1:0] acc_req_psum_r  [ARRAY_SIZE];
    logic                 acc_a_valid_r [ARRAY_SIZE];
    logic [ROW_W-1:0]     acc_a_row_r   [ARRAY_SIZE];
    logic [ACC_WIDTH-1:0] acc_a_old_r   [ARRAY_SIZE];
    logic [ACC_WIDTH-1:0] acc_a_psum_r  [ARRAY_SIZE];
    logic                 acc_b_valid_r [ARRAY_SIZE];
    logic [ROW_W-1:0]     acc_b_row_r   [ARRAY_SIZE];
    logic [ACC_LO_W:0]    acc_b_lo_sum_r[ARRAY_SIZE];
    logic [ACC_HI_W-1:0]  acc_b_old_hi_r[ARRAY_SIZE];
    logic [ACC_HI_W-1:0]  acc_b_psum_hi_r[ARRAY_SIZE];

    function automatic logic [ACC_WIDTH-1:0] finish_acc_sum(
        input logic [ACC_LO_W:0]   lo_sum,
        input logic [ACC_HI_W-1:0] old_hi,
        input logic [ACC_HI_W-1:0] psum_hi
    );
        logic [ACC_HI_W:0] hi_sum;
        begin
            hi_sum = {1'b0, old_hi} + {1'b0, psum_hi} + ACC_HI_W'(lo_sum[ACC_LO_W]);
            finish_acc_sum = {hi_sum[ACC_HI_W-1:0], lo_sum[ACC_LO_W-1:0]};
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            S_r           <= '0;
            act_vld_prev_r <= '0;
            running_r     <= '0;
            S_pipe_r       <= '0;
            running_pipe_r <= '0;
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                psum_pipe_r[c] <= '0;
            end
        end else begin
            S_pipe_r       <= S_r;
            running_pipe_r <= running_r;
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                psum_pipe_r[c] <= psum_in[c];
            end

            act_vld_prev_r <= act_col_vld;

            if (act_col_vld && !act_vld_prev_r) begin
                // Rising edge: begin capture for this tile
                running_r <= 1'b1;
                S_r       <= S_W'(1);
            end else if (running_r) begin
                if (S_r == S_W'(S_MAX)) begin
                    running_r <= 1'b0;
                    S_r       <= '0;
                end else begin
                    S_r <= S_r + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Accumulation: each output column has a small row pointer. The actual
    // read/add/write path is pipelined and splits the 32-bit add into low and
    // high halves, which keeps the post-route output-buffer path short.
    // ------------------------------------------------------------------
    always_comb begin
        for (int c = 0; c < ARRAY_SIZE; c++) begin
            acc_req_valid[c] = 1'b0;
            acc_req_row[c]   = '0;
            if (running_pipe_r) begin
                if (S_pipe_r == S_W'(c + S_BASE)) begin
                    acc_req_valid[c] = 1'b1;
                    acc_req_row[c]   = '0;
                end else if (col_active_r[c]) begin
                    acc_req_valid[c] = 1'b1;
                    acc_req_row[c]   = col_row_r[c];
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || buf_clear) begin
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                col_active_r[c] <= 1'b0;
                col_row_r[c]    <= '0;
                acc_req_valid_r[c] <= 1'b0;
                acc_req_row_r[c]   <= '0;
                acc_req_psum_r[c]  <= '0;
                acc_a_valid_r[c] <= 1'b0;
                acc_a_row_r[c]   <= '0;
                acc_a_old_r[c]   <= '0;
                acc_a_psum_r[c]  <= '0;
                acc_b_valid_r[c] <= 1'b0;
                acc_b_row_r[c]   <= '0;
                acc_b_lo_sum_r[c] <= '0;
                acc_b_old_hi_r[c] <= '0;
                acc_b_psum_hi_r[c] <= '0;
            end
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                for (int c = 0; c < ARRAY_SIZE; c++) begin
                    buf_r[r][c] <= '0;
                end
            end
        end else begin
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                if (acc_b_valid_r[c]) begin
                    buf_r[acc_b_row_r[c]][c] <= finish_acc_sum(
                        acc_b_lo_sum_r[c],
                        acc_b_old_hi_r[c],
                        acc_b_psum_hi_r[c]
                    );
                end

                acc_req_valid_r[c] <= acc_req_valid[c];
                acc_req_row_r[c]   <= acc_req_row[c];
                acc_req_psum_r[c]  <= psum_pipe_r[c];

                acc_b_valid_r[c]  <= acc_a_valid_r[c];
                acc_b_row_r[c]    <= acc_a_row_r[c];
                acc_b_lo_sum_r[c] <= {1'b0, acc_a_old_r[c][ACC_LO_W-1:0]} +
                                     {1'b0, acc_a_psum_r[c][ACC_LO_W-1:0]};
                acc_b_old_hi_r[c] <= acc_a_old_r[c][ACC_WIDTH-1:ACC_LO_W];
                acc_b_psum_hi_r[c] <= acc_a_psum_r[c][ACC_WIDTH-1:ACC_LO_W];

                acc_a_valid_r[c] <= acc_req_valid_r[c];
                acc_a_row_r[c]   <= acc_req_row_r[c];
                acc_a_old_r[c]   <= buf_r[acc_req_row_r[c]][c];
                acc_a_psum_r[c]  <= acc_req_psum_r[c];

                if (acc_req_valid[c] && (acc_req_row[c] == '0)) begin
                    if (ARRAY_SIZE > 1) begin
                        col_active_r[c] <= 1'b1;
                        col_row_r[c]    <= ROW_W'(1);
                    end
                end else if (acc_req_valid[c]) begin
                    if (col_row_r[c] == ROW_W'(ARRAY_SIZE - 1)) begin
                        col_active_r[c] <= 1'b0;
                        col_row_r[c]    <= '0;
                    end else begin
                        col_row_r[c] <= col_row_r[c] + 1'b1;
                    end
                end else if (!running_pipe_r) begin
                    col_active_r[c] <= 1'b0;
                    col_row_r[c]    <= '0;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Registered host read port. Split the 2-D buffer mux into small row-group,
    // row, and column stages so ASIC placement does not see one large mux.
    // rd_data is valid four cycles after rd_row/rd_col are presented.
    // ------------------------------------------------------------------
    localparam int RD_GROUPS     = 4;
    localparam int RD_GROUP_ROWS = (ARRAY_SIZE + RD_GROUPS - 1) / RD_GROUPS;
    localparam int RD_GROUP_W    = $clog2(RD_GROUPS);
    localparam int RD_LO_W       = (RD_GROUP_ROWS > 1) ? $clog2(RD_GROUP_ROWS) : 1;

    logic [RD_GROUP_W-1:0] rd_group;
    logic [RD_LO_W-1:0]    rd_lo;
    logic [RD_GROUP_W-1:0] rd_group_r;
    logic [RD_GROUP_W-1:0] rd_group_rr;
    logic [RD_LO_W-1:0]    rd_lo_r;
    logic [ROW_W-1:0]      rd_col_r;
    logic [ROW_W-1:0]      rd_col_rr;
    logic [ROW_W-1:0]      rd_col_rrr;
    logic [ACC_WIDTH-1:0]  rd_group_data_r [RD_GROUPS][ARRAY_SIZE];
    logic [ACC_WIDTH-1:0] rd_row_data_r [ARRAY_SIZE];

    always_comb begin
        rd_group = '0;
        rd_lo    = '0;
        if (ARRAY_SIZE > RD_GROUPS) begin
            rd_group = rd_row[ROW_W-1 -: RD_GROUP_W];
            rd_lo    = rd_row[RD_LO_W-1:0];
        end else begin
            rd_group = rd_row[RD_GROUP_W-1:0];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_group_r <= '0;
            rd_group_rr <= '0;
            rd_lo_r <= '0;
            rd_col_r <= '0;
            rd_col_rr <= '0;
            rd_col_rrr <= '0;
            rd_data <= '0;
            rd_row_data <= '0;
            for (int g = 0; g < RD_GROUPS; g++)
                for (int c = 0; c < ARRAY_SIZE; c++)
                    rd_group_data_r[g][c] <= '0;
            for (int c = 0; c < ARRAY_SIZE; c++)
                rd_row_data_r[c] <= '0;
        end else begin
            rd_group_r <= rd_group;
            rd_group_rr <= rd_group_r;
            rd_lo_r    <= rd_lo;
            rd_col_r   <= rd_col;
            rd_col_rr  <= rd_col_r;
            rd_col_rrr <= rd_col_rr;

            for (int g = 0; g < RD_GROUPS; g++) begin
                for (int c = 0; c < ARRAY_SIZE; c++) begin
                    if ((g * RD_GROUP_ROWS + rd_lo_r) < ARRAY_SIZE)
                        rd_group_data_r[g][c] <= buf_r[g * RD_GROUP_ROWS + rd_lo_r][c];
                    else
                        rd_group_data_r[g][c] <= '0;
                end
            end

            for (int c = 0; c < ARRAY_SIZE; c++)
                rd_row_data_r[c] <= rd_group_data_r[rd_group_rr][c];

            for (int c = 0; c < ARRAY_SIZE; c++)
                rd_row_data[c*ACC_WIDTH +: ACC_WIDTH] <= rd_row_data_r[c];

            rd_data <= rd_row_data_r[rd_col_rrr];
        end
    end

endmodule
