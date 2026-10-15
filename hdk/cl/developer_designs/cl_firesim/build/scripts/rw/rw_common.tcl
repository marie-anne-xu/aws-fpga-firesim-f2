# RapidWright child-flow helpers (Vivado side). Source after pr_utils.tcl.
#   ::RP   nested RP cell (full path)    ::SHELL  AWS cl_bb_routed.small_shell.dcp
#   ::RWD  dir holding install_rw.sh / run_rw.sh / RwDcp.java
if {![info exists ::RP]} {
  set ::RP WRAPPER/CL/firesim_top/top/sim/target/FireSim_/chiptop0/system/sbus/coupler_from_boom_tile/prefetcher/prefetchers_0
}
# RP path inside the WRAPPER/CL cell checkpoint
set ::RPCL [string range $::RP [string length WRAPPER/CL/] end]

proc rw_timed {k script} {
  set t0 [clock milliseconds]
  set rc [catch {uplevel #0 $script} e]
  set dt [expr {([clock milliseconds] - $t0) / 1000.0}]
  puts "PR_TIME $k $dt"
  if {$rc} { puts "RWFLOW step $k FAILED: [string range $e 0 2000]" }
  return $rc
}

# Run a RapidWright subcommand (RwDcp.java) with stdout/stderr into the Vivado log.
proc rw_java {args} {
  set t0 [clock milliseconds]
  set rc [catch {exec bash $::RWD/run_rw.sh {*}$args >@ stdout 2>@ stderr} e]
  puts "PR_TIME rw_[lindex $args 0] [expr {([clock milliseconds] - $t0) / 1000.0}]"
  if {$rc} { puts "RWFLOW rapidwright [lindex $args 0] FAILED: [string range $e 0 2000]" }
  return $rc
}

proc rw_install {} {
  return [catch {exec bash $::RWD/install_rw.sh >@ stdout 2>@ stderr} e]
}

# Open a RapidWright-written DCP: via its *_load.tcl if RW wrote one (encrypted cells), else open_checkpoint.
proc rw_open {dcp} {
  set tcl [file rootname $dcp]_load.tcl
  if {[file exists $tcl]} {
    puts "RWFLOW opening $dcp via $tcl:"
    set fh [open $tcl r]; puts [read $fh]; close $fh
    source $tcl
  } else {
    open_checkpoint $dcp
  }
}

# Partition-pin node list of the RP pins: "<pin> <nodes>" per line (input for RwDcp stitch).
proc rw_dump_pplocs {file} {
  set fh [open $file w]
  set n 0
  foreach p [get_pins -of_objects [get_cells $::RP]] {
    set v [get_property -quiet HD.ASSIGNED_PPLOCS $p]
    if {$v ne ""} { puts $fh "[get_property NAME $p] $v"; incr n }
  }
  close $fh
  puts "RWFLOW pplocs: $n RP pins with HD.ASSIGNED_PPLOCS -> $file"
  return $n
}

proc rw_design_info {tag} {
  foreach p {IS_PRSHELL_DESIGN} {
    puts "RWFLOW $tag design $p=[get_property -quiet $p [current_design]]"
  }
  foreach c [get_cells -quiet -hier -filter {HD.RECONFIGURABLE == 1}] {
    puts "RWFLOW $tag RP $c container=[get_property -quiet HD.RECONFIGURABLE_CONTAINER $c]"
  }
  puts "RWFLOW $tag pblocks=[llength [get_pblocks -quiet]] [lrange [get_pblocks -quiet] 0 10]"
  set rpc [get_cells -quiet $::RP]
  if {[llength $rpc]} {
    puts "RWFLOW $tag RP ref=[get_property REF_NAME $rpc] bb=[get_property IS_BLACKBOX $rpc] pblock=[get_pblocks -quiet -of $rpc]"
    set leaf [get_cells -quiet -hier -filter "IS_PRIMITIVE && NAME =~ $::RP/*"]
    set unpl [filter -quiet $leaf {STATUS != PLACED && STATUS != FIXED && PRIMITIVE_LEVEL != INTERNAL && REF_NAME != VCC && REF_NAME != GND}]
    puts "RWFLOW $tag RP leaf cells=[llength $leaf] unplaced=[llength $unpl]"
    set np 0
    foreach p [get_pins -of $rpc] { if {[get_property -quiet HD.ASSIGNED_PPLOCS $p] ne ""} { incr np } }
    puts "RWFLOW $tag RP pins=[llength [get_pins -of $rpc]] with_ppl=$np"
  }
}

# The canonical child's gates (route/timing/HDPR DRC/DDR anchors/MIG BRAM), non-fatal: prints and counts.
proc rw_gates {tag rptdir} {
  set bad 0
  set st [report_route_status -ignore_cache -return_string]
  puts $st
  if {[catch {pr_check_routed $tag} e]} { puts "RWFLOW GATE FAIL route: $e"; incr bad }
  if {[catch {pr_check_timing_met $tag} e]} { puts "RWFLOW GATE FAIL timing: $e"; incr bad }
  if {[catch {pr_check_hdpr_drc $tag $rptdir/${tag}.hdpr_drc.rpt} e]} { puts "RWFLOW GATE FAIL hdpr: $e"; incr bad }
  if {[catch {pr_require_mig_bram $tag} e]} { puts "RWFLOW GATE FAIL mig: $e"; incr bad }
  if {[info commands chia_mark_ddr] ne ""} { chia_mark_ddr }
  set bs [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ *RXTX_BITSLICE* && NAME =~ WRAPPER/CL/SH_DDR/*}]
  set fixed 0
  foreach c $bs { if {[get_property LOC $c] ne "" && [get_property IS_LOC_FIXED $c] && [get_property IS_BEL_FIXED $c]} { incr fixed } }
  puts "RWFLOW $tag ddr anchors fixed $fixed/[llength $bs]"
  if {$fixed != 124} { puts "RWFLOW GATE FAIL ddr: $fixed"; incr bad }
  puts "RWFLOW $tag gates bad=$bad"
  return $bad
}

# main_pr_export.tcl tail on the open nested design: recombine, clear partpin props, gates, write, pr_verify.
proc rw_export {tag aws_dcp} {
  set children [get_cells -quiet -hierarchical -filter {HD.RECONFIGURABLE == 1 && NAME =~ WRAPPER/CL/*}]
  if {[rw_timed ${tag}_recombine {pr_recombine -cell WRAPPER/CL}]} { return 1 }
  set cleared 0
  foreach child $children {
    foreach p [get_pins -quiet -of_objects [get_cells $child]] {
      foreach pr {HD.PARTPIN_LOCS HD.PARTPIN_RANGE} {
        if {[get_property -quiet $pr $p] ne ""} { reset_property $pr $p; incr cleared }
      }
    }
  }
  puts "RWFLOW $tag cleared $cleared partpin props on [llength $children] former nested RP(s)"
  set bad [rw_gates ${tag}_export [file dirname $aws_dcp]]
  rw_timed ${tag}_write_export [list write_checkpoint -force $aws_dcp]
  close_design
  set rpt [file rootname $aws_dcp].pr_verify.rpt
  rw_timed ${tag}_pr_verify_shell [list pr_verify -full_check -file $rpt -initial $::SHELL -additional [list $aws_dcp]]
  set txt ""
  if {[file exists $rpt]} { set fh [open $rpt r]; set txt [read $fh]; close $fh }
  if {[regexp {are compatible} $txt] && ![regexp -nocase {not compatible|incompatible} $txt]} {
    puts "RWFLOW $tag pr_verify vs AWS shell: COMPATIBLE"
  } else {
    puts "RWFLOW $tag pr_verify vs AWS shell: NOT COMPATIBLE"
    puts [string range $txt end-3000 end]
    incr bad
  }
  return $bad
}

# ---- CL-level path: the full design's top is AWS-protected (write_edif: EDIF 20-92), so RapidWright works on
# the WRAPPER/CL cell checkpoint; the AWS export is rebuilt as AWS shell + read_checkpoint -cell WRAPPER/CL.

# write_edif -security_mode multifile writes <out>.edf/<module>/<module>.edn per protected/split module.
# Flatten for RapidWright: the top module's file -> <dir>/<name>.edf, every other .edn next to it.
proc rw_write_readable_edif {cell out_dir name} {
  file delete -force $out_dir; file mkdir $out_dir
  set raw ${out_dir}_raw.edf
  file delete -force $raw
  if {$cell eq ""} { set c {} } else { set c [list -cell $cell] }
  write_edif -force -security_mode multifile {*}$c $raw
  if {$cell eq ""} { set top [get_property TOP [current_design]] } else { set top [get_property REF_NAME [get_cells $cell]] }
  set files [split [exec find $raw -type f] "\n"]
  puts "RWFLOW edif $name: top=$top [llength $files] file(s)"
  foreach f $files {
    set fh [open $f rb]; set hdr [read $fh 12]; close $fh
    set enc [expr {[string match "XlxV*" $hdr] ? "ENCRYPTED" : "plain"}]
    puts "RWFLOW edif   [file size $f] $enc $f"
    if {[file rootname [file tail $f]] eq $top} {
      file copy -force $f $out_dir/$name.edf
    } else {
      file copy -force $f $out_dir/[file tail $f]
    }
  }
  if {![file exists $out_dir/$name.edf]} {
    if {[file isfile $raw]} { file copy -force $raw $out_dir/$name.edf } else { error "no top EDIF for $top in $raw" }
  }
  return $out_dir/$name.edf
}

# Open the AWS shell, read a routed WRAPPER/CL cell DCP into it, gates, write the AWS export, pr_verify.
proc rw_export_cl {tag cl_dcp aws_dcp} {
  rw_timed ${tag}_open_shell [list open_checkpoint $::SHELL]
  if {[rw_timed ${tag}_read_cl [list read_checkpoint -cell WRAPPER/CL $cl_dcp]]} { return 99 }
  set nested [get_cells -quiet -hierarchical -filter {HD.RECONFIGURABLE == 1 && NAME =~ WRAPPER/CL/*}]
  puts "RWFLOW $tag nested RPs after read: [llength $nested] $nested"
  set cleared 0
  foreach c [concat $nested [get_cells -quiet $::RP]] {
    foreach p [get_pins -quiet -of_objects $c] {
      foreach pr {HD.PARTPIN_LOCS HD.PARTPIN_RANGE} {
        if {[get_property -quiet $pr $p] ne ""} { reset_property $pr $p; incr cleared }
      }
    }
  }
  puts "RWFLOW $tag cleared $cleared partpin props"
  rw_design_info ${tag}_shell
  set bad [rw_gates ${tag}_export [file dirname $aws_dcp]]
  rw_timed ${tag}_write_export [list write_checkpoint -force $aws_dcp]
  close_design
  set rpt [file rootname $aws_dcp].pr_verify.rpt
  rw_timed ${tag}_pr_verify_shell [list pr_verify -full_check -file $rpt -initial $::SHELL -additional [list $aws_dcp]]
  set txt ""
  if {[file exists $rpt]} { set fh [open $rpt r]; set txt [read $fh]; close $fh }
  if {[regexp {are compatible} $txt] && ![regexp -nocase {not compatible|incompatible} $txt]} {
    puts "RWFLOW $tag pr_verify vs AWS shell: COMPATIBLE"
  } else {
    puts "RWFLOW $tag pr_verify vs AWS shell: NOT COMPATIBLE"
    puts [string range $txt end-3000 end]
    incr bad
  }
  return $bad
}
