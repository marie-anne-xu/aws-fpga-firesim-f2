# =============================================================================
# Nested-DFX pass-2 implementation helpers (AWS F2), used by main_pr_subdivide.tcl.
#
# Ported from trial g9_cell_const_unroute (placed + routed, WNS +0.060 ns,
# WHS +0.010 ns, 124/124 DDR bitslices fixed, DFX DRC 0 errors, no ERROR lines):
#   1. Export the placed+routed WRAPPER/CL of the pass-1 parent as a cell
#      checkpoint, strip its pblocks, and unroute its GND/VCC nets
#      (pr_write_clean_cl_cell). Static constants routed through the future
#      RP region otherwise cause HPR routing violations (Constraints 18-5228).
#   2. Open the AWS shell, lock_design -level routing, then pr_subdivide from
#      that placed cell. SH_DDR arrives placed and generated (no MIG regen).
#   3. Freeze all static logic (LUT pin maps, placement, routes) and place and
#      route only the RP plus its boundary nets (pr_route_rp). Rerouting
#      static nets produced DFX route DRC 18-1000 in earlier trials.
# Procs take the RP path explicitly. RP paths must not contain glob characters.
# =============================================================================

# ---- step 1: clean CL cell checkpoint ---------------------------------------
# Call with the routed pass-1 parent open. Closes it and leaves no design open.
proc pr_write_clean_cl_cell {cell_dcp clean_dcp} {
    write_checkpoint -force -cell WRAPPER/CL $cell_dcp
    close_design
    open_checkpoint $cell_dcp
    # The CL XDCs re-create the floorplan after subdivision.
    if {[llength [get_pblocks -quiet]]} { delete_pblocks [get_pblocks] }
    set rxtx [get_cells -quiet -hierarchical -filter {REF_NAME == RXTX_BITSLICE}]
    puts "PR: CL cell RXTX bitslices=[llength $rxtx] placed=[llength [filter -quiet $rxtx {STATUS != UNPLACED}]]"
    set pg [get_nets -quiet -hierarchical -filter {TYPE == POWER || TYPE == GROUND}]
    set fixed [filter -quiet $pg {IS_ROUTE_FIXED}]
    if {[llength $fixed]} { set_property IS_ROUTE_FIXED 0 $fixed }
    if {[llength $pg]} { route_design -unroute -nets $pg }
    set left [get_nets -quiet -hierarchical -filter {(TYPE == POWER || TYPE == GROUND) && ROUTE_STATUS != UNROUTED}]
    puts "PR: CL cell constant nets=[llength $pg] unrouted; still routed=[llength $left]"
    if {[llength $left]} { error "PR: [llength $left] constant nets remain routed in the CL cell checkpoint" }
    write_checkpoint -force $clean_dcp
    close_design
}

# ---- step 3 helpers: floorplan and static locks -----------------------------
proc pr_make_rp_pblock {rp region} {
    foreach rng $region {
        foreach grp {pblock_CL_SLR0 pblock_CL_SLR1 pblock_CL_SLR2} {
            if {[llength [get_pblocks -quiet $grp]]} { resize_pblock $grp -remove $rng }
        }
    }
    foreach old {pblock_prefetcher_seed pblock_pr_region_0} {
        if {[llength [get_pblocks -quiet $old]]} { delete_pblocks [get_pblocks $old] }
    }
    # Parent is ROOT (HDPR-2). EXCLUDE_PLACEMENT and CONTAIN_ROUTING are required.
    # RESET_AFTER_RECONFIG is not supported on this device (HDPR-32).
    set pb [create_pblock pblock_pr_region_0]
    foreach rng $region { resize_pblock $pb -add $rng }
    set_property SNAPPING_MODE ON       $pb
    set_property EXCLUDE_PLACEMENT true $pb
    set_property CONTAIN_ROUTING true   $pb
    add_cells_to_pblock $pb [get_cells $rp] -clear_locs
    puts "PR: pblock_pr_region_0 = $region"
    return $pb
}

