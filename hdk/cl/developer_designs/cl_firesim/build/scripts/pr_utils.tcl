# FireSim nested-DFX helpers for AWS F2. WRAPPER/CL is already AWS's partition,
# so the prefetcher RP nests inside it; every flow ends in a routed checkpoint.

# Env set by platforms/f2/build-bitstream.sh.
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

# Named --option tclargs: pr_parse_args $argv {required ...} {optional ...}
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

# The RM instance path changes between elaborations, so find it by module name.
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

# Fail on routing errors/unrouted nets. Uses report_route_status: per-net ROUTE_STATUS
# over-reports hierarchical segments in a nested design. Missing line = zero.
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

# Setup and hold must both close before shipping.
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

# Nested RP region: two SLR0 clock regions unless FIRESIM_PR_NESTED_REGION is set.
proc pr_nested_region {} {
    return [pr_env FIRESIM_PR_NESTED_REGION {CLOCKREGION_X1Y0:CLOCKREGION_X2Y0}]
}

# The reserved RP region must be inside pblock_CL, in one SLR, and free of shell/DDR cells.
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

# DFX needs a unique driver per RM output: give constant outputs their own LUT1 (OOC RM only).
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

# AWS's DDR calibration BRAM check; supplies AWS's print proc outside build_all.tcl.
proc pr_check_ddr_bram {} {
    if {![llength [info procs ::print]]} { proc ::print {m} { puts "AWS FPGA: $m" } }
    uplevel #0 [list source [pr_env HDK_SHELL_DIR]/build/scripts/check_ddr_bram.tcl]
}
