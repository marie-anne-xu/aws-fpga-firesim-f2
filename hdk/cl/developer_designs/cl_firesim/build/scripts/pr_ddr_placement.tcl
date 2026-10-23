# The DDR4 PHY (SH_DDR) is inside the subdivided partition and can't be re-placed (Place 30-687),
# so pass 2 imports it placed from pass 1; these procs freeze and check it. No opt_design after.

# Freeze SH_DDR exactly as imported. It must not be optimized, moved, or replaced.
proc pr_lock_ddr_placement {} {
    set ddr [get_cells -quiet WRAPPER/CL/SH_DDR]
    if {[llength $ddr] != 1} { error "PR: WRAPPER/CL/SH_DDR not found after subdivision" }
    set_property DONT_TOUCH true $ddr
    lock_design -level placement $ddr
    puts "PR: SH_DDR placement locked"
}

# Every native RXTX bitslice must be placed with LOC and BEL fixed.
proc pr_check_ddr_anchors {label} {
    set bs [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ *RXTX_BITSLICE* && NAME =~ WRAPPER/CL/SH_DDR/*}]
    if {![llength $bs]} { error "PR: ${label}: no SH_DDR RXTX bitslices found" }
    set bad {}
    foreach c $bs {
        if {[get_property LOC $c] eq "" || ![get_property IS_LOC_FIXED $c] || ![get_property IS_BEL_FIXED $c]} {
            lappend bad [get_property NAME $c]
        }
    }
    if {[llength $bad]} {
        error "PR: ${label}: [llength $bad]/[llength $bs] DDR bitslices not placed+fixed: [lrange $bad 0 3]"
    }
    puts "PR: ${label}: all [llength $bs] DDR RXTX bitslices placed with LOC/BEL fixed"
}
