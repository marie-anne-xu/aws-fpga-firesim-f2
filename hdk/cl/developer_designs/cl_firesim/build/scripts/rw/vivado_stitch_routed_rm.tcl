# Vivado-only control for B: open base, black-box RP, lock static routing, read a PLACED+ROUTED RM cell DCP
# into the RP (keeps its placement/routing), route only what is left (boundary), gates, AWS export + pr_verify.
# Expects rw_trial.tcl/rw_common.tcl sourced and: ::BASE ::RMDCP ::OUT (nested out dcp) ::TAG
# Targeted repair of an imported OOC-routed RM. Only nets the import left in CONFLICTS/PARTIAL/UNROUTED
# state are touched: RM-internal ones are unrouted whole; boundary (static, locked) ones lose only the
# branches to their RM pins, so the static side (ending at the base PPLOC / static clock tree) stays.
# (rw_c_viv3: unrouting all 10658 RM-side boundary pins incl. clock/reset ran single-threaded >10 min.)
proc rw_unroute_rm_side {} {
  set badn [get_nets -quiet -hierarchical -top_net_of_hierarchical_group \
              -filter {ROUTE_STATUS == CONFLICTS || ROUTE_STATUS == PARTIAL || ROUTE_STATUS == UNROUTED}]
  set rmint {}; set bnd {}
  foreach n $badn {
    set lp [get_pins -quiet -leaf -of_objects $n]
    set out [filter -quiet $lp "NAME !~ $::RP/*"]
    if {[llength $out]} { lappend bnd $n } else { lappend rmint $n }
  }
  puts "RWFLOW repair: nets not ROUTED=[llength $badn] RM-internal=[llength $rmint] boundary/static=[llength $bnd]"
  foreach n [lrange $bnd 0 20] { puts "RWFLOW repair boundary/static net: $n [get_property ROUTE_STATUS $n] fixed=[get_property IS_ROUTE_FIXED $n]" }
  if {[llength $rmint]} {
    set f [filter -quiet [get_nets $rmint] {IS_ROUTE_FIXED}]
    if {[llength $f]} { set_property IS_ROUTE_FIXED 0 $f }
    rw_timed unroute_rm_internal [list route_design -unroute -nets [get_nets $rmint]]
  }
  if {[llength $bnd]} {
    set bn [get_nets $bnd]
    set pins [get_pins -quiet -leaf -of_objects $bn -filter "NAME =~ $::RP/*"]
    set f [filter -quiet $bn {IS_ROUTE_FIXED}]
    if {[llength $f]} { set_property IS_ROUTE_FIXED 0 $f }
    puts "RWFLOW repair: unrouting [llength $pins] RM-side pins of [llength $bn] boundary nets"
    if {[llength $pins]} { rw_timed unroute_rm_pins [list route_design -unroute -pins $pins] }
  }
  return 0
}

proc rw_vivado_stitch {} {
  set t0 [clock seconds]
  rw_timed open_base [list open_checkpoint $::BASE]
  pr_require_mig_bram "child base" 0
  rw_timed black_box [list update_design -cell $::RP -black_box]
  rw_timed lock [list lock_design -level routing]
  if {[rw_timed read_rm [list read_checkpoint -cell $::RP $::RMDCP]]} { error "read_checkpoint -cell failed" }
  # pblocks carried in by the RM checkpoint (OOC pblock) would nest under the RP pblock (HDPR-19)
  set extra [get_pblocks -quiet -filter {NAME !~ pblock_CL* && NAME !~ pblock_pr_region*}]
  if {[llength $extra]} { puts "RWFLOW deleting RM-carried pblocks: $extra"; delete_pblocks $extra }
  rw_design_info after_read
  puts [report_route_status -return_string]
  set leaf [get_cells -quiet -hier -filter "IS_PRIMITIVE && NAME =~ $::RP/*"]
  set unpl [filter -quiet $leaf {STATUS != PLACED && STATUS != FIXED && PRIMITIVE_LEVEL != INTERNAL && REF_NAME != VCC && REF_NAME != GND}]
  if {[llength $unpl]} {
    puts "RWFLOW [llength $unpl] RM cells unplaced after read; running place_design -directive Quick"
    rw_timed place [list place_design -directive Quick]
  }
  # If the imported RM already connects to every partition pin (route status clean), the full-design router
  # (7.6 min of mostly init in rw_b0) has nothing to do; skip it when ::SKIP_ROUTE_IF_ROUTED is set.
  set st [report_route_status -return_string]
  set e 1; set u 1
  regexp {# of nets with routing errors\.*\s*:\s*(\d+)} $st -> e
  regexp {# of unrouted nets\.*\s*:\s*(\d+)} $st -> u
  if {![regexp {# of unrouted nets} $st]} { set u 0 }
  puts "RWFLOW after read: routing errors=$e unrouted=$u"
  if {[info exists ::SKIP_ROUTE_IF_ROUTED] && $::SKIP_ROUTE_IF_ROUTED && $e == 0 && $u == 0} {
    puts "RWFLOW skipping route_design (imported RM fully routed)"
  } else {
    if {$e > 0} { rw_unroute_rm_side }
    rw_timed route [list route_design -directive Default]
  }
  set bad [rw_gates $::TAG [file dirname $::OUT]]
  if {$bad && (![info exists ::REPAIR_ROUTE] || $::REPAIR_ROUTE)} {
    # Repair: drop the RM side of every boundary net (signal + clock) and route again; static stays locked.
    rw_unroute_rm_side
    rw_timed repair_route [list route_design -directive Default]
    set bad [rw_gates ${::TAG}_repair [file dirname $::OUT]]
  }
  rw_timed write [list write_checkpoint -force $::OUT]
  incr bad [rw_export $::TAG [file rootname $::OUT]_aws.dcp]
  puts "RWFLOW $::TAG total [expr {[clock seconds] - $t0}] s bad=$bad"
  return $bad
}
