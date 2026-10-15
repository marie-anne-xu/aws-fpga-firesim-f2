# =============================================================================
# CHILD (RM swap) PR flow with a PRE-IMPLEMENTED RM -- AWS F2 nested DFX, non-project mode.
#
# Alternative to ../main_pr_rm.tcl that never runs place_design against the full ~640k-cell design:
#   1. context (once per base, cached in --ctx_dir): RP pblock, RP clock period + HD.CLK_SRC, PPLOC per RP port
#   2. out-of-context implementation of the RM synth DCP alone (HD.RECONFIGURABLE top, RP pblock,
#      HD.PARTPIN_LOCS = base PPLOC tiles), ~4 min
#   3. open base, black-box RP, lock_design -level routing, read_checkpoint -cell <OOC-routed RM>
#      (keeps the RM placement/routing), route_design only if the import left unrouted/errored nets
#   4. canonical gates + fused AWS export (pr_recombine, partpin-prop clear) + pr_verify vs the AWS shell
#
# RapidWright was evaluated for steps 3/4 and is not usable here: the base's netlist cannot be exported
# readable (write_edif: EDIF 20-92 on the AWS-protected top, Designutils 20-2284 IEEE-1735 IP in WRAPPER/CL).
#
#   vivado -mode batch -source main_pr_rm_preimpl.tcl -tclargs \
#     --cl_dir <dir> --build_tag <tag> --base_dcp <nested base post_route.dcp> --rm_dcp <RM rm_post_synth.dcp> \
#     [--cl_name <name>] [--ctx_dir <dir>] [--skip_route_if_routed 1]
# =============================================================================
set script_start_time [clock seconds]
set rw_dir [file dirname [file normalize [info script]]]
source [file dirname $rw_dir]/pr_utils.tcl
source $rw_dir/rw_common.tcl
source $rw_dir/rw_rm_ooc.tcl
source $rw_dir/vivado_stitch_routed_rm.tcl

set opts [pr_parse_args $argv {cl_dir build_tag base_dcp rm_dcp} {cl_name ctx_dir skip_route_if_routed}]
set CL_DIR   [dict get $opts cl_dir]
set TAG      [dict get $opts build_tag]
set ::BASE   [dict get $opts base_dcp]
set rm_dcp   [dict get $opts rm_dcp]
set CL       [pr_opt $opts cl_name cl_firesim]
set ctx_dir  [pr_opt $opts ctx_dir [file rootname $::BASE].rmctx]
set ::SKIP_ROUTE_IF_ROUTED [pr_opt $opts skip_route_if_routed 1]
set ::SHELL  [pr_env HDK_SHELL_DIR]/build/checkpoints/from_aws/cl_bb_routed.[pr_env SHELL_MODE small_shell].dcp

set checkpoints_dir ${CL_DIR}/build/checkpoints
set reports_dir     ${CL_DIR}/build/reports
file mkdir $checkpoints_dir $reports_dir $ctx_dir
foreach f [list $::BASE $rm_dcp $::SHELL] { if {![file exists $f]} { error "PR: checkpoint not found: $f" } }

# 1. per-base context
set xdc $ctx_dir/rm_ooc.xdc
set ctx $ctx_dir/rm_ctx.txt
if {![file exists $xdc] || ![file exists $ctx] || [file mtime $xdc] < [file mtime $::BASE]} {
    rw_timed ctx_open_base [list open_checkpoint $::BASE]
    set rp [get_cells -quiet -hierarchical -filter {HD.RECONFIGURABLE == 1 && NAME =~ WRAPPER/CL/*}]
    if {[llength $rp] != 1} { error "PR: expected one nested RP in the base, found: $rp" }
    set ::RP [get_property NAME $rp]
    rw_write_ooc_context $xdc $ctx
    set fh [open $ctx_dir/rp_path.txt w]; puts $fh $::RP; close $fh
    close_design
}
set fh [open $ctx_dir/rp_path.txt r]; set ::RP [string trim [read $fh]]; close $fh

# 2. OOC implementation of the RM
set ::RMDCP ${checkpoints_dir}/${CL}.${TAG}.rm_ooc_routed.dcp
rw_impl_rm_ooc $rm_dcp $xdc $ctx $::RMDCP ""
close_design

# 3+4. stitch, gates, nested child + fused AWS export + pr_verify
set ::OUT ${checkpoints_dir}/${CL}.${TAG}.post_route.dcp
set ::TAG $TAG
set bad [rw_vivado_stitch]
if {$bad} { error "PR: pre-implemented RM swap failed $bad gate(s); see log" }
file rename -force [file rootname $::OUT]_aws.dcp ${checkpoints_dir}/${CL}.${TAG}.aws_post_route.dcp
puts "PR: =========================================="
puts "PR: pre-implemented RM swap complete in [expr {[clock seconds] - $script_start_time}]s"
puts "PR: AWS export: ${checkpoints_dir}/${CL}.${TAG}.aws_post_route.dcp"
puts "PR: =========================================="
