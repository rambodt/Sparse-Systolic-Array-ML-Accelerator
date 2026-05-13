// Capture timing (derived from array_top pipeline analysis):
//   At streaming tick S (1-indexed from first act_col_vld rising edge),
//   psum_out_row[c] = C[t][c]  where  S = t + c + ARRAY_SIZE + 1
//   → t = S - c - ARRAY_SIZE - 1
//   Valid when t in [0, ARRAY_SIZE-1],
//   i.e., S in [c + ARRAY_SIZE + 1,  c + 2*ARRAY_SIZE]
//
//   All ARRAY_SIZE*ARRAY_SIZE elements arrive within S = 1..3*ARRAY_SIZE-1.
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

    // Read port — host reads one element at a time after done
    input  logic [$clog2(ARRAY_SIZE)-1:0]   rd_row,
    input  logic [$clog2(ARRAY_SIZE)-1:0]   rd_col,
    output logic [ACC_WIDTH-1:0]            rd_data
);

    localparam int S_MAX  = 3 * ARRAY_SIZE - 1;    // last tick with valid output
    localparam int S_BASE = ARRAY_SIZE + 1;         // first tick col-0 output is valid
    localparam int S_W    = $clog2(S_MAX + 1) + 1;
    localparam int ROW_W  = $clog2(ARRAY_SIZE);

    // ------------------------------------------------------------------
    // Accumulator array: buf_r[row][col]
    // ------------------------------------------------------------------
    logic [ACC_WIDTH-1:0] buf_r [ARRAY_SIZE][ARRAY_SIZE];

    // ------------------------------------------------------------------
    // Streaming tick counter — starts at 1 on rising edge of act_col_vld,
    // increments every cycle until S_MAX, then stops.
    // Multi-tile: restarts each tile without clearing buf_r (accumulation).
    // ------------------------------------------------------------------
    logic [S_W-1:0] S_r;
    logic           act_vld_prev_r;
    logic           running_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            S_r           <= '0;
            act_vld_prev_r <= '0;
            running_r     <= '0;
        end else begin
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
    // Accumulation: buf_r[t][c] += psum_in[c] when S is in column c's
    // valid window.  For multi-tile K the += accumulates across tiles.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n || buf_clear) begin
            for (int r = 0; r < ARRAY_SIZE; r++)
                for (int c = 0; c < ARRAY_SIZE; c++)
                    buf_r[r][c] <= '0;
        end else if (running_r) begin
            for (int c = 0; c < ARRAY_SIZE; c++) begin
                // Column c is valid during S in [c+S_BASE, c+S_BASE+ARRAY_SIZE-1]
                if (S_r >= S_W'(c + S_BASE) && S_r <= S_W'(c + S_BASE + ARRAY_SIZE - 1)) begin
                    // t = S - c - S_BASE  (always non-negative inside the guard)
                    buf_r[S_r - S_W'(c + S_BASE)][c] <=
                        buf_r[S_r - S_W'(c + S_BASE)][c] + psum_in[c];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Read port (combinational — host reads after done asserts)
    // ------------------------------------------------------------------
    assign rd_data = buf_r[rd_row][rd_col];

endmodule
