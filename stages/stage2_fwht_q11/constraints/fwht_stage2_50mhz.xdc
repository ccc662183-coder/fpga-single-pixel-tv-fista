# Reusable compute IP timing baseline: 50 MHz.
# Board-level input/output delays are intentionally not specified here.
create_clock -name pl_clk_50m -period 20.000 [get_ports clk]
