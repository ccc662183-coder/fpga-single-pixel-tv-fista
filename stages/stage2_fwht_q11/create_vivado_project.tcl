# Vivado 2019.2 project for Stage-2A Q5.11 FWHT adapter.
set root [file normalize [file dirname [info script]]]
create_project sp_fwht_q11_stage2 [file join $root vivado_project] -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]

add_files -norecurse [file join $root rtl fwht_inplace.v]
add_files -norecurse [file join $root rtl fwht_q11_stage2.v]
add_files -fileset constrs_1 -norecurse [file join $root constraints fwht_stage2_50mhz.xdc]

add_files -fileset sim_1 -norecurse [file join $root sim tb_fwht_q11_stage2.v]
foreach n {
    cat64_input_q11_s16.mem
    cat64_fwht_raw_q11_s32.mem
    cat64_fwht_normalized_q11_s32.mem
} {
    add_files -fileset sim_1 -norecurse [file join $root data $n]
}

set_property top fwht_q11_stage2 [get_filesets sources_1]
set_property top tb_fwht_q11_stage2 [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts {Stage-2A project created. Run Behavioral Simulation -> run all.}
puts {This phase validates the Q5.11-to-S32.F11 FWHT path and normalization only.}
