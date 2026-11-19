# Board pin mapping from user's proven Experiment 1 project uart_dynamic.xdc.
# Device: XC7Z020-2CLG400, AX7020 V2.x, 3.3V PL J10 nanoDAP UART.
set_property PACKAGE_PIN U18 [get_ports clk_50m]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50m]
create_clock -name sys_clk_50m -period 20.000 [get_ports clk_50m]

set_property PACKAGE_PIN N15 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

set_property PACKAGE_PIN W19 [get_ports uart_rx_i]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx_i]
set_property PULLUP true [get_ports uart_rx_i]

set_property PACKAGE_PIN W18 [get_ports uart_tx_o]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx_o]

# RX is asynchronous to FPGA 50MHz. Its first synchronizer flop is inside
# the copied uart_rx.v. Do not use arbitrary input-delay constraints for UART.
# The Stage-5B board top will have to be rechecked after integrating Stage-4C.
