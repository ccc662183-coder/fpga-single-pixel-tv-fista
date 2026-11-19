# Vivado 2019.2 project for Stage-1 64x64 BRAM TV Prox.
set root [file normalize [file dirname [info script]]]
create_project sp_tv_stage1 [file join $root vivado_project] -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]

add_files -norecurse [file join $root rtl sp_bram_4096x16.v]
add_files -norecurse [file join $root rtl sdp_bram_4096x16.v]
add_files -norecurse [file join $root rtl tv_dual_project_q11.v]
add_files -norecurse [file join $root rtl tv_prox64_bram_q11.v]

add_files -fileset constrs_1 -norecurse [file join $root constraints tv_prox64_50mhz.xdc]

add_files -fileset sim_1 -norecurse [file join $root sim tb_tv_prox64_bram_q11.v]
foreach n {input_f_q11.mem expected_prox_q11.mem} {
    add_files -fileset sim_1 -norecurse [file join $root data $n]
}

set_property top tv_prox64_bram_q11 [get_filesets sources_1]
set_property top tb_tv_prox64_bram_q11 [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts {Stage-1 project created. Run Behavioral Simulation -> run all.}
puts {After simulation passes, run Synthesis and inspect RAMB36/RAMB18 utilization.}
