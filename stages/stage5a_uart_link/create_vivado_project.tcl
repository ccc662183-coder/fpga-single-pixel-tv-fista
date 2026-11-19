# Vivado 2019.2 -- Stage-5A PL UART loopback link, 50MHz single clock.
set root [file normalize [file dirname [info script]]]
create_project sp_stage5a_ax7020_uart [file join $root vivado_project] -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]
foreach name {
 uart_rx.v uart_tx.v uart_fifo.v uart_crc16.v
 uart_packet_rx.v uart_packet_tx.v uart_baud_switch_ctrl.v
 uart_protocol_core.v stage5a_uart_link_top.v
} {
 add_files -norecurse [file join $root rtl $name]
}
add_files -fileset constrs_1 -norecurse [file join $root constraints stage5a_ax7020_50m_uart.xdc]
add_files -fileset sim_1 -norecurse [file join $root sim tb_stage5a_uart_link.v]
set_property top stage5a_uart_link_top [get_filesets sources_1]
set_property top tb_stage5a_uart_link [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts {Stage-5A new project created. First launch Behavioral Simulation and run all.}
puts {If PASS, run synthesis/implementation/bitstream, then AX7020 board test.}
