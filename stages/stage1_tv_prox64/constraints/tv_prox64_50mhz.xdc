# Module-level timing target: AX7020 PL clock baseline = 50 MHz.
# This is a clock constraint only; board pin constraints are intentionally
# omitted because this is a reusable compute IP, not the final board top.
create_clock -name pl_clk_50m -period 20.000 [get_ports clk]
