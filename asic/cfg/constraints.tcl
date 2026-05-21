# First-pass Genus/Innovus timing constraints for accel_top.

create_clock -name clk -period 5.0 [get_ports clk]
set_clock_uncertainty 0.100 [get_clocks clk]

# rst_n is an asynchronous reset. Do not time reset deassertion as a normal
# 5 ns data input path through reset mux logic.
set_false_path -from [get_ports rst_n]

# Use half-cycle setup budgets for IO relative to clk.
set_input_delay  2.5 -max -clock [get_clocks clk] [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 2.5 -max -clock [get_clocks clk] [all_outputs]

# Use zero-cycle hold budgets for IO relative to clk.
set_input_delay  0.0 -min -clock [get_clocks clk] [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.0 -min -clock [get_clocks clk] [all_outputs]
