# ONCE PER BASE: inputs of main_pr_rm.tcl --rw_base_dir (RapidWright child flow), from the nested base post_route.dcp.
#   vivado -mode batch -source main_pr_rwfst_base.tcl -tclargs --base_dcp <nested base post_route.dcp> --out_dir <dir>
set rw_dir [file dirname [file normalize [info script]]]
source [file dirname $rw_dir]/pr_utils.tcl
set opts [pr_parse_args $argv {base_dcp out_dir} {}]
set out [dict get $opts out_dir]
file mkdir $out
open_checkpoint [dict get $opts base_dcp]
set rp [get_cells -hierarchical -filter {HD.RECONFIGURABLE == 1 && NAME =~ WRAPPER/CL/*}]
if {[llength $rp] != 1} { error "PR: expected one nested RP in the base, found: $rp" }
set fh [open $out/rp_path.txt w]; puts $fh [get_property NAME $rp]; close $fh

# RP clock regions
set pb [get_pblocks -of $rp]
set ranges [get_property GRID_RANGES $pb]
set crs {}
foreach r $ranges {
  if {[regexp {CLOCKREGION_X(\d+)Y(\d+):CLOCKREGION_X(\d+)Y(\d+)} $r -> x0 y0 x1 y1]} {
    for {set x $x0} {$x <= $x1} {incr x} { for {set y $y0} {$y <= $y1} {incr y} { lappend crs X${x}Y${y} } }
  }
}
set crs [lsort -unique $crs]
set fh [open $out/rp_clock_regions.txt w]; puts $fh $crs; close $fh

# OOC context for the RM place step
set ck [get_pins $rp/clock]
set per [get_property PERIOD [lindex [get_clocks -of_objects $ck] 0]]
set src [get_property LOC [get_cells -of_objects [get_pins -leaf -of_objects [get_nets -of $ck] -filter {DIRECTION == OUT}]]]
set fh [open $out/rm_ooc.xdc w]
puts $fh "create_clock -name rmclk -period $per \[get_ports clock\]
set_property HD.CLK_SRC $src \[get_ports clock\]
create_pblock pblock_rm
resize_pblock pblock_rm -add {$ranges}
add_cells_to_pblock pblock_rm -top
set_property CONTAIN_ROUTING true \[get_pblocks pblock_rm\]
set_property EXCLUDE_PLACEMENT true \[get_pblocks pblock_rm\]
set_input_delay -clock rmclk [expr {$per * 0.4}] \[get_ports -filter {DIRECTION == IN && NAME != clock}\]
set_output_delay -clock rmclk [expr {$per * 0.4}] \[get_ports -filter {DIRECTION == OUT}\]"
close $fh
set fh [open $out/rm_ctx.txt w]
foreach p [get_pins -of $rp] {
  set v [get_property -quiet HD.ASSIGNED_PPLOCS $p]
  if {$v ne ""} { puts $fh "[get_property REF_PIN_NAME $p] [lindex [split [lindex $v 0] /] 0]" }
}
close $fh

# Base RM cell: partition-pin template
write_checkpoint -force -cell $rp $out/base_rp.dcp
write_edif -force -cell $rp $out/base_rp.edf

update_design -cell $rp -black_box
lock_design -level routing
write_checkpoint -force -cell WRAPPER/CL/firesim_top $out/fst_bb.dcp
write_edif -force -cell WRAPPER/CL/firesim_top $out/fst.edf

# write_checkpoint -cell drops firesim_top's routing: dump nets using the RP region
set rt [filter [get_tiles -of_objects [get_clock_regions $crs]] {TYPE =~ INT* || TYPE =~ RCLK*}]
set fh [open $out/routes.txt w]
foreach n [get_nets -quiet -of_objects $rt] {
  set ps [get_pips -quiet -of_objects $n]
  if {[llength $ps]} { puts $fh "$n [join $ps { }]" }
}
close $fh
