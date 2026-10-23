# Child flow: swap a new prefetcher RM into the routed nested base (open base, lock static,
# read RM, P&R in place), then write the nested child and the recombined AWS export.
#   vivado -mode batch -source main_pr_rm.tcl -tclargs --cl_dir <dir> --build_tag <tag> \
#     --base_dcp <dcp> --rm_dcp <dcp> [--cl_name <name>] [--pr_partition_path <hier/path>] [--rw_base_dir <dir>]
# --rw_base_dir (rw/main_pr_rwfst_base.tcl output): route the RM with RapidWright first; if that
# fails or is not clean with timing met, the normal in-place P&R flow runs instead.

set script_start_time [clock seconds]
set scripts_dir [file dirname [file normalize [info script]]]
source ${scripts_dir}/pr_utils.tcl
# PR_TIME <step> <seconds> lines for the build log.
proc pr_t {step script} {
    set t0 [clock milliseconds]
    uplevel 1 $script
    puts "PR_TIME $step [expr {([clock milliseconds] - $t0) / 1000.0}]"
}

set opts [pr_parse_args $argv \
              {cl_dir build_tag base_dcp rm_dcp} \
              {cl_name pr_partition_path rw_base_dir}]

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
set rw_base_dir [pr_opt $opts rw_base_dir]
set rm_synth_dcp $rm_dcp
if {$rw_base_dir ne ""} {
    source ${scripts_dir}/rw/rw_common.tcl
    if {[catch {rw_route_rm $rm_dcp $rw_base_dir ${checkpoints_dir}/${CL}.${TAG}} rw_dcp]} {
        puts "PR: RapidWright failed ($rw_dcp); using the normal pr flow"
        while {[llength [get_designs -quiet]]} { close_design }
        set rw_base_dir ""
    } else {
        set rm_dcp $rw_dcp
    }
}

# Explicit path wins; otherwise use what the base build recorded.
set pr_partition_paths [pr_split [pr_opt $opts pr_partition_path]]
# A child's own CL dir has no pr_partition_paths.txt: find the RP in the base instead.
set pr_paths_file ${checkpoints_dir}/${CL}.pr_partition_paths.txt
set pr_discover_from_base 0
if {[llength $pr_partition_paths] == 0} {
    if {[file exists $pr_paths_file]} {
        lassign [pr_read_paths $pr_paths_file] pr_module_names pr_partition_paths
    } else {
        puts "PR: $pr_paths_file not found; will discover the nested RP from the base checkpoint"
        set pr_discover_from_base 1
        set pr_partition_paths [list __from_base__]
    }
}
if {[llength $pr_partition_paths] != 1} {
    error "PR: expected exactly 1 partition, found [llength $pr_partition_paths].\
           Multi-partition swaps are not supported yet."
}
set pr_partition_path [lindex $pr_partition_paths 0]

# Synthesis records CL-scoped paths; the base is the full design.
if {![string match "WRAPPER/*" $pr_partition_path]} {
    set pr_partition_path WRAPPER/CL/$pr_partition_path
}

puts "PR: RM swap configuration"
puts "PR:   base DCP      : $base_dcp"
puts "PR:   RM DCP        : $rm_dcp"
puts "PR:   partition path: $pr_partition_path"

