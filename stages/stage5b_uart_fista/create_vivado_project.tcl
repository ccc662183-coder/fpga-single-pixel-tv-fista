# Stage-5B AX7020: UART <-> PL TV-FISTA, Vivado 2019.2, XC7Z020-2CLG400.
# Standalone project; original Stage-4C and Stage-5A are not edited.
set root [file normalize [file dirname [info script]]]
create_project sp_stage5b_uart_fista [file join $root vivado_project] -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]
foreach name {
  uart_rx.v uart_tx.v uart_fifo.v uart_crc16.v uart_packet_rx.v uart_packet_tx.v
  sp_bram_4096x16.v sdp_bram_4096x16.v
  fwht_inplace.v fwht_q11_stage2.v data_consistency_fista_q11.v
  tv_dual_project_q11.v tv_prox64_bram_q11.v tv_fista_top_q11.v
  stage5b_uart_fista_top.v
} {
    add_files -norecurse [file join $root rtl $name]
}
add_files -fileset constrs_1 -norecurse [file join $root constraints stage5b_ax7020_50m_uart.xdc]
# Needed by synthesizable ROM initialization.
foreach name {fista_beta_q15.hex mask_4096_rowmajor.mem} {
    add_files -norecurse [file join $root data $name]
}
add_files -fileset sim_1 -norecurse [file join $root sim tb_stage5b_uart_fista_one_iter.v]
foreach name {
  cat64_measurements_q11_s32.mem cat64_expected_iter1_q11_s16.mem
  fista_beta_q15.hex mask_4096_rowmajor.mem
} {
    add_files -fileset sim_1 -norecurse [file join $root data $name]
}
set_property top stage5b_uart_fista_top [get_filesets sources_1]
set_property top tb_stage5b_uart_fista_one_iter [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts {Stage-5B: single 50MHz PL clock + fixed 1000000bps UART.}
puts {First launch Behavioral Simulation and run all (1024 measurements + one FISTA iteration + 4096 returned pixels).}
puts {After PASS: Synthesis -> Implementation -> Check Timing -> Generate Bitstream, run PC script with cat64.}
puts {Physical board design top stage5b_uart_fista_top uses default 40 outer FISTA iterations.}