# Current LUT input-pin -> BEL-pin map as a LOCK_PINS value, or "" if ambiguous.
proc pr_lut_lock_str {c} {
    set m {}
    foreach p [get_pins -quiet -of_objects $c -filter {DIRECTION == IN}] {
        set bp [get_bel_pins -quiet -of_objects $p]
        if {[llength $bp] != 1} { return "" }
        lappend m "[get_property REF_PIN_NAME $p]:[lindex [split [get_property NAME $bp] /] end]"
    }
    return [join $m " "]
}

# Lock the pin mapping of placed LUTs not locked yet. Without this the router
# swaps LUT pins on static boundary loads whose other inputs have fixed routes,
# which fails DFX route DRC (Constraints 18-1000).
proc pr_lock_lut_pins {cells label} {
    set t0 [clock seconds]
    set n 0; set pre 0; set skip 0; set fail 0; set i 0
    foreach c $cells {
        if {[incr i] % 50000 == 0} { puts "PR: $label LOCK_PINS $i/[llength $cells] ([expr {[clock seconds]-$t0}]s)"; flush stdout }
        if {[get_property LOCK_PINS $c] ne ""} { incr pre; continue }
        set ls [pr_lut_lock_str $c]
        if {$ls eq ""} { incr skip; continue }
        # Tolerated as in the validated trial: the router then keeps this LUT's
        # inputs on whatever pins its fixed static routes already use.
        if {[catch {set_property LOCK_PINS $ls $c}]} { incr fail; continue }
        incr n
    }
    puts "PR: $label LOCK_PINS luts=[llength $cells] locked=$n already=$pre ambiguous=$skip failed=$fail ([expr {[clock seconds]-$t0}]s)"
}

proc pr_lock_static_lut_pins {rp} {
    set cells [get_cells -quiet -hierarchical -filter "IS_PRIMITIVE && REF_NAME =~ LUT* && STATUS != UNPLACED && NAME =~ WRAPPER/CL/* && NAME !~ $rp/*"]
    pr_lock_lut_pins $cells static
}

# Unplace whole macros that came in partially placed (leaf LOC lost on import).
proc pr_unplace_partial_macros {rp} {
    set unpl [get_cells -quiet -hierarchical -filter "IS_PRIMITIVE && NAME =~ WRAPPER/CL/* && NAME !~ $rp/* && STATUS == UNPLACED"]
    set parents [dict create]
    foreach c $unpl {
        set pc [get_cells -quiet [get_property PARENT $c]]
        if {[llength $pc] && [get_property -quiet PRIMITIVE_LEVEL $pc] eq "MACRO"} { dict set parents [get_property NAME $pc] $pc }
    }
    set n 0
    dict for {name pc} $parents {
        set kids [get_cells -quiet -filter {STATUS != UNPLACED} "$name/*"]
        if {[llength $kids]} {
            set_property IS_BEL_FIXED 0 $kids
            set_property IS_LOC_FIXED 0 $kids
            unplace_cell $pc
            incr n
        }
    }
    puts "PR: unplaced static primitives=[llength $unpl], partially placed macros reset=$n"
}

# Lock placement of every static sibling along the RP's ancestor chain (this
# covers all of WRAPPER/CL except the RP).
proc pr_lock_static_except_rp {rp} {
    set chain {}
    set p $rp
    while {$p ne "WRAPPER/CL"} { set p [file dirname $p]; lappend chain $p }
    set skip [dict create $rp 1]
    foreach a $chain { dict set skip $a 1 }
    set nh 0; set nl 0
    foreach a $chain {
        foreach c [get_cells -quiet "$a/*"] {
            if {[dict exists $skip [get_property NAME $c]]} { continue }
            if {[get_property IS_PRIMITIVE $c]} {
                if {[get_property STATUS $c] ne "UNPLACED"} {
                    set_property IS_BEL_FIXED 1 $c
                    set_property IS_LOC_FIXED 1 $c
                    incr nl
                }
            } else {
                lock_design -level placement $c
                incr nh
            }
        }
    }
    puts "PR: static placement locked: hierarchies=$nh leaves=$nl"
}

