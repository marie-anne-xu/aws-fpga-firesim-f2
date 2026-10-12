# =============================================================================
# Nested-DFX RP region selection (AWS F2). Pick the clock-region rectangle for the
# prefetcher RP from where the module actually places, instead of a fixed default.
#
# Run on a PLACED reference design that holds the RM unconstrained (e.g. the flat
# inline build of the same target config):
#
#   source pr_derive_region.tcl
#   set region [pr_derive_region $rp_path {lut 3000 ff 3000 lutram 64 bram 0 dsp 0}]
#
# Returns "CLOCKREGION_XaYb:CLOCKREGION_XcYd" and prints the ranking. Feed it to the
# base build as recipe platform_config_args.pr_region (-> FIRESIM_PR_NESTED_REGION).
#
# needs = resources of the LARGEST RM the base must host. Every candidate must:
#   - be a rectangle of clock regions in one SLR, inside pblock_CL (AWS CL area)
#   - hold no shell cell and no SH_DDR cell (same rules as pr_check_seed_region)
#   - have >= min_slices slice sites and capacity >= margin x needs
# Ranking: smallest first, then most RM cells already inside, then nearest to the
# centroid of the RM's static neighbours (low-fanout data nets only; clocks/resets
# would pull the centroid everywhere).
# =============================================================================

proc pr_cr_xy {cr} {
    if {[regexp {^X(\d+)Y(\d+)$} $cr -> x y]} { return [list $x $y] }
    return {}
}

