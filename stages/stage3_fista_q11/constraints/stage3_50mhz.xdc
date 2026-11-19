# Standalone PL compute IP timing baseline. Board I/O delays are not specified here.
create_clock -name pl_clk_50m -period 20.000 [get_ports clk]
