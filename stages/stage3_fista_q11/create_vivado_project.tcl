# Stage-3 TV-FISTA integration project, Vivado 2019.2, XC7Z020-CLG400-2.
set root [file normalize [file dirname [info script]]]
create_project sp_tv_fista_stage3 [file join $root vivado_project] -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]

foreach v {
    sp_bram_4096x16.v
    sdp_bram_4096x16.v
    tv_dual_project_q11.v
    tv_prox64_bram_q11.v
    fwht_inplace.v
    fwht_q11_stage2.v
    data_consistency_fista_q11.v
    tv_fista_top_q11.v
} {
    add_files -norecurse [file join $root rtl $v]
}

add_files -fileset constrs_1 -norecurse [file join $root constraints stage3_50mhz.xdc]

# ROM initialization files are design sources (required for synthesis and sim).
add_files -norecurse [file join $root data mask_4096_rowmajor.mem]
add_files -norecurse [file join $root data fista_beta_q15.hex]

add_files -fileset sim_1 -norecurse [file join $root sim tb_fista_top_q11.v]
foreach n {
    mask_4096_rowmajor.mem
    fista_beta_q15.hex
    cat64_measurements_q11_s32.mem
    cat64_expected_initial_direct_q11_s16.mem
    cat64_expected_iter1_projected_q11_s16.mem
    cat64_expected_iter1_q11_s16.mem
    cat64_expected_iter1_z_q11_s16.mem
    cat64_expected_final_q11_s16.mem
} {
    add_files -fileset sim_1 -norecurse [file join $root data $n]
}

set_property top tv_fista_top_q11 [get_filesets sources_1]
set_property top tb_fista_top_q11_one_iter [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts {Stage-3 project created. Default simulation top is tb_fista_top_q11_one_iter.}
puts {Run Behavioral Simulation -> run all. Expected: 4096/4096 exact after one complete FISTA iteration.}
puts {After one-iteration PASS, select tb_fista_top_q11_full for the 40-iteration test.}
puts {The 40-iteration XSim test is long; expect roughly tens of minutes.}
