# Export the outer AWS RP without replacing the nested implementation base.
# Validated recipe (trial x3_recombine_route_preserve):
#   pr_recombine WRAPPER/CL, then clear the stale HD.PARTPIN_LOCS/RANGE left on
#   the former nested RP's pins. Without that, report_route_status counts every
#   boundary net (70) as "some unplaced pins" although all are routed and
#   unchanged. No placement or routing is modified.
# The export is checked against the AWS shell DCP with pr_verify (what AWS bitgen
# checks). pr_verify against the nested base always fails (HDPRVerify-22:
# container count differs after recombine), so it is not used.
set scripts_dir [file dirname [file normalize [info script]]]
source ${scripts_dir}/pr_utils.tcl
set opts [pr_parse_args $argv {base_dcp output_dcp} {shell_dcp}]
set base_dcp [dict get $opts base_dcp]
set output_dcp [dict get $opts output_dcp]
if {[file normalize $base_dcp] eq [file normalize $output_dcp]} {
    error "PR: AWS export must not overwrite the nested checkpoint"
}
set HDK_SHELL_DIR [pr_env HDK_SHELL_DIR]
set SHELL_MODE    [pr_env SHELL_MODE small_shell]
set shell_dcp [pr_opt $opts shell_dcp ${HDK_SHELL_DIR}/build/checkpoints/from_aws/cl_bb_routed.${SHELL_MODE}.dcp]
foreach f [list $base_dcp $shell_dcp] {
    if {![file exists $f]} { error "PR: missing input checkpoint $f (HDK_SHELL_DIR set?)" }
}

open_checkpoint $base_dcp
set parent [get_cells WRAPPER/CL]
if {![get_property HD.RECONFIGURABLE_CONTAINER $parent]} {
    error "PR: AWS export requires a nested WRAPPER/CL container"
}
pr_check_routed "nested checkpoint before AWS export"

# The nested child RP(s); their pins carry the partition-pin props to clear.
set children [get_cells -quiet -hierarchical -filter {HD.RECONFIGURABLE == 1 && NAME =~ WRAPPER/CL/*}]
if {[llength $children] == 0} { error "PR: no nested RP found under WRAPPER/CL" }
puts "PR: nested RP(s): $children"

pr_recombine -cell WRAPPER/CL
set partitions [get_cells -hierarchical -filter {HD.RECONFIGURABLE == 1}]
if {[llength $partitions] != 1 || [get_property NAME [lindex $partitions 0]] ne "WRAPPER/CL"} {
    error "PR: expected WRAPPER/CL as the sole RP after recombination"
}

# pr_recombine keeps HD.PARTPIN_RANGE on the former child's pins; the boundary
# nets then report as having unplaced pins. Clear them (props only).
set cleared 0
foreach child $children {
    foreach p [get_pins -quiet -of_objects [get_cells $child]] {
        foreach pr {HD.PARTPIN_LOCS HD.PARTPIN_RANGE} {
            if {[get_property -quiet $pr $p] ne ""} { reset_property $pr $p; incr cleared }
        }
    }
}
puts "PR: cleared $cleared stale partition-pin properties on former nested RP pins"

# Guards: routing (hard stop), timing, DFX DRC.
pr_check_routed "recombined AWS export"
pr_check_timing_met "recombined AWS export"
pr_check_hdpr_drc "recombined AWS export" [file rootname $output_dcp].hdpr_drc.rpt
# BOOTFIX: never ship an AFI whose DDR calibration BRAM is empty.
pr_require_mig_bram "recombined AWS export"
write_checkpoint -force $output_dcp
close_design

# Recombination must not change the AWS static design: compare the export with
# the AWS shell checkpoint (static placement/routing, partition interface).
set verify_rpt [file rootname $output_dcp].pr_verify.rpt
puts "PR: pr_verify $shell_dcp vs $output_dcp"
if {[catch {pr_verify -full_check -file $verify_rpt -initial $shell_dcp -additional [list $output_dcp]} verify_msg]} {
    error "PR: pr_verify failed between AWS shell and export (see $verify_rpt): $verify_msg"
}
set verify_txt ""
if {[file exists $verify_rpt]} {
    set fh [open $verify_rpt r]; set verify_txt [read $fh]; close $fh
}
if {[regexp -nocase {not compatible|incompatible} "$verify_msg\n$verify_txt"] ||
    ![regexp {are compatible} $verify_txt]} {
    error "PR: pr_verify does not report AWS shell and export compatible (see $verify_rpt)"
}
puts "PR: pr_verify passed: $verify_rpt"
puts "PR: AWS outer-CL export: $output_dcp; nested base preserved: $base_dcp"
