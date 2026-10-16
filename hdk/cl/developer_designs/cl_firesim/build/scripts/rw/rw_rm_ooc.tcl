# Out-of-context implementation of an RM against a nested base's RP context.
#   rw_write_ooc_context <xdc_out> <ctx_out>  (base open): pblock, clock period + HD.CLK_SRC, per-port PPLOC tile
#   rw_impl_rm_ooc <rm_synth_dcp> <xdc> <ctx> <out_dcp> <edf_dir>: HD.PARTITION OOC place+route inside the RP pblock
proc rw_write_ooc_context {xdc ctx {budget 0.4}} {
  set rpc [get_cells $::RP]
  set pb [get_pblocks -of $rpc]
  set ranges [get_property GRID_RANGES $pb]
  set ck [get_pins $::RP/clock]
  set clk [lindex [get_clocks -of_objects $ck] 0]
  set per [get_property PERIOD $clk]
  set drv [get_cells -of_objects [get_pins -leaf -of_objects [get_nets -of $ck] -filter {DIRECTION == OUT}]]
  set src [get_property LOC $drv]
  puts "RWFLOW ctx pblock=$pb ranges=$ranges clock=$clk period=$per driver=$drv ($src)"
  set fh [open $xdc w]
  puts $fh "create_clock -name rmclk -period $per \[get_ports clock\]"
  puts $fh "set_property HD.CLK_SRC $src \[get_ports clock\]"
  puts $fh "create_pblock pblock_rm"
  puts $fh "resize_pblock pblock_rm -add {$ranges}"
  puts $fh "add_cells_to_pblock pblock_rm -top"
  # DRC HDOOC-2: an HD.RECONFIGURABLE OOC top pblock needs CONTAIN_ROUTING and EXCLUDE_PLACEMENT
  puts $fh "set_property CONTAIN_ROUTING true \[get_pblocks pblock_rm\]"
  puts $fh "set_property EXCLUDE_PLACEMENT true \[get_pblocks pblock_rm\]"
  set d [expr {$per * $budget}]
  puts $fh "set_input_delay -clock rmclk $d \[get_ports -filter {DIRECTION == IN && NAME != clock}\]"
  puts $fh "set_output_delay -clock rmclk $d \[get_ports -filter {DIRECTION == OUT}\]"
  close $fh
  set ch [open $ctx w]
  set n 0
  foreach p [get_pins -of $rpc] {
    set v [get_property -quiet HD.ASSIGNED_PPLOCS $p]
    if {$v eq ""} continue
    puts $ch "[get_property REF_PIN_NAME $p] [lindex $v 0]"; incr n
  }
  close $ch
  puts "RWFLOW ctx: $n ports with PPLOC -> $ctx; xdc -> $xdc"
}

proc rw_impl_rm_ooc {rm xdc ctx out edf_dir {do_route 1}} {
  rw_timed ooc_open [list open_checkpoint $rm]
  # The in-context RP is HD.RECONFIGURABLE; read_checkpoint -cell refuses an HD.PARTITION OOC module (Project 1-1036).
  if {[catch {set_property HD.RECONFIGURABLE 1 [current_design]} e]} {
    puts "RWFLOW ooc HD.RECONFIGURABLE on top failed ($e); using HD.PARTITION"
    set_property HD.PARTITION 1 [current_design]
  }
  puts "RWFLOW ooc top HD.RECONFIGURABLE=[get_property -quiet HD.RECONFIGURABLE [current_design]] HD.PARTITION=[get_property -quiet HD.PARTITION [current_design]]"
  # OOC-only: clock, HD.CLK_SRC, pblock and I/O budgets must not travel into the base (in-context RP has its own).
  read_xdc -mode out_of_context $xdc
  # partition pins: try the exact base PPLOC node, fall back to its INT tile
  set node_ok 0; set tile_ok 0; set fail 0; set unused 0
  set fh [open $ctx r]
  foreach line [split [read $fh] "\n"] {
    if {[llength $line] < 2} continue
    lassign $line port node
    set node [string trim $node "{}"]
    set p [get_ports -quiet $port]
    if {![llength $p]} { incr fail; puts "RWFLOW ooc no port $port"; continue }
    if {![llength [get_nets -quiet -of_objects $p]]} { incr unused; continue }
    if {![catch {set_property HD.PARTPIN_LOCS $node $p}] && [get_property HD.PARTPIN_LOCS $p] eq $node} { incr node_ok; continue }
    set tile [lindex [split $node /] 0]
    if {[catch {set_property HD.PARTPIN_LOCS $tile $p} e]} { incr fail; puts "RWFLOW ooc ppl $port $tile: $e" } else { incr tile_ok }
  }
  close $fh
  puts "RWFLOW ooc partpin locs: node=$node_ok tile=$tile_ok unused_port=$unused fail=$fail"
  set steps {ooc_opt opt_design ooc_place place_design ooc_phys phys_opt_design}
  # do_route 0: placement only; the in-context route_design then routes the RM against the real static
  # (an OOC-routed RM collided with static routing crossing the RP region: 116 conflicts, rw_c_viv4).
  if {$do_route} { lappend steps ooc_route route_design }
  foreach {k cmd} $steps {
    if {[rw_timed $k $cmd]} { error "RWFLOW OOC $k failed" }
  }
  puts [report_route_status -return_string]
  report_timing_summary -max_paths 5 -file [file rootname $out].timing.rpt
  puts [report_timing -max_paths 3 -return_string]
  puts "RWFLOW ooc timing WNS=[get_property SLACK [get_timing_paths -setup]] WHS=[get_property SLACK [get_timing_paths -hold]]"
  set np 0
  foreach p [get_ports] { set v [get_property -quiet HD.ASSIGNED_PPLOCS $p]; if {$v ne ""} { incr np; if {$np <= 5} { puts "RWFLOW ooc assigned $p $v" } } }
  puts "RWFLOW ooc ports with assigned PPLOCS: $np"
  set same 0; set diff 0
  set fh [open $ctx r]
  foreach line [split [read $fh] "\n"] {
    if {[llength $line] < 2} continue
    lassign $line port node
    set a [lindex [get_property -quiet HD.ASSIGNED_PPLOCS [get_ports -quiet $port]] 0]
    if {$a eq [string trim $node "{}"]} { incr same } else { incr diff; if {$diff <= 10} { puts "RWFLOW ooc ppl mismatch $port base=$node ooc=$a" } }
  }
  close $fh
  puts "RWFLOW ooc PPLOC vs base: same=$same differ=$diff"
  rw_timed ooc_write [list write_checkpoint -force $out]
  if {$edf_dir ne ""} { rw_timed ooc_edif [list rw_write_readable_edif "" $edf_dir [file rootname [file tail $out]]] }
}
