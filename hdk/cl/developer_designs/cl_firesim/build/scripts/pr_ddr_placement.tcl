# Native DDR PHY handling for the nested parent (pass 2).
#
# The AWS DDR4 PHY (WRAPPER/CL/SH_DDR) is inside the partition being subdivided.
# Reloading it from the post-synth netlist unplaces its native-mode bitslices
# (Place 30-687/30-686), and regenerating the MIG (opt_design or
# implement_xphy_cores) discards any LOC restore. main_pr_subdivide.tcl
# therefore runs pr_subdivide from the *placed* pass-1 CL cell checkpoint, so
# SH_DDR arrives already placed and generated. The procs below only freeze that
# placement and check it. Never run opt_design on the subdivided design.

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
