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

# Route-completeness gate, parsed from report_route_status (the same counts the
# validated nested trial was gated on). A per-net ROUTE_STATUS scan is not used:
# in an abstract-shell (nested container) design it reports hierarchical
# segments that report_route_status does not count. Zero-count lines are
# omitted from the report, so a missing line means zero.
proc pr_check_routed {label} {
    puts "PR: route status after ${label}:"
    set st [report_route_status -ignore_cache -return_string]
    puts $st
    set errors 0
    set unrouted 0
    regexp {# of nets with routing errors\.*\s*:\s*(\d+)} $st -> errors
    regexp {# of unrouted nets\.*\s*:\s*(\d+)} $st -> unrouted
    if {$errors > 0 || $unrouted > 0} {
        error "PR: ${label}: $errors net(s) with routing errors, $unrouted unrouted;\
               refusing to ship this DCP"
    }
    puts "PR: fully routed after ${label}"
}

# Setup and hold must both close; a nested base that misses timing is not shipped.
proc pr_check_timing_met {label} {
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
    puts "PR: timing after ${label}: WNS=$wns WHS=$whs"
    foreach {name v} [list WNS $wns WHS $whs] {
        if {$v ne "" && [string is double -strict $v] && $v < 0} {
            error "PR: ${label} fails timing ($name=$v)"
        }
    }
}

# DFX DRC gate: fail on any HDPR rule reported at Error or Critical Warning.
proc pr_check_hdpr_drc {label rpt} {
    set checks [get_drc_checks -quiet HDPR-*]
    if {![llength $checks]} { error "PR: no HDPR DRC checks available" }
    set txt [report_drc -checks $checks -return_string]
    set fh [open $rpt w]; puts $fh $txt; close $fh
    set bad {}
    foreach line [split $txt "\n"] {
        if {[regexp {^\|\s*(HDPR-\d+)\s*\|\s*([^|]*?)\s*\|.*\|\s*(\d+)\s*\|\s*$} $line -> rule sev n]} {
            puts "PR: ${label} DRC $rule ($sev): $n"
            if {$n > 0 && [regexp -nocase {error|critical} $sev]} { lappend bad "$rule=$n" }
        }
    }
    if {[llength $bad]} { error "PR: ${label} HDPR DRC violations: $bad (see $rpt)" }
    puts "PR: ${label} HDPR DRC clean ($rpt)"
}

# Nested child region. The validated base (trial g9_cell_const_unroute) uses two
# whole clock regions in SLR0. FIRESIM_PR_NESTED_REGION overrides it.
# platforms/f2/build-bitstream.sh still exports the superseded SLR2 default as
# PR_PBLOCK_REGION, so that variable does not choose the nested-parent region.
proc pr_nested_region {} {
    return [pr_env FIRESIM_PR_NESTED_REGION {CLOCKREGION_X1Y0:CLOCKREGION_X2Y0}]
}

# Pass-1 guard on the child reservation: the slices must lie inside pblock_CL,
# within one SLR, and must not hold shell or SH_DDR cells.
proc pr_check_seed_region {pblock {min_slices 3000}} {
    set pb [get_pblocks $pblock]
    set allowed [dict create]
    foreach site [get_sites -of_objects [get_pblocks pblock_CL]] {dict set allowed [get_property NAME $site] 1}
    set slrs [dict create]
    set n 0
    foreach site [get_sites -of_objects $pb -filter {SITE_TYPE =~ SLICE*}] {
        set name [get_property NAME $site]
        incr n
        if {![dict exists $allowed $name]} { error "PR seed: region leaves the AWS CL at $name" }
        dict set slrs [get_property NAME [get_slrs -of_objects $site]] 1
        foreach occupant [get_cells -quiet -of_objects $site] {
            set o [get_property NAME $occupant]
            if {![string match WRAPPER/CL/* $o]} { error "PR seed: region overlaps shell cell $o" }
            if {[string match WRAPPER/CL/SH_DDR/* $o]} { error "PR seed: region overlaps DDR cell $o" }
        }
    }
    if {[dict size $slrs] != 1} { error "PR seed: region spans SLRs [dict keys $slrs]" }
    if {$n < $min_slices} { error "PR seed: region has only $n slice sites (< $min_slices)" }
    puts "PR seed: region guard passed: slices=$n slr=[dict keys $slrs] ranges=[get_property GRID_RANGES $pb]"
}

# Give constant RM output bits distinct preserved drivers (UG909 unique-driver
# requirement). Run on the standalone OOC RM before writing its checkpoint.
proc pr_fix_constant_output_drivers {} {
    set index 0
    foreach port [get_ports -filter {DIRECTION == OUT}] {
        set net [get_nets -quiet -of_objects $port]
        set drivers [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == OUT}]
        if {[llength $drivers] != 1} {continue}
        set ref [get_property REF_NAME [get_cells -of_objects $drivers]]
        if {$ref ni {GND VCC}} {continue}
        set name dfx_output_constant_$index
        if {[llength [get_cells -quiet $name]]} {error "PR: reserved output driver name already exists: $name"}
        create_cell -reference LUT1 $name
        set_property INIT [expr {$ref eq "GND" ? "2'h0" : "2'h3"}] [get_cells $name]
        set_property DONT_TOUCH true [get_cells $name]
        connect_net -net $net -objects [get_pins $name/I0]
        disconnect_net -net $net -objects $port
        create_net ${name}_net
        connect_net -net [get_nets ${name}_net] -objects [list $port [get_pins $name/O]]
        puts "PR: unique constant output driver: $port -> $name/O ($ref)"
        incr index
    }
    puts "PR: created $index distinct constant RM output drivers"
    return $index
}
