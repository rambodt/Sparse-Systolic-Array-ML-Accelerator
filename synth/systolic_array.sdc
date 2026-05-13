# Synopsis Design Constraints
# Sparse Systolic Array Matrix Accelerator
# Target: 100 MHz — push hard, worst case it fails and we back off

# ── Primary clock ─────────────────────────────────────────────────────────────
# 10 ns period = 100 MHz
create_clock -name clk -period 10.0 [get_ports clk]

# ── Input/output delays ───────────────────────────────────────────────────────
# Assume host interface signals are stable well before clock edge
set_input_delay  -clock clk -max 2.0 [all_inputs]
set_input_delay  -clock clk -min 0.5 [all_inputs]
set_output_delay -clock clk -max 2.0 [all_outputs]
set_output_delay -clock clk -min 0.5 [all_outputs]

# ── False paths ───────────────────────────────────────────────────────────────
# reset is asynchronous to timing analysis (synchronous in RTL but held long enough)
set_false_path -from [get_ports rst_n]

# ── Derive clock uncertainty from PLL (if using Quartus PLL IP) ──────────────
derive_clock_uncertainty
