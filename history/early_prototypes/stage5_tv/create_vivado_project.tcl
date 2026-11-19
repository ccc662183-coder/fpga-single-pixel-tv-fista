# Open Vivado 2019.2 Tcl Console; cd to extracted stage5_tv, then source this file.
set root [file normalize [file dirname [info script]]]
create_project sp_tv_stage5a [file join $root vivado_project] -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]
add_files -norecurse [file join $root rtl tv_grad_div_pixel.v]
add_files -fileset constrs_1 -norecurse [file join $root constraints tv_core_100mhz.xdc]
add_files -fileset sim_1 -norecurse [file join $root sim tb_tv_grad_div_pixel.v]
foreach name {tv16_pixels.mem tv16_px.mem tv16_py.mem tv16_expected_gx.mem tv16_expected_gy.mem tv16_expected_div.mem} {
    add_files -fileset sim_1 -norecurse [file join $root data $name]
}
set_property top tv_grad_div_pixel [get_filesets sources_1]
set_property top tb_tv_grad_div_pixel [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts {Stage 5A project created. Run Behavioral Simulation; then type: run all}
