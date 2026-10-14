# Static checkpoint reuse helpers. Full nested implementation validation is in progress.
proc pr_reuse_one {path} {
    set literal [string map [list \\ \\\\ \" \\\"] $path]
    set cells [get_cells -hierarchical -quiet -filter [format {NAME == "%s"} $literal]]
    if {[llength $cells] != 1} {error "PR reuse: expected exactly one cell: $path"}
    return [lindex $cells 0]
}
# Imported checkpoints can retain only a subset of source placement. The
# pre-placement phases permit this, but require the native PHY and the complete
# previously failing RAM/FF groups. Source and post-place phases remain complete.
proc pr_reuse_guard_static {paths child} {
    foreach path $paths {
        pr_reuse_one $path
        if {$path eq $child || [string first ${child}/ $path] == 0 || [string first ${path}/ $child] == 0} {
            error "PR reuse: static IP overlaps child hierarchy: $path / $child"
        }
    }
}

# Discover disjoint static sibling hierarchies along the child ancestor chain.
# Select distributed-memory branches; BRAM-only branches are not affected by
# the observed LUTRAM/FF placement shapes. This matches the source inventory.
proc pr_reuse_memory_branches {container child} {
    if {[string first ${container}/ $child] != 0} {error "PR reuse: child outside container"}
    set ancestors [dict create]
    set path $child
    while {$path ne $container} {
        set path [file dirname $path]
        dict set ancestors $path 1
    }
    set roots [dict create]
    foreach cell [get_cells -hierarchical -filter {IS_PRIMITIVE == 0}] {
        set name [get_property NAME $cell]
        if {[dict exists $ancestors [file dirname $name]] && ![dict exists $ancestors $name] && $name ne $child} {
            dict set roots $name 0
        }
    }
    foreach cell [get_cells -hierarchical -filter {IS_PRIMITIVE == 1}] {
        set ref [get_property REF_NAME $cell]
        if {![string match RAM* $ref] || [string match RAMB* $ref]} {continue}
        set name [get_property NAME $cell]
        foreach root [dict keys $roots] {
            if {[string first ${root}/ $name] == 0} {dict incr roots $root; break}
        }
    }
    set selected {}
    foreach root [lsort [dict keys $roots]] {
        if {[dict get $roots $root] > 0} {lappend selected $root}
    }
    # Import MIG last: importing other checkpoints after it invalidated MIG
    # IO placement in the earlier converter/DDR assembly trial.
    set ddr ${container}/SH_DDR
    set index [lsearch -exact $selected $ddr]
    if {$index >= 0} {set selected [lreplace $selected $index $index]; lappend selected $ddr}
    if {![llength $selected]} {error "PR reuse: no distributed-memory static branches"}
    pr_reuse_guard_static $selected $child
    return $selected
}

