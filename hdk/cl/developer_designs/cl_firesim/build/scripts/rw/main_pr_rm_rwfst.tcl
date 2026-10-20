# =============================================================================
# PER CHILD -- prefetcher RM swap with RapidWright routing at the WRAPPER/CL/firesim_top level (AWS F2 nested DFX).
#   1. Vivado OOC PLACE of the RM synth DCP in the RP pblock (rw_rm_ooc.tcl, no OOC route)            ~3-4 min
#   2. RapidWright (RwDcp.java 'fst'): populate the black-boxed RP of the firesim_top cell DCP, re-apply the
#      RP-region routing, route RM + boundary with PartialDFXRouter (PPLOC partition pins, pblock-confined,
#      BFS fixes for dual-output LUT sources / PPLOC-less ports, LUTRAM hold detours), extract the routed RP ~1.5-2.5 min
#   3. Vivado: open base, black-box RP, lock_design -level routing, read_checkpoint -cell <routed RP>;
#      route_design only if errors/timing fail; gates; pr_recombine + partpin clear; AWS export; pr_verify ~21 min
# Needs the per-base dir from main_pr_rwfst_base.tcl and RapidWright (install_rw.sh; RW_HOME, default ~/rw).
#
#   vivado -mode batch -source main_pr_rm_rwfst.tcl -tclargs --cl_dir <dir> --build_tag <tag> \
#     --base_dcp <nested base post_route.dcp> --rm_dcp <RM rm_post_synth.dcp> --base_dir <main_pr_rwfst_base out_dir> \
#     [--pp_template <RP cell dcp with the base partpins> --pp_template_edf <its edf>] [--cl_name cl_firesim]
# =============================================================================
set script_start_time [clock seconds]
set rw_dir [file dirname [file normalize [info script]]]
set ::RWD $rw_dir
source [file dirname $rw_dir]/pr_utils.tcl
source $rw_dir/rw_common.tcl
source $rw_dir/rw_rm_ooc.tcl
source $rw_dir/vivado_stitch_routed_rm.tcl
set opts [pr_parse_args $argv {cl_dir build_tag base_dcp rm_dcp base_dir} {cl_name pp_template pp_template_edf}]
set CL_DIR [dict get $opts cl_dir]
set TAG    [dict get $opts build_tag]
set ::BASE [dict get $opts base_dcp]
set rm_dcp [dict get $opts rm_dcp]
set B      [dict get $opts base_dir]
set CL     [pr_opt $opts cl_name cl_firesim]
set tpl    [pr_opt $opts pp_template $B/base_rp.dcp]
set tpl_edf [pr_opt $opts pp_template_edf $B/base_rp.edf]
set ::SHELL [pr_env HDK_SHELL_DIR]/build/checkpoints/from_aws/cl_bb_routed.[pr_env SHELL_MODE small_shell].dcp
set fh [open $B/rp_path.txt r]; set ::RP [string trim [read $fh]]; close $fh
set fh [open $B/rp_clock_regions.txt r]; set crs [string trim [read $fh]]; close $fh
set ckdir ${CL_DIR}/build/checkpoints
file mkdir $ckdir
# 1. OOC place
set placed $ckdir/${CL}.${TAG}.rm_ooc_placed.dcp
rw_impl_rm_ooc $rm_dcp $B/rm_ooc.xdc $B/rm_ctx.txt $placed $ckdir/${CL}.${TAG}.rm_ooc_placed_edf 0
close_design
set placed_edf $ckdir/${CL}.${TAG}.rm_ooc_placed_edf/[file rootname [file tail $placed]].edf
# 2. RapidWright
if {[rw_install]} { error "PR: RapidWright install failed" }
set ::RMDCP $ckdir/${CL}.${TAG}.rm_rw_routed.dcp
set rpfst [string range $::RP [string length WRAPPER/CL/firesim_top/] end]
set pb "CLOCKREGION_[lindex [lsort $crs] 0]:CLOCKREGION_[lindex [lsort $crs] end]"
if {[rw_java fst $B/fst_bb.dcp $B/fst.edf $placed $placed_edf $rpfst $B/base_pplocs.txt - [join $crs ,] $::RMDCP 1 \
       $tpl $tpl_edf $B/routes.txt $pb]} { error "PR: RapidWright RP routing failed" }
puts "PR_TIME child_until_rw [expr {[clock seconds] - $script_start_time}]"
# 3. Vivado merge + export
set ::OUT $ckdir/${CL}.${TAG}.post_route.dcp
set ::TAG $TAG
set ::SKIP_ROUTE_IF_ROUTED 1
set ::REPAIR_ROUTE 1
set bad [rw_vivado_stitch]
if {$bad} { error "PR: firesim_top RapidWright RM swap failed $bad gate(s); see log" }
file rename -force [file rootname $::OUT]_aws.dcp ${ckdir}/${CL}.${TAG}.aws_post_route.dcp
puts "PR_TIME child_total [expr {[clock seconds] - $script_start_time}]"
puts "PR: AWS export: ${ckdir}/${CL}.${TAG}.aws_post_route.dcp"