# ---- partition-pin ranges ---------------------------------------------------
proc pr_tile_xy {cell} {
    set loc [get_property -quiet LOC $cell]
    if {$loc eq ""} { return "" }
    set t [get_tiles -quiet -of_objects [get_sites -quiet $loc]]
    if {[regexp {_X(\d+)Y(\d+)$} [get_property -quiet NAME $t] -> x y]} { return [list $x $y] }
    return ""
}
# Static-side leaf cells driven through RP boundary pin $p.
proc pr_static_ends {rp p} {
    set st {}
    foreach lp [get_pins -quiet -leaf -of_objects [get_nets -quiet -segments -of_objects $p]] {
        set c [get_cells -quiet -of_objects $lp]
        if {[llength $c] && ![string match "$rp/*" [get_property NAME $c]]} { lappend st $c }
    }
    return $st
}
# For every io_request_bits_address output with static loads outside the RP rows,
# constrain its PartPin to the band of RP slice rows nearest those loads (rows
# 1..6 inside the edge, X within +/-6 INT columns). Without it the router could
# not assign PartPins for address bits whose loads sit far above the region.
proc pr_set_partpin_ranges {rp pblock} {
    set recs {}
    set ymin 1e9; set ymax -1
    foreach s [get_sites -quiet -of_objects [get_pblocks $pblock] -filter {SITE_TYPE =~ SLICE*}] {
        if {![regexp {_X(\d+)Y(\d+)$} [get_property NAME [get_tiles -quiet -of_objects $s]] -> tx ty]} { continue }
        if {![regexp {SLICE_X(\d+)Y(\d+)} [get_property NAME $s] -> sx sy]} { continue }
        lappend recs [list $tx $ty $sx $sy]
        if {$ty < $ymin} { set ymin $ty }
        if {$ty > $ymax} { set ymax $ty }
    }
    set n 0
    foreach p [get_pins -quiet -of_objects [get_cells $rp]] {
        if {![regexp {io_request_bits_address\[\d+\]$} [get_property NAME $p]]} { continue }
        set xs {}; set ys {}
        foreach c [pr_static_ends $rp $p] {
            set xy [pr_tile_xy $c]
            if {$xy ne ""} { lappend xs [lindex $xy 0]; lappend ys [lindex $xy 1] }
        }
        if {![llength $xs]} { continue }
        set lx [expr {int(([tcl::mathfunc::min {*}$xs] + [tcl::mathfunc::max {*}$xs]) / 2)}]
        if {[tcl::mathfunc::min {*}$ys] > $ymax} {
            set y0 [expr {$ymax-6}]; set y1 [expr {$ymax-1}]
        } elseif {[tcl::mathfunc::max {*}$ys] < $ymin} {
            set y0 [expr {$ymin+1}]; set y1 [expr {$ymin+6}]
        } else { continue }
        set sxs {}; set sys {}
        foreach r $recs {
            lassign $r tx ty sx sy
            if {$tx >= $lx-6 && $tx <= $lx+6 && $ty >= $y0 && $ty <= $y1} { lappend sxs $sx; lappend sys $sy }
        }
        if {![llength $sxs]} { continue }
        set rng "SLICE_X[tcl::mathfunc::min {*}$sxs]Y[tcl::mathfunc::min {*}$sys]:SLICE_X[tcl::mathfunc::max {*}$sxs]Y[tcl::mathfunc::max {*}$sys]"
        set_property HD.PARTPIN_RANGE $rng $p
        incr n
    }
    puts "PR: HD.PARTPIN_RANGE set on $n RP address pins (pblock INT rows $ymin..$ymax)"
}

