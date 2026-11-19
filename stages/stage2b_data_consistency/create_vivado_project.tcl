# Stage-2B: Data-consistency gradient step, Vivado 2019.2, XC7Z020-2CLG400.
set root [file normalize [file dirname [info script]]]
create_project sp_stage2b_consistency [file join $root vivado_project] -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]

foreach v {
    fwht_inplace.v
    fwht_q11_stage2.v
    data_consistency_q11.v
} {
    add_files -norecurse [file join $root rtl $v]
}
add_files -fileset constrs_1 -norecurse [file join $root constraints stage2b_50mhz.xdc]
add_files -fileset sim_1 -norecurse [file join $root sim tb_data_consistency_q11.v]

# The mask is a compile-time ROM in RTL and must be available to both
# synthesis and behavioral simulation. Other .mem files are testbench data.
add_files -norecurse [file join $root data mask_4096_rowmajor.mem]
add_files -fileset sim_1 -norecurse [file join $root data mask_4096_rowmajor.mem]
foreach n {
    measurements_1024_q11_s32.mem
    input_direct_q11_s16.mem
    input_original_q11_s16.mem
    input_perturbed_q11_s16.mem
    input_zero_q11_s16.mem
    expected_direct_q11_s16.mem
    expected_original_q11_s16.mem
    expected_perturbed_q11_s16.mem
    expected_zero_q11_s16.mem
} {
    add_files -fileset sim_1 -norecurse [file join $root data $n]
}

set_property top data_consistency_q11 [get_filesets sources_1]
set_property top tb_data_consistency_q11 [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts {Stage-2B project created. Run Behavioral Simulation -> run all.}
puts {Expected: all 4 test images, 16384/16384 outputs, exactly match Stage-0.2 vectors.}
puts {Only start synthesis after the behavioral simulation passes.}
