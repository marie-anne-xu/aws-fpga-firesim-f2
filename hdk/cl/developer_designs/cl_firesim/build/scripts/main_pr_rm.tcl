# =============================================================================
# CHILD (RM swap) PR flow -- AWS F2, non-project mode.
# Counterpart of platforms/xilinx_alveo_u250/cl_firesim/scripts/main_pr_rm.tcl.
#
# Own vivado invocation; never enters build_all.tcl. Uses UG909 "Method 4"
# (open base, lock, drop RM in, P&R in place) rather than U250's abstract-shell
# + merge, since abstract shells yield partial bitstreams only and F2 needs a
# full routed DCP. Ends in write_checkpoint -- no local bitgen on F2.
#
# Invocation (build-bitstream.sh owns this vivado call, so args come in as
# tclargs -- named rather than positional):
#
#   vivado -mode batch -source main_pr_rm.tcl -tclargs \
#     --cl_dir <dir> --build_tag <tag> --base_dcp <dcp> --rm_dcp <dcp> \
#     [--cl_name <name>] [--pr_partition_path <hier/path>]
#
# --pr_partition_path overrides the path the base build recorded.
# =============================================================================

set script_start_time [clock seconds]
set scripts_dir [file dirname [file normalize [info script]]]
source ${scripts_dir}/pr_utils.tcl

set opts [pr_parse_args $argv \
              {cl_dir build_tag base_dcp rm_dcp} \
              {cl_name pr_partition_path}]

set CL_DIR   [dict get $opts cl_dir]
set TAG      [dict get $opts build_tag]
set base_dcp [dict get $opts base_dcp]
set rm_dcp   [dict get $opts rm_dcp]
set CL       [pr_opt $opts cl_name cl_firesim]

set checkpoints_dir ${CL_DIR}/build/checkpoints
set reports_dir     ${CL_DIR}/build/reports
file mkdir $checkpoints_dir $reports_dir
set out_dcp ${checkpoints_dir}/${CL}.${TAG}.post_route.dcp
if {[file normalize $base_dcp] eq [file normalize $out_dcp]} {
    error "PR: RM output must differ from the base checkpoint; preserve the base for pr_verify"
}

foreach f [list $base_dcp $rm_dcp] {
    if {![file exists $f]} { error "PR: checkpoint not found: $f" }
}

# Explicit path wins; otherwise use what the base build recorded.
set pr_partition_paths [pr_split [pr_opt $opts pr_partition_path]]
if {[llength $pr_partition_paths] == 0} {
    lassign [pr_read_paths ${checkpoints_dir}/${CL}.pr_partition_paths.txt] \
            pr_module_names pr_partition_paths
}
if {[llength $pr_partition_paths] != 1} {
    error "PR: expected exactly 1 partition, found [llength $pr_partition_paths].\
           Multi-partition swaps are not supported yet."
}
set pr_partition_path [lindex $pr_partition_paths 0]

# Paths recorded at synthesis are CL-scoped, but the base checkpoint is the full
# design, where the cell sits under WRAPPER/CL. Normalize so either form works.
if {![string match "WRAPPER/*" $pr_partition_path]} {
    set pr_partition_path WRAPPER/CL/$pr_partition_path
}

puts "PR: RM swap configuration"
puts "PR:   base DCP      : $base_dcp"
puts "PR:   RM DCP        : $rm_dcp"
puts "PR:   partition path: $pr_partition_path"

# UG909 Method 4. lock_design freezes both the AWS shell and the FireSim CL
# static, so only the unlocked RP moves during the P&R below.
puts "PR: opening base routed checkpoint"
open_checkpoint $base_dcp

puts "PR: black-boxing $pr_partition_path"
update_design -cell $pr_partition_path -black_box

puts "PR: locking static routing (AWS shell + FireSim CL)"
lock_design -level routing

puts "PR: reading RM checkpoint into the partition"
read_checkpoint -cell $pr_partition_path $rm_dcp

# Implement only the RM; the static is locked.
opt_design
place_design
phys_opt_design
route_design -tns_cleanup

# Last chance to catch a bad stitch before a multi-hour AFI bake.
pr_check_routed "RM implementation"

report_timing_summary -report_unconstrained -file ${reports_dir}/${CL}.${TAG}.pr_rm_timing_summary.rpt
report_bus_skew -file ${reports_dir}/${CL}.${TAG}.pr_rm_bus_skew.rpt
check_timing -verbose -file ${reports_dir}/${CL}.${TAG}.pr_rm_check_timing.rpt
report_exceptions -coverage -file ${reports_dir}/${CL}.${TAG}.pr_rm_exceptions_coverage.rpt
report_exceptions -ignored -file ${reports_dir}/${CL}.${TAG}.pr_rm_exceptions_ignored.rpt
report_utilization -cells [get_cells $pr_partition_path] \
                   -file ${reports_dir}/${CL}.${TAG}.pr_rm_utilization.rpt

if {[llength [get_timing_paths -quiet -max_paths 1 -slack_lesser_than 0]] > 0} {
    puts "PR: WARNING -- timing is violated after the RM swap."
    puts "PR: aws_build_dcp_from_cl.py ships a VIOLATED dcp with only a warning\
          (see :127-133); this design may not function."
}

# Name it what generate_dcp_tarball() expects, so AWS's own code writes the
# manifest and its DCP sha256 (AFI_Manifest.md:5: never hand-edit it).
puts "PR: writing stitched checkpoint: $out_dcp"
write_checkpoint -force $out_dcp

write_debug_probes -no_partial_ltxfile -force ${checkpoints_dir}/${TAG}.debug_probes.ltx

close_design

# Routing alone does not prove a partial configuration is compatible. Verify
# that static placement, routing, proxy logic, and clock spines match the base.
puts "PR: verifying static compatibility against the nested base"
pr_verify -full_check -initial $base_dcp -additional [list $out_dcp] \
    -file ${reports_dir}/${CL}.${TAG}.pr_rm_verify.rpt

puts "PR: =========================================="
puts "PR: RM swap complete in [expr {[clock seconds] - $script_start_time}]s"
puts "PR: package with aws_build_dcp_from_cl.py, then create-fpga-image"
puts "PR: =========================================="