# ---- static constants inside the RP region ----------------------------------
# Static GND/VCC routes must not cross the RP region (18-5228). The clean CL
# cell import already guarantees this; scan anyway, and unroute any offender
# so the router re-routes it outside the region.
proc pr_const_nets_in_rp {pblock} {
    set xs {}; set ys {}
    foreach t [get_tiles -quiet -of_objects [get_sites -quiet -of_objects [get_pblocks $pblock]]] {
        if {[regexp {_X(\d+)Y(\d+)$} [get_property NAME $t] -> x y]} { lappend xs $x; lappend ys $y }
    }
    set xs [lsort -integer -unique $xs]; set ys [lsort -integer -unique $ys]
    set names {}
    for {set x [lindex $xs 0]} {$x <= [lindex $xs end]} {incr x} {
        for {set y [lindex $ys 0]} {$y <= [lindex $ys end]} {incr y} { lappend names INT_X${x}Y${y} }
    }
    set nodes [get_nodes -quiet -of_objects [get_tiles -quiet $names]]
    return [filter -quiet [get_nets -quiet -of_objects $nodes] {TYPE == POWER || TYPE == GROUND}]
}
proc pr_const_rp_repair {rp pblock label} {
    set bad [filter -quiet [pr_const_nets_in_rp $pblock] "NAME !~ $rp/*"]
    puts "PR: $label static constant nets using RP-region INT tiles: [llength $bad]"
    if {![llength $bad]} { return }
    set fixed [filter -quiet $bad {IS_ROUTE_FIXED}]
    if {[llength $fixed]} { set_property IS_ROUTE_FIXED 0 $fixed }
    route_design -unroute -nets $bad
    puts "PR: $label unrouted [llength $bad] static constant nets for re-route outside the RP"
}

# ---- step 3: route the RP and its boundary only -----------------------------
# Call after place_design. No phys_opt_design: it restructures static cells.
proc pr_route_rp {rp pblock} {
    set bnets [get_nets -quiet -of_objects [get_pins -quiet $rp/*]]
    set bsig [filter -quiet $bnets {TYPE != GLOBAL_CLOCK}]
    set bclk [filter -quiet $bnets {TYPE == GLOBAL_CLOCK}]
    puts "PR: boundary nets=[llength $bnets] signal=[llength $bsig] clock=[llength $bclk]"
    set fixed [filter -quiet $bnets {IS_ROUTE_FIXED}]
    if {[llength $fixed]} { set_property IS_ROUTE_FIXED 0 $fixed }
    # Parent routes of boundary nets do not reach the new PartPins.
    if {[llength $bsig]} { route_design -unroute -nets $bsig }
    # The RP clock must be rebuilt for the new loads (Route 35-359 is expected here).
    if {[llength $bclk]} {
        route_design -unroute -nets $bclk
        update_clock_routing
    }
    # Static loads of the boundary keep their LUT pin maps (normally all locked already).
    set xun [get_nets -quiet -hierarchical -top_net_of_hierarchical_group \
                 -filter "(ROUTE_STATUS == UNROUTED || ROUTE_STATUS == PARTIAL) && TYPE == SIGNAL && NAME !~ $rp/*"]
    set loads [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects [concat $bnets $xun]] \
                   -filter "REF_NAME =~ LUT* && STATUS != UNPLACED && NAME !~ $rp/*"]
    pr_lock_lut_pins $loads boundary
    # Fix every routed static net so route_design touches only RP/boundary nets.
    set st [get_nets -quiet -hierarchical -top_net_of_hierarchical_group \
                -filter "ROUTE_STATUS == ROUTED && IS_ROUTE_FIXED == 0 && NAME !~ $rp/*"]
    if {[llength $st]} { set_property IS_ROUTE_FIXED 1 $st }
    puts "PR: fixed [llength $st] routed static nets; unrouted static signal nets=[llength $xun]"
    pr_const_rp_repair $rp $pblock pre_route
    if {[catch {route_design} e]} {
        puts "PR: route_design failed, retrying once after releasing unfixed conflicts: [string range $e 0 400]"
        set cn [get_nets -quiet -hierarchical -top_net_of_hierarchical_group -filter {ROUTE_STATUS == CONFLICTS && IS_ROUTE_FIXED == 0}]
        if {[llength $cn]} { route_design -unroute -nets $cn }
        pr_const_rp_repair $rp $pblock retry
        route_design
    }
}

# Every non-internal primitive is placed.
proc pr_check_placed {label} {
    set unpl [get_cells -quiet -hierarchical -filter {IS_PRIMITIVE && STATUS != PLACED && STATUS != FIXED && PRIMITIVE_LEVEL != INTERNAL && REF_NAME != VCC && REF_NAME != GND}]
    if {[llength $unpl]} { error "PR: ${label}: [llength $unpl] unplaced primitives, e.g. [lrange $unpl 0 3]" }
    puts "PR: ${label}: all primitives placed"
}
