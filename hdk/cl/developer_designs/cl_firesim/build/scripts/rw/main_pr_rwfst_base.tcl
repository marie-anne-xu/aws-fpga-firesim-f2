# =============================================================================
# ONCE PER BASE -- inputs for the firesim_top-level RapidWright child flow (main_pr_rm_rwfst.tcl).
# AWS F2 nested DFX, non-project mode. Writes into --out_dir:
#   base_pplocs.txt          RP pin -> base PPLOC node(s)
#   rm_ooc.xdc rm_ctx.txt    OOC context for the RM place step (pblock, clock, HD.CLK_SRC, PPLOC tile per port)
#   base_rp.dcp/.edf         the base's own RM cell (partition-pin template, incl. clock partpins)
#   blockers.txt             P probe: nets using the RP region with no pin inside firesim_top
#   fst_bb.dcp fst.edf       WRAPPER/CL/firesim_top cell DCP (RP black-boxed, static locked) + readable EDIF
#   routes.txt               routing of every net using the RP clock regions (the cell DCP carries almost none)
#
#   vivado -mode batch -source main_pr_rwfst_base.tcl -tclargs --base_dcp <nested base post_route.dcp> --out_dir <dir>
# =============================================================================
set t_start [clock seconds]
set rw_dir [file dirname [file normalize [info script]]]
source [file dirname $rw_dir]/pr_utils.tcl
source $rw_dir/rw_common.tcl
source $rw_dir/rw_rm_ooc.tcl
source $rw_dir/rw_fst.tcl
set opts [pr_parse_args $argv {base_dcp out_dir} {skip_probe}]
set base [dict get $opts base_dcp]
set out  [dict get $opts out_dir]
file mkdir $out
rw_timed base_open [list open_checkpoint $base]
set rp [get_cells -quiet -hierarchical -filter {HD.RECONFIGURABLE == 1 && NAME =~ WRAPPER/CL/*}]
if {[llength $rp] != 1} { error "PR: expected one nested RP in the base, found: $rp" }
set ::RP [get_property NAME $rp]
set ::RPFST [string range $::RP [string length $::FST/] end]
set fh [open $out/rp_path.txt w]; puts $fh $::RP; close $fh
rw_dump_pplocs $out/base_pplocs.txt
rw_write_ooc_context $out/rm_ooc.xdc $out/rm_ctx.txt
set fh [open $out/rp_clock_regions.txt w]; puts $fh [rw_rp_clock_regions]; close $fh
rw_timed base_rp_template [list write_checkpoint -force -cell $::RP $out/base_rp.dcp]
rw_timed base_rp_template_edif [list rw_write_readable_edif $::RP $out/base_rp_edf base_rp]
file copy -force $out/base_rp_edf/base_rp.edf $out/base_rp.edf
if {![pr_opt $opts skip_probe 0]} { rw_timed P_probe [list rw_fst_probe $out/blockers.txt] }
rw_timed fst_export [list rw_fst_export $out/fst_bb.dcp $out/fst_edf]
file copy -force $out/fst_edf/fst.edf $out/fst.edf
rw_timed dump_routes [list rw_fst_dump_routes $out/routes.txt]
puts "PR: rwfst base prep done in [expr {[clock seconds] - $t_start}] s -> $out"
