# =============================================================================
# FireSim partial reconfiguration (DFX) utilities -- AWS F2.
# Non-project-mode counterpart of the U250 flow in
# platforms/xilinx_alveo_u250/cl_firesim/scripts/.
#
# WRAPPER/CL is already AWS's DFX partition, so an RM inside it is nested DFX.
# No local write_bitstream on F2: every flow ends in write_checkpoint.
# HD.RECONFIGURABLE + pblock live in the user XDC (build_level_1_cl.tcl:56).
# =============================================================================

# Env plumbing for the parent flow; platforms/f2/build-bitstream.sh exports these.
proc pr_env {name {default ""}} {
    if {[info exists ::env($name)]} {
        return $::env($name)
    }
    return $default
}

proc pr_enabled {} {
    set v [string tolower [pr_env FIRESIM_PR_ENABLE 0]]
    return [expr {$v ni {0 "" false no}}]
}

# Comma-separated value -> Tcl list, whitespace trimmed.
proc pr_split {s} {
    set out {}
    foreach item [split $s ","] {
        set item [string trim $item]
        if {$item ne ""} { lappend out $item }
    }
    return $out
}

# Named-option tclargs parsing for the child flows, whose vivado calls we own.
#   set opts [pr_parse_args $argv {cl_dir build_tag} {device_type}]
proc pr_parse_args {arglist required {optional {}}} {
    set opts [dict create]
    set n [llength $arglist]
    for {set i 0} {$i < $n} {incr i} {
        set tok [lindex $arglist $i]
        if {![string match "--*" $tok]} {
            error "PR: expected a --option but got '$tok'.\
                   Usage: [join [concat $required $optional] " --"]"
        }
        set key [string range $tok 2 end]
        if {$key ni [concat $required $optional]} {
            error "PR: unknown option --$key.\
                   Accepted: --[join [concat $required $optional] " --"]"
        }
        incr i
        if {$i >= $n} { error "PR: option --$key has no value" }
        dict set opts $key [lindex $arglist $i]
    }
    foreach key $required {
        if {![dict exists $opts $key] || [string trim [dict get $opts $key]] eq ""} {
            error "PR: required option --$key is missing or empty"
        }
    }
    return $opts
}

# Fetch an optional arg, falling back to a default.
proc pr_opt {opts key {default ""}} {
    if {[dict exists $opts $key] && [string trim [dict get $opts $key]] ne ""} {
        return [dict get $opts $key]
    }
    return $default
}

# Partition discovery. The Golden Gate path shifts between elaborations, so
# derive it rather than guess. Mirrors U250 post_synth_pr.tcl:13.
proc pr_discover_paths {module_names} {
    set paths {}
    foreach mod $module_names {
        set cells [get_cells -hierarchical -filter "REF_NAME == $mod" -quiet]
        if {[llength $cells] == 0} {
            error "PR: no instance of module '$mod' found in the synthesized design"
        }
        puts "PR: found [llength $cells] instance(s) of '$mod'"
        foreach cell $cells {
            lappend paths [get_property NAME $cell]
        }
    }
    return $paths
}

# Vivado errors on a missing module ([Synth 8-439]) rather than inferring a black
# box, so the withheld RM needs an empty stub carrying its real port list.
proc pr_write_stub {src_sv module out_file} {
    if {![file exists $src_sv]} { error "PR: cannot make a stub, no such file: $src_sv" }
    set fh [open $src_sv r]
    set lines {}
    set started 0
    while {[gets $fh line] >= 0} {
        if {!$started} {
            if {[regexp "^module\\s+${module}\\s*\\(" $line]} { set started 1 } else { continue }
        }
        lappend lines $line
        if {[regexp {^\s*\)\s*;} $line]} { break }
    }
    close $fh
    if {!$started} { error "PR: no 'module $module(' declaration found in $src_sv" }
    if {![regexp {^\s*\)\s*;} [lindex $lines end]]} {
        error "PR: port declaration for '$module' was not terminated in $src_sv"
    }
    set oh [open $out_file w]
    puts $oh "// Auto-generated DFX black-box stub for $module -- do not edit."
    puts $oh "(* black_box *)"
    foreach l $lines { puts $oh $l }
    puts $oh "endmodule"
    close $oh
    puts "PR: wrote black-box stub ([llength $lines] port lines) -> $out_file"
    return $out_file
}

# A cell is only an RP if synthesis left it a black box, i.e. its RTL was withheld.
proc pr_assert_blackbox {paths} {
    foreach path $paths {
        set cell [get_cells $path -quiet]
        if {$cell eq ""} {
            error "PR: partition path not found in design: $path"
        }
        if {![get_property IS_BLACKBOX $cell]} {
            error "PR: '$path' is not a black box -- its RTL was included in the\
                   static synthesis. Check that the RM .sv is excluded from the\
                   read_verilog list in synth_cl_firesim.tcl."
        }
    }
    puts "PR: all [llength $paths] partition(s) are black boxes"
}

# The user XDC's HD.RECONFIGURABLE and pblock lines must name these exactly.
proc pr_report_paths {paths} {
    puts "PR: ============================================================"
    puts "PR: partition path(s) -- these must match the XDC exactly:"
    foreach path $paths {
        puts "PR:   $path"
    }
    puts "PR: ============================================================"
}

proc pr_write_paths {path_file module_names paths} {
    set fh [open $path_file w]
    for {set i 0} {$i < [llength $paths]} {incr i} {
        puts $fh "[lindex $module_names $i]:[lindex $paths $i]"
    }
    close $fh
    puts "PR: wrote partition paths to $path_file"
}

proc pr_read_paths {path_file} {
    if {![file exists $path_file]} {
        error "PR: partition path file not found: $path_file\
               (was the base build run with FIRESIM_PR_ENABLE=1?)"
    }
    set modules {}
    set paths {}
    set fh [open $path_file r]
    foreach line [split [read $fh] "\n"] {
        set line [string trim $line]
        if {$line eq ""} { continue }
        set idx [string first ":" $line]
        lappend modules [string range $line 0 [expr {$idx - 1}]]
        lappend paths   [string range $line [expr {$idx + 1}] end]
    }
    close $fh
    return [list $modules $paths]
}

# Pre-submission gate. With no local write_bitstream, route status is the only
# check before a multi-hour AFI bake.
proc pr_check_routed {label} {
    puts "PR: route status after ${label}:"
    report_route_status
    set unrouted [get_nets -quiet -hierarchical \
                    -filter {ROUTE_STATUS != INTRACT && ROUTE_STATUS != ROUTED}]
    if {[llength $unrouted] > 0} {
        error "PR: [llength $unrouted] net(s) not fully routed after ${label};\
               refusing to ship this DCP"
    }
    puts "PR: fully routed after ${label}"
}
