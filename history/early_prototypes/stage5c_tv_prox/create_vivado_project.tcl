# Vivado 2019.2 Zynq xc7z020clg400-2
set root [file normalize [file dirname [info script]]]
create_project sp_tv_stage5c [file join $root vivado_project] -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]
add_files -norecurse [file join $root rtl tv_dual_project_q11.v]
add_files -norecurse [file join $root rtl tv_prox8_q11.v]
add_files -fileset constrs_1 -norecurse [file join $root constraints tv_prox8_100mhz.xdc]
add_files -fileset sim_1 -norecurse [file join $root sim tb_tv_prox8_q11.v]
foreach n {input_pixels.mem expected_prox.mem} {
 add_files -fileset sim_1 -norecurse [file join $root data $n]
}
set_property top tv_prox8_q11 [get_filesets sources_1]
set_property top tb_tv_prox8_q11 [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts {Stage-5C project created. Click Run Behavioral Simulation, then type run all.}
