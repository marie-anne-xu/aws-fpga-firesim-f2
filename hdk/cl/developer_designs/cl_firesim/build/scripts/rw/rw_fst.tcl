# firesim_top-level RapidWright child flow, Vivado side (rwf_* trials, 2026-10-19).
# WRAPPER/CL/firesim_top (F1Shim) is write_edif-clean and contains the nested RP and its static neighbours;
# only AWS sh_ddr helpers under WRAPPER/CL/SH_DDR are IEEE-1735 protected (rwp_protected_cells).
# Source after rw_common.tcl.
set ::FST WRAPPER/CL/firesim_top
set ::RPFST [string range $::RP [string length $::FST/] end]

# Clock regions of the RP pblock (GRID_RANGES CLOCKREGION_X1Y0:CLOCKREGION_X2Y0 -> X1Y0 X2Y0).
proc rw_rp_clock_regions {} {
  set pb [get_pblocks -of [get_cells $::RP]]
  set out {}
  foreach r [get_property GRID_RANGES $pb] {
    if {![regexp {CLOCKREGION_X(\d+)Y(\d+):CLOCKREGION_X(\d+)Y(\d+)} $r -> x0 y0 x1 y1]} {
      if {[regexp {CLOCKREGION_(X\d+Y\d+)} $r -> c]} { lappend out $c }
      continue
    }
    for {set x $x0} {$x <= $x1} {incr x} { for {set y $y0} {$y <= $y1} {incr y} { lappend out X${x}Y${y} } }
  }
  return [lsort -unique $out]
}

# P: nets that use routing in the RP clock regions but have no leaf pin inside firesim_top (invisible to a
# firesim_top-level RapidWright) or pins on both sides (crossing). Writes "<net> <pip> ..." per outside/crossing
# net to $blk (all PIPs of signal nets; region-tile PIPs only for GND/VCC).
proc rw_fst_probe {blk} {
  set crs [rw_rp_clock_regions]
  puts "RWFLOW P RP clock regions: $crs"
  set tiles [get_tiles -of_objects [get_clock_regions $crs]]
  set rt [filter $tiles {TYPE =~ INT* || TYPE =~ RCLK*}]
  puts "RWFLOW P region tiles=[llength $tiles] INT/RCLK=[llength $rt]"
  set t0 [clock milliseconds]
  set nets [get_nets -quiet -of_objects $rt]
  puts "RWFLOW P nets using INT/RCLK tiles of the RP region: [llength $nets] ([expr {([clock milliseconds]-$t0)/1000.0}] s)"
  set inN 0; set outN {}; set crossN {}; set stat {}
  set fstp "$::FST/*"
  foreach n $nets {
    if {[string match $fstp $n]} { incr inN; continue }
    set ty [get_property TYPE $n]
    if {$ty eq "GROUND" || $ty eq "POWER"} { lappend stat $n; continue }
    set lp [get_pins -quiet -leaf -of_objects $n]
    set nin [llength [filter -quiet $lp "NAME =~ $fstp"]]
    if {$nin == 0} { lappend outN $n } else { lappend crossN $n }
  }
  puts "RWFLOW P nets: named-inside-firesim_top=$inN outside=[llength $outN] crossing=[llength $crossN] static=[llength $stat]"
  # hierarchy histogram (first 4 levels) of outside + crossing
  foreach {tag lst} [list outside $outN crossing $crossN] {
    set h [dict create]
    foreach n $lst { dict incr h [join [lrange [split $n /] 0 3] /] }
    set rows {}
    dict for {k v} $h { lappend rows [list $v $k] }
    foreach r [lrange [lsort -integer -decreasing -index 0 $rows] 0 14] { puts "RWFLOW P $tag hier [lindex $r 0] [lindex $r 1]" }
  }
  set rtset [dict create]
  foreach t $rt { dict set rtset $t 1 }
  set fh [open $blk w]
  set np 0; set nreg 0
  foreach n [concat $outN $crossN] {
    set ps [get_pips -quiet -of_objects $n]
    set k 0
    foreach p $ps { if {[dict exists $rtset [lindex [split $p /] 0]]} { incr k } }
    incr nreg $k
    if {$k > 0} { puts "RWFLOW P net pips_in_region=$k total=[llength $ps] fixed=[get_property IS_ROUTE_FIXED $n] [get_property TYPE $n] $n" }
    puts $fh "$n [join $ps { }]"
    incr np [llength $ps]
  }
  set ns 0
  foreach n $stat {
    set ps {}
    foreach p [get_pips -quiet -of_objects $n] { if {[dict exists $rtset [lindex [split $p /] 0]]} { lappend ps $p } }
    puts "RWFLOW P static net $n pips_in_region=[llength $ps]"
    if {[llength $ps]} { puts $fh "$n [join $ps { }]"; incr ns [llength $ps] }
  }
  close $fh
  puts "RWFLOW P RESULT outside=[llength $outN] crossing=[llength $crossN] (their pips in region INT/RCLK tiles=$nreg, all pips dumped=$np) static_region_pips=$ns -> $blk"
  return [list [llength $outN] [llength $crossN]]
}

