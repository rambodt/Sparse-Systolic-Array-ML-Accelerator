// skip_en_col[r] must arrive at PE[r] at the same cycle as act_stagger[r],
// which is r+1 cycles after act_col_in[r] is presented.
// This module mirrors the array_top stagger exactly for the zero-detect flag.

module sparsity_unit #(
    parameter int ARRAY_SIZE = 16,
    parameter int DATA_WIDTH = 8
)(
    input  logic clk,
    input  logic rst_n,
    input  logic clear,                          // pulse on start — resets per-GEMM counters

    input  logic [DATA_WIDTH-1:0] act_in     [ARRAY_SIZE],
    input  logic                  act_col_vld,

    output logic [DATA_WIDTH-1:0] act_out    [ARRAY_SIZE],
    output logic [ARRAY_SIZE-1:0] skip_en_col,

    output logic [31:0]           total_mac_cycles,
    output logic [31:0]           skipped_mac_cycles
);

    // Pass-through — activations reach array_top unchanged
    always_comb begin
        for (int i = 0; i < ARRAY_SIZE; i++)
            act_out[i] = act_in[i];
    end

    // Raw zero detection (gated by act_col_vld — only detect during streaming)
    logic [ARRAY_SIZE-1:0] zero_det;
    always_comb begin
        for (int i = 0; i < ARRAY_SIZE; i++)
            zero_det[i] = act_col_vld && (act_in[i] == '0);
    end

    // ------------------------------------------------------------------
    // Stagger skip_en to match the activation stagger in array_top.
    // PE[r] receives its activation r+1 cycles after act_col_in[r] is valid.
    // Structure mirrors array_top's stagger_sr / act_stagger chain exactly:
    //   Row 0: 1 register (skip_staggered[0] <= zero_det[0])
    //   Row r: r stages in det_sr[r] → 1 final register = r+1 total
    // Also resets on clear so stale data cannot corrupt the next GEMM.
    // ------------------------------------------------------------------
    logic [ARRAY_SIZE-2:0] det_sr [ARRAY_SIZE];
    logic [ARRAY_SIZE-1:0] skip_staggered;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            skip_staggered <= '0;
            for (int r = 0; r < ARRAY_SIZE; r++)
                for (int s = 0; s < ARRAY_SIZE-1; s++)
                    det_sr[r][s] <= '0;
        end else begin
            for (int r = 0; r < ARRAY_SIZE; r++) begin
                if (r == 0) begin
                    skip_staggered[0] <= zero_det[0];
                end else begin
                    det_sr[r][0] <= zero_det[r];
                    for (int s = 1; s < r; s++)
                        det_sr[r][s] <= det_sr[r][s-1];
                    skip_staggered[r] <= det_sr[r][r-1];
                end
            end
        end
    end

    assign skip_en_col = skip_staggered;

    // ------------------------------------------------------------------
    // Per-GEMM MAC utilization counters (counted at detection time —
    // approximation sufficient for sparsity ratio analysis)
    //   total_mac_cycles   += ARRAY_SIZE every cycle act_col_vld=1
    //   skipped_mac_cycles += (zero count in act_in) every cycle act_col_vld=1
    // ------------------------------------------------------------------
    logic [$clog2(ARRAY_SIZE+1)-1:0] zero_cnt;
    always_comb begin
        zero_cnt = '0;
        for (int i = 0; i < ARRAY_SIZE; i++)
            if (act_in[i] == '0)
                zero_cnt = zero_cnt + 1'b1;
    end

    logic [31:0] total_r, skipped_r;
    assign total_mac_cycles   = total_r;
    assign skipped_mac_cycles = skipped_r;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            total_r   <= '0;
            skipped_r <= '0;
        end else if (act_col_vld) begin
            total_r   <= total_r   + 32'(ARRAY_SIZE);
            skipped_r <= skipped_r + 32'(zero_cnt);
        end
    end

endmodule
