# RapidWright child-flow steps for main_pr_rm.tcl --rw_base_dir (base dir from rw/main_pr_rwfst_base.tcl).
set ::RWD [file dirname [file normalize [info script]]]

proc rw_install {} {
  return [catch {exec bash $::RWD/install_rw.sh >@ stdout 2>@ stderr}]
}

proc rw_java {args} {
  return [catch {exec bash $::RWD/run_rw.sh {*}$args >@ stdout 2>@ stderr}]
}

# OOC-place the RM synth DCP in the base's RP context; write DCP + EDIF.
proc rw_place_rm_ooc {rm b out} {
  open_checkpoint $rm
  # read_checkpoint -cell into the RP refuses an HD.PARTITION OOC module
  set_property HD.RECONFIGURABLE 1 [current_design]
  read_xdc -mode out_of_context $b/rm_ooc.xdc
  # Load-less inputs get a DONT_TOUCH LUT1 load, else their static stubs are antennas after pr_recombine.
  set i 0
  foreach p [get_ports -quiet -filter {DIRECTION == IN && NAME != clock}] {
    set n [get_nets -quiet -of_objects $p]
    if {[llength $n] && [llength [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == IN}]]} continue
    set c [create_cell -reference LUT1 rwf_in_load_$i]
    set_property INIT 2'h2 $c
    set_property DONT_TOUCH 1 $c
    if {![llength $n]} { set n [create_net rwf_in_net_$i]; connect_net -net $n -objects [list $p] }
    connect_net -net $n -objects [list [get_pins rwf_in_load_$i/I0]]
    incr i
  }
  set fh [open $b/rm_ctx.txt r]
  foreach line [split [string trim [read $fh]] "\n"] {
    lassign $line port tile
    set p [get_ports $port]
    if {[llength [get_nets -quiet -of_objects $p]]} { set_property HD.PARTPIN_LOCS $tile $p }
  }
  close $fh
  opt_design
  place_design
  write_checkpoint -force $out
  write_edif -force [file rootname $out].edf
  close_design
}

# OOC place + RapidWright route of the RM; returns the routed RM cell DCP.
proc rw_route_rm {rm b prefix} {
  set fh [open $b/rp_path.txt r]; set rp [string trim [read $fh]]; close $fh
  set fh [open $b/rp_clock_regions.txt r]; set crs [string trim [read $fh]]; close $fh
  pr_t rw_ooc_place {rw_place_rm_ooc $rm $b ${prefix}.rm_ooc_placed.dcp}
  pr_t rw_install {set rc [rw_install]}
  if {$rc} { error "PR: RapidWright install failed" }
  set out ${prefix}.rm_rw_routed.dcp
  set pb "CLOCKREGION_[lindex $crs 0]:CLOCKREGION_[lindex $crs end]"
  # write_edif -cell writes <dir>/<ref>/<ref>.edn
  pr_t rw_route {set rc [rw_java $b/fst_bb.dcp [glob $b/fst.edf/*/*.edn] ${prefix}.rm_ooc_placed.dcp \
      ${prefix}.rm_ooc_placed.edf [string range $rp [string length WRAPPER/CL/firesim_top/] end] [join $crs ,] $out \
      $b/base_rp.dcp [glob $b/base_rp.edf/*/*.edn] $b/routes.txt $pb]}
  if {$rc} { error "PR: RapidWright RP routing failed" }
  return $out
}

# After read_checkpoint -cell: drop the RM's OOC pblock; 1 if fully routed.
proc rw_rm_routed {} {
  set extra [get_pblocks -quiet -filter {NAME !~ pblock_CL* && NAME !~ pblock_pr_region*}]
  if {[llength $extra]} { delete_pblocks $extra }
  set st [report_route_status -return_string]
  set e 1; set u 0
  regexp {# of nets with routing errors\.*\s*:\s*(\d+)} $st -> e
  regexp {# of unrouted nets\.*\s*:\s*(\d+)} $st -> u
  return [expr {$e == 0 && $u == 0}]
}
