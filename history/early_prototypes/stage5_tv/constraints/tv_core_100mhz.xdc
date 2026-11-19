# 100 MHz internal timing target. No physical pin assignment; not a board top.
create_clock -name tv_clk -period 10.000 [get_ports clk]
