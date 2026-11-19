# Open Vivado 2019.2 > Tcl Console > cd <unzipped stage4_hw> > source create_vivado_project.tcl
set project_root [file normalize [file dirname [info script]]]
set project_dir [file join $project_root vivado_project]
create_project sp_fwht_stage4 $project_dir -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]
add_files -norecurse [file join $project_root rtl fwht_inplace.v]
add_files -fileset sim_1 -norecurse [file join $project_root sim tb_fwht_inplace.v]
add_files -fileset sim_1 -norecurse [file join $project_root data fwht64_input.mem]
add_files -fileset sim_1 -norecurse [file join $project_root data fwht64_expected.mem]
set_property top fwht_inplace [get_filesets sources_1]
set_property top tb_fwht_inplace [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts {Project created. Next: Run Simulation > Run Behavioral Simulation; then in Tcl Console: run all}
puts {If xsim cannot locate .mem files: ensure both data/*.mem appear in Simulation Sources, and copy them to xsim working directory if necessary.}
