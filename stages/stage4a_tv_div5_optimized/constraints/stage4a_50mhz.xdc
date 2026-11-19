# Stage-4A standalone compute-IP clock target 50 MHz; board I/O is not constrained here.
create_clock -name pl_clk_50m -period 20.000 [get_ports clk]