proc pr_region_capacity {crs allowed} {
    # slices, slicem, bram36, dsp, shell/DDR occupants, sites outside pblock_CL, slrs
    set sl 0; set sm 0; set br 0; set ds 0; set bad 0; set out 0; set slrs [dict create]
    foreach cr $crs {
        set crobj [get_clock_regions -quiet $cr]
        if {$crobj eq ""} { return {} }
        foreach s [get_sites -quiet -of_objects $crobj -filter {SITE_TYPE =~ SLICE*}] {
            incr sl
            if {[get_property SITE_TYPE $s] eq "SLICEM"} { incr sm }
            if {![dict exists $allowed [get_property NAME $s]]} { incr out }
            dict set slrs [get_property NAME [get_slrs -of_objects $s]] 1
            foreach o [get_cells -quiet -of_objects $s] {
                set n [get_property NAME $o]
                if {![string match WRAPPER/CL/* $n] || [string match WRAPPER/CL/SH_DDR/* $n]} { incr bad }
            }
        }
        incr br [llength [get_sites -quiet -of_objects $crobj -filter {SITE_TYPE == RAMB36}]]
        incr ds [llength [get_sites -quiet -of_objects $crobj -filter {SITE_TYPE == DSP48E2}]]
    }
    return [list $sl $sm $br $ds $bad $out [dict size $slrs]]
}

proc pr_derive_region {rp needs {margin 3.0} {min_slices 3000} {max_crs 4}} {
    set need [dict merge {lut 0 ff 0 lutram 0 bram 0 dsp 0} $needs]
    # 1. where the RM sits now
    set rm [get_cells -quiet -hierarchical -filter "IS_PRIMITIVE && NAME =~ $rp/* && STATUS != UNPLACED"]
    if {![llength $rm]} { error "PR region: no placed primitives under $rp (need a placed reference design)" }
    set hist [dict create]
    foreach c $rm {
        set s [get_sites -quiet [get_property LOC $c]]
        if {$s eq ""} continue
        dict incr hist [get_property NAME [get_clock_regions -of_objects $s]]
    }
    set dom [lindex [lsort -stride 2 -index 1 -integer -decreasing $hist] 0]
    puts "PR region: RM [llength $rm] placed cells by clock region: $hist (dominant $dom)"
    # 2. centroid of static neighbours over low-fanout data nets
    set cx 0.0; set cy 0.0; set w 0
    foreach p [get_pins -quiet -of_objects [get_cells $rp]] {
        set n [get_nets -quiet -of_objects $p]
        if {$n eq "" || [get_property TYPE $n] ne "SIGNAL" || [get_property FLAT_PIN_COUNT $n] > 64} continue
        foreach c [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects $n] -filter "IS_PRIMITIVE && NAME !~ $rp/*"] {
            set s [get_sites -quiet [get_property LOC $c]]
            if {$s eq ""} continue
            set xy [pr_cr_xy [get_property NAME [get_clock_regions -of_objects $s]]]
            if {![llength $xy]} continue
            set cx [expr {$cx + [lindex $xy 0]}]; set cy [expr {$cy + [lindex $xy 1]}]; incr w
        }
    }
    if {$w} { set cx [expr {$cx / $w}]; set cy [expr {$cy / $w}] } else { lassign [pr_cr_xy $dom] cx cy }
    puts "PR region: static-neighbour centroid (clock-region grid) X=[format %.2f $cx] Y=[format %.2f $cy] from $w endpoints"
    # 3. candidate rectangles containing the dominant clock region
    set allowed [dict create]
    foreach s [get_sites -of_objects [get_pblocks pblock_CL]] { dict set allowed [get_property NAME $s] 1 }
    lassign [pr_cr_xy $dom] dx dy
    set best {}
    foreach wdt {1 2 3 4} {
        foreach hgt {1 2 3 4} {
            if {$wdt * $hgt > $max_crs} continue
            for {set x0 [expr {$dx - $wdt + 1}]} {$x0 <= $dx} {incr x0} {
                for {set y0 [expr {$dy - $hgt + 1}]} {$y0 <= $dy} {incr y0} {
                    if {$x0 < 0 || $y0 < 0} continue
                    set x1 [expr {$x0 + $wdt - 1}]; set y1 [expr {$y0 + $hgt - 1}]
                    set crs {}
                    for {set x $x0} {$x <= $x1} {incr x} { for {set y $y0} {$y <= $y1} {incr y} { lappend crs X${x}Y${y} } }
                    set cap [pr_region_capacity $crs $allowed]
                    if {![llength $cap]} continue
                    lassign $cap sl sm br ds bad out nslr
                    set why {}
                    if {$nslr != 1} { lappend why "spans $nslr SLRs" }
                    if {$out} { lappend why "$out sites outside pblock_CL" }
                    if {$bad} { lappend why "$bad shell/DDR cells" }
                    if {$sl < $min_slices} { lappend why "$sl < $min_slices slices" }
                    if {$sl * 8 < $margin * [dict get $need lut]} { lappend why "LUT capacity" }
                    if {$sl * 16 < $margin * [dict get $need ff]} { lappend why "FF capacity" }
                    if {$sm * 8 < $margin * [dict get $need lutram]} { lappend why "LUTRAM capacity" }
                    if {$br < $margin * [dict get $need bram]} { lappend why "BRAM capacity" }
                    if {$ds < $margin * [dict get $need dsp]} { lappend why "DSP capacity" }
                    set inside 0
                    foreach cr $crs { if {[dict exists $hist $cr]} { incr inside [dict get $hist $cr] } }
                    set dist [expr {abs(($x0 + $x1) / 2.0 - $cx) + abs(($y0 + $y1) / 2.0 - $cy)}]
                    set region CLOCKREGION_X${x0}Y${y0}:CLOCKREGION_X${x1}Y${y1}
                    puts [format "PR region: candidate %-40s crs=%d slices=%d slicem=%d bram=%d dsp=%d rm_inside=%d dist=%.2f %s" \
                          $region [llength $crs] $sl $sm $br $ds $inside $dist [expr {[llength $why] ? "REJECT: [join $why {, }]" : "ok"}]]
                    if {![llength $why]} { lappend best [list [llength $crs] [expr {-$inside}] $dist $region] }
                }
            }
        }
    }
    if {![llength $best]} { error "PR region: no legal candidate around $dom (raise max_crs or check needs)" }
    # rank: fewest clock regions, then most RM cells already inside, then nearest the neighbour centroid
    set best_sorted [lsort -command {apply {{a b} {
        foreach i {0 1} { if {[lindex $a $i] != [lindex $b $i]} { return [expr {[lindex $a $i] < [lindex $b $i] ? -1 : 1}] } }
        return [expr {[lindex $a 2] < [lindex $b 2] ? -1 : ([lindex $a 2] > [lindex $b 2])}] }}} $best]
    set pick [lindex $best_sorted 0 3]
    puts "PR_REGION $pick"
    return $pick
}
