# Vivado 2019.2; open new project using exact directory of this TCL file.
set root [file normalize [file dirname [info script]]]
create_project sp_tv_stage5b [file join $root vivado_project] -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]
add_files -norecurse [file join $root rtl tv_dual_project_q11.v]
add_files -fileset constrs_1 -norecurse [file join $root constraints tv_projection_100mhz.xdc]
add_files -fileset sim_1 -norecurse [file join $root sim tb_tv_dual_project_q11.v]
foreach name {input_x.mem input_y.mem expected_x.mem expected_y.mem} {
    add_files -fileset sim_1 -norecurse [file join $root data $name]
}
set_property top tv_dual_project_q11 [get_filesets sources_1]
set_property top tb_tv_dual_project_q11 [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts {Stage 5B project created. Run Behavioral Simulation then type: run all}
