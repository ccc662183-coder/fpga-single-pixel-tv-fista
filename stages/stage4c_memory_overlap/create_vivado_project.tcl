# Stage-4C: BRAM read-prefetch and arithmetic-state overlap
# Standalone Vivado 2019.2 project, never overwrites Stage-4B.
set root [file normalize [file dirname [info script]]]
create_project sp_tv_fista_stage4c [file join $root vivado_project] -part xc7z020clg400-2 -force
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
add_files -fileset constrs_1 -norecurse [file join $root constraints stage4c_50mhz.xdc]
add_files -norecurse [file join $root data mask_4096_rowmajor.mem]
add_files -norecurse [file join $root data fista_beta_q15.hex]
foreach v {
    tb_fista_top_q11.v
    tb_tv_prox_stage4c_ab.v
    tv_prox64_bram_q11_reference.v
} {
    add_files -fileset sim_1 -norecurse [file join $root sim $v]
}
foreach n {
    mask_4096_rowmajor.mem
    fista_beta_q15.hex
    cat64_measurements_q11_s32.mem
    cat64_expected_initial_direct_q11_s16.mem
    cat64_expected_iter1_projected_q11_s16.mem
    cat64_expected_iter1_q11_s16.mem
    cat64_expected_iter1_z_q11_s16.mem
    cat64_expected_final_q11_s16.mem
    input_f_q11.mem
    expected_prox_q11.mem
} {
    add_files -fileset sim_1 -norecurse [file join $root data $n]
}
set_property top tv_fista_top_q11 [get_filesets sources_1]
set_property top tb_tv_prox_stage4c_ab [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts {Stage-4C project created. First test: independent TV Prox Stage-4B/4C A/B.}
puts {Run Behavioral Simulation -> run all; check 4096/4096 exact and saved=442332.}
puts {Then switch sim top to tb_fista_top_q11_one_iter and repeat.}
puts {Only after those pass, synthesize and implement, then check 50MHz timing.}
