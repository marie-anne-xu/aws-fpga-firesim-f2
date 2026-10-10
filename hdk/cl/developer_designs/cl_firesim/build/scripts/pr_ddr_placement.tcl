# Preserve native DDR PHY anchors across UG909 pr_subdivide. I/O buffers
# remain anchored by their package pins; DDR fabric logic is placed normally.
proc pr_capture_ddr_placement {} {
    set result [dict create]
    foreach port [get_ports -quiet {CLK_DIMM_DP CLK_DIMM_DN}] {
        puts "PR: DDR clock port $port: [get_property PACKAGE_PIN $port] / [get_property LOC $port]"
    }
    set cells [get_cells -hierarchical -quiet -filter {IS_PRIMITIVE == 1 && NAME =~ "WRAPPER/CL/SH_DDR/*"}]
    foreach cell $cells {
        set loc [get_property LOC $cell]
        set bel [get_property BEL $cell]
        if {$loc eq "" || $bel eq ""} { continue }
        set type [lindex [split $bel .] 0]
        # I/O buffers are placed from the package-pin constraints. Unplacing
        # those macros also unplaces their top-level terminals (Vivado 12-4778).
        if {$type ni {BITSLICE_RX_TX BITSLICE_TX BITSLICE_CONTROL RIU_OR PLL MMCM BUFGCE}} { continue }
        dict set result [get_property NAME $cell] [list $loc [lindex [split $bel .] end]]
    }
    puts "PR: captured [dict size $result] DDR PHY and clock placements"
    if {[llength $cells] && ![dict size $result]} {
        error "PR: SH_DDR exists but no physical DDR anchors were captured"
    }
    return $result
}

proc pr_restore_ddr_placement {placement} {
    if {![dict size $placement]} { return }
    # Use cell objects returned by traversal, never a glob lookup of generated
    # names containing brackets. Resolve every name before modifying placement.
    set cells [get_cells -hierarchical -quiet -filter {IS_PRIMITIVE == 1 && NAME =~ "WRAPPER/CL/SH_DDR/*"}]
    set matched [dict create]
    foreach cell $cells name [get_property NAME $cells] {
        if {[dict exists $placement $name]} { dict set matched $name $cell }
    }
    set missing {}
    foreach name [dict keys $placement] {
        if {![dict exists $matched $name]} { lappend missing $name }
    }
    if {[llength $missing]} {
        error "PR: missing [llength $missing] captured DDR anchors after subdivision: [lrange $missing 0 7]"
    }
    # Free the whole set first, since reload can permute bitslices among sites.
    foreach cell [dict values $matched] {
        unplace_cell $cell
        reset_property LOC $cell
        reset_property BEL $cell
    }
    dict for {name cell} $matched {
        lassign [dict get $placement $name] loc bel
        set_property BEL $bel $cell
    }
    dict for {name cell} $matched {
        lassign [dict get $placement $name] loc bel
        set_property LOC $loc $cell
        if {[get_property LOC $cell] ne $loc || ![get_property IS_LOC_FIXED $cell]} {
            error "PR: DDR anchor restoration failed for $name"
        }
    }
    puts "PR: restored [dict size $matched] DDR anchors to their parent implementation sites"
}
