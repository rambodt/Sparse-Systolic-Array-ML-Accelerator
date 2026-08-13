
create_clock -name clk -period 5.0 [get_ports clk]
set_clock_uncertainty 0.000 [get_clocks clk]

set_false_path -from [get_ports rst_n]

set_input_delay  2.5 -max -clock [get_clocks clk] [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 2.5 -max -clock [get_clocks clk] [all_outputs]

set_input_delay  0.0 -min -clock [get_clocks clk] [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.0 -min -clock [get_clocks clk] [all_outputs]