# Once per base: black-box the RP, lock static routing, write the firesim_top cell DCP + readable EDIF.
proc rw_fst_export {dcp edf_dir} {
  rw_timed fst_black_box [list update_design -cell $::RP -black_box]
  rw_timed fst_lock [list lock_design -level routing]
  rw_timed fst_write_cell_dcp [list write_checkpoint -force -cell $::FST $dcp]
  puts "RWFLOW fst dcp size [file size $dcp]"
  rw_timed fst_write_edif [list rw_write_readable_edif $::FST $edf_dir fst]
}

# Vivado's write_checkpoint -cell drops nearly all routing of a big hierarchical cell (rwf_1: fst rdb 161 KB,
# RapidWright sees 0 PIPs; rw_a2: same for WRAPPER/CL, 629563 nets unrouted). Dump the routing RapidWright needs
# instead (after black_box + lock): every net using an INT/RCLK tile of the RP clock regions (full PIP list) and
# the GND/VCC PIPs in those tiles. "<net> <pip> ..." per line; GND/VCC as __GND__/__VCC__.
proc rw_fst_dump_routes {file} {
  set crs [rw_rp_clock_regions]
  set rt [filter [get_tiles -of_objects [get_clock_regions $crs]] {TYPE =~ INT* || TYPE =~ RCLK*}]
  set rtset [dict create]
  foreach t $rt { dict set rtset $t 1 }
  set nets [get_nets -quiet -of_objects $rt]
  set fh [open $file w]
  set np 0; set nn 0
  foreach n $nets {
    set ps [get_pips -quiet -of_objects $n]
    if {![llength $ps]} continue
    puts $fh "$n [join $ps { }]"
    incr np [llength $ps]; incr nn
  }
  puts "RWFLOW dump: $nn nets in region, $np pips"
  foreach {tag ty} {__GND__ GROUND __VCC__ POWER} {
    # one segment only: get_pips of all ~thousands of hierarchical const segments at once ran the host out of
    # memory (rwf_2 s0, exit 137); the PIPs belong to the flat net, so any segment returns them all.
    set g [lindex [get_nets -quiet -hier -filter "TYPE == $ty"] 0]
    set ps {}
    set all 0
    if {$g ne ""} {
      set t0 [clock milliseconds]
      set allp [get_pips -quiet -of_objects [get_nets $g]]
      set all [llength $allp]
      foreach p $allp {
        if {[dict exists $rtset [lindex [split $p /] 0]]} { lappend ps $p }
      }
      unset allp
      puts "RWFLOW dump: $tag via $g: [expr {([clock milliseconds]-$t0)/1000.0}] s"
    }
    puts "RWFLOW dump: $tag net pips=$all region pips=[llength $ps]"
    if {[llength $ps]} { puts $fh "$tag [join $ps { }]" }
  }
  close $fh
  puts "RWFLOW dump -> $file [file size $file] B"
}
