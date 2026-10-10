# Export the outer AWS RP without replacing the nested implementation base.
set scripts_dir [file dirname [file normalize [info script]]]
source ${scripts_dir}/pr_utils.tcl
set opts [pr_parse_args $argv {base_dcp output_dcp}]
set base_dcp [dict get $opts base_dcp]
set output_dcp [dict get $opts output_dcp]
if {[file normalize $base_dcp] eq [file normalize $output_dcp]} {
    error "PR: AWS export must not overwrite the nested checkpoint"
}
open_checkpoint $base_dcp
set parent [get_cells WRAPPER/CL]
if {![get_property HD.RECONFIGURABLE_CONTAINER $parent]} {
    error "PR: AWS export requires a nested WRAPPER/CL container"
}
pr_check_routed "nested checkpoint before AWS export"
pr_recombine -cell WRAPPER/CL
set partitions [get_cells -hierarchical -filter {HD.RECONFIGURABLE == 1}]
if {[llength $partitions] != 1 || [get_property NAME [lindex $partitions 0]] ne "WRAPPER/CL"} {
    error "PR: expected WRAPPER/CL as the sole RP after recombination"
}
pr_check_routed "recombined AWS export"
write_checkpoint -force $output_dcp
close_design
puts "PR: AWS outer-CL export: $output_dcp; nested base preserved: $base_dcp"