# Lock the AWS shell and FireSim static so only the RP is placed and routed.
puts "PR: opening base routed checkpoint"
pr_t open_base {open_checkpoint $base_dcp}
pr_check_ddr_bram
if {$pr_discover_from_base} {
    set rp_cells [get_cells -quiet -hierarchical -filter {HD.RECONFIGURABLE == 1 && NAME =~ WRAPPER/CL/*}]
    if {[llength $rp_cells] != 1} {
        error "PR: expected exactly 1 nested RP under WRAPPER/CL in the base, found [llength $rp_cells]: $rp_cells"
    }
    set pr_partition_path [get_property NAME [lindex $rp_cells 0]]
    puts "PR:   partition path (from base): $pr_partition_path"
}

puts "PR: black-boxing $pr_partition_path"
pr_t black_box {update_design -cell $pr_partition_path -black_box}

puts "PR: locking static routing (AWS shell + FireSim CL)"
pr_t lock {lock_design -level routing}

puts "PR: reading RM checkpoint into the partition"
pr_t read_rm {read_checkpoint -cell $pr_partition_path $rm_dcp}

# RapidWright result not clean: swap the synthesized RM back in for the normal PR flow.
if {$rw_base_dir ne "" && ![rw_rm_routed]} {
    puts "PR: RapidWright RM not routed clean with timing met; using the normal pr flow"
    pr_t black_box_rw {update_design -cell $pr_partition_path -black_box}
    pr_t read_rm_synth {read_checkpoint -cell $pr_partition_path $rm_synth_dcp}
    set rw_base_dir ""
}
if {$rw_base_dir ne ""} {
    puts "PR: RapidWright-routed RM imported fully routed; skipping opt/place/route"
} else {
# Quick place keeps the swap short; Default route (not Quick) is needed to close hold.
pr_t opt {opt_design}
pr_t place {place_design -directive Quick}
pr_t route {route_design -directive Default}
}

# Fail before the AFI build, not after it.
pr_check_routed "RM implementation"
pr_check_timing_met "RM implementation"

# Informational reports must not kill a multi-hour build.
if {[catch {
report_timing_summary -report_unconstrained -file ${reports_dir}/${CL}.${TAG}.pr_rm_timing_summary.rpt
report_bus_skew -file ${reports_dir}/${CL}.${TAG}.pr_rm_bus_skew.rpt
check_timing -verbose -file ${reports_dir}/${CL}.${TAG}.pr_rm_check_timing.rpt
report_exceptions -coverage -file ${reports_dir}/${CL}.${TAG}.pr_rm_exceptions_coverage.rpt
report_exceptions -ignored -file ${reports_dir}/${CL}.${TAG}.pr_rm_exceptions_ignored.rpt
report_utilization -cells [get_cells $pr_partition_path] \
                   -file ${reports_dir}/${CL}.${TAG}.pr_rm_utilization.rpt
} rep_err]} { puts "PR: WARNING -- report generation failed: $rep_err" }

if {[llength [get_timing_paths -quiet -max_paths 1 -slack_lesser_than 0]] > 0} {
    puts "PR: WARNING -- timing is violated after the RM swap."
    puts "PR: aws_build_dcp_from_cl.py ships a VIOLATED dcp with only a warning; this design may not function."
}

# Name expected by AWS generate_dcp_tarball(), which writes the manifest + sha256.
puts "PR: writing stitched checkpoint: $out_dcp"
pr_t write {write_checkpoint -force $out_dcp}

if {[catch {write_debug_probes -no_partial_ltxfile -force ${checkpoints_dir}/${TAG}.debug_probes.ltx} dbg_err]} { puts "PR: WARNING -- write_debug_probes: $dbg_err" }

# AWS export in the same session (as main_pr_export.tcl): AWS ingest needs WRAPPER/CL as
# the only RP, so recombine after writing the nested child, which stays the base for swaps.
set aws_dcp ${checkpoints_dir}/${CL}.${TAG}.aws_post_route.dcp
pr_t recombine {pr_recombine -cell WRAPPER/CL}
set partitions [get_cells -hierarchical -filter {HD.RECONFIGURABLE == 1}]
if {[llength $partitions] != 1 || [get_property NAME [lindex $partitions 0]] ne "WRAPPER/CL"} {
    error "PR: expected WRAPPER/CL as the sole RP after recombination"
}
# pr_recombine leaves partition-pin props on the former RP pins (reported as unplaced pins).
set cleared 0
foreach p [get_pins -quiet -of_objects [get_cells $pr_partition_path]] {
    foreach pr {HD.PARTPIN_LOCS HD.PARTPIN_RANGE} {
        if {[get_property -quiet $pr $p] ne ""} { reset_property $pr $p; incr cleared }
    }
}
puts "PR: cleared $cleared stale partition-pin properties on former nested RP pins"
pr_check_routed "recombined AWS export"
pr_check_timing_met "recombined AWS export"
pr_check_hdpr_drc "recombined AWS export" [file rootname $aws_dcp].hdpr_drc.rpt
pr_check_ddr_bram
pr_t write_export {write_checkpoint -force $aws_dcp}
close_design

# The check AWS ingest runs: export vs the AWS shell.
set HDK_SHELL_DIR [pr_env HDK_SHELL_DIR]
set shell_dcp ${HDK_SHELL_DIR}/build/checkpoints/from_aws/cl_bb_routed.[pr_env SHELL_MODE small_shell].dcp
set verify_rpt [file rootname $aws_dcp].pr_verify.rpt
pr_t pr_verify_shell {pr_verify -full_check -file $verify_rpt -initial $shell_dcp -additional [list $aws_dcp]}
set fh [open $verify_rpt r]; set vtxt [read $fh]; close $fh
if {![regexp {are compatible} $vtxt]} { error "PR: AWS shell vs export not compatible (see $verify_rpt)" }

# Optional (FIRESIM_PR_VERIFY_BASE=1): child vs nested base; static is locked, so usually redundant.
if {[pr_env FIRESIM_PR_VERIFY_BASE 0]} {
    puts "PR: verifying static compatibility against the nested base"
    pr_t pr_verify {pr_verify -full_check -initial $base_dcp -additional [list $out_dcp] \
        -file ${reports_dir}/${CL}.${TAG}.pr_rm_verify.rpt}
}

puts "PR: =========================================="
puts "PR: RM swap complete in [expr {[clock seconds] - $script_start_time}]s"
puts "PR: package with aws_build_dcp_from_cl.py, then create-fpga-image"
puts "PR: =========================================="
