# FireSim prefetcher-swap helpers for AWS F2 (RapidWright shell flow).

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

# Fail on routing errors/unrouted nets (report_route_status; missing line = zero).
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

# AWS's DDR calibration BRAM check; supplies AWS's print proc outside build_all.tcl.
proc pr_check_ddr_bram {} {
    if {![llength [info procs ::print]]} { proc ::print {m} { puts "AWS FPGA: $m" } }
    uplevel #0 [list source [pr_env HDK_SHELL_DIR]/build/scripts/check_ddr_bram.tcl]
}
