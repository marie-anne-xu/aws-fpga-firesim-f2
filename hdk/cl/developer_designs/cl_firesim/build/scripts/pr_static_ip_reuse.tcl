# Pass 1: find static hierarchies next to the RP that must keep their interfaces.
proc pr_reuse_one {path} {
    set literal [string map [list \\ \\\\ \" \\\"] $path]
    set cells [get_cells -hierarchical -quiet -filter [format {NAME == "%s"} $literal]]
    if {[llength $cells] != 1} {error "PR reuse: expected exactly one cell: $path"}
    return [lindex $cells 0]
}
# The preserved hierarchies must not overlap the RP.
proc pr_reuse_guard_static {paths child} {
    foreach path $paths {
        pr_reuse_one $path
        if {$path eq $child || [string first ${child}/ $path] == 0 || [string first ${path}/ $child] == 0} {
            error "PR reuse: static IP overlaps child hierarchy: $path / $child"
        }
    }
}

# Static siblings along the RP's ancestor chain that contain LUTRAM (their placement must be kept).
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
    # SH_DDR last.
    set ddr ${container}/SH_DDR
    set index [lsearch -exact $selected $ddr]
    if {$index >= 0} {set selected [lreplace $selected $index $index]; lappend selected $ddr}
    if {![llength $selected]} {error "PR reuse: no distributed-memory static branches"}
    pr_reuse_guard_static $selected $child
    return $selected
}

