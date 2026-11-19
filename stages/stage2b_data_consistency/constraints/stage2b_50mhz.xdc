# Standalone compute IP timing target, not board-level pin constraints.
# After integration, provide the actual AX7020 clock source and I/O constraints.
create_clock -name pl_clk_50m -period 20.000 [get_ports clk]
