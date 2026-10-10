# Reserve the future nested RP while implementing the outer CL parent.
# Source after pass-one user XDC, before opt_design, only for nested parent.
if {$pr_nested_parent} {
    source ${CL_DIR}/build/scripts/pr_utils.tcl
    lassign [pr_read_paths ${checkpoints_dir}/${CL}.pr_partition_paths.txt] seed_mods seed_paths
    if {[llength $seed_paths] != 1} {error "PR seed: expected exactly one nested child"}
    set seed_path [lindex $seed_paths 0]
    if {![string match "WRAPPER/*" $seed_path]} {set seed_path WRAPPER/CL/$seed_path}
    if {[llength [get_cells -quiet $seed_path]] != 1} {error "PR seed: populated child missing"}
    set seed_region [pr_env PR_PBLOCK_REGION {CLOCKREGION_X1Y8:CLOCKREGION_X2Y9}]
    if {[llength [get_pblocks -quiet pblock_prefetcher_seed]]} {error "PR seed: pblock name already used"}
    create_pblock pblock_prefetcher_seed
    resize_pblock pblock_prefetcher_seed -add $seed_region
    set_property SNAPPING_MODE ON [get_pblocks pblock_prefetcher_seed]
    set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_prefetcher_seed]
    add_cells_to_pblock pblock_prefetcher_seed [get_cells $seed_path]
    # Preserve static interface pins before opt/placement can replicate
    # reset/control logic across boundaries needed by later cell DCP imports.
    source ${CL_DIR}/build/scripts/pr_static_ip_reuse.tcl
    set pr_seed_static_paths [pr_reuse_memory_branches WRAPPER/CL $seed_path]
    foreach path $pr_seed_static_paths {set_property DONT_TOUCH true [pr_reuse_one $path]}
    set pr_seed_static_fh [open ${checkpoints_dir}/${CL}.pr_static_reuse_paths.tcl w]
    puts $pr_seed_static_fh [list set pr_seed_static_paths $pr_seed_static_paths]
    close $pr_seed_static_fh
    puts "PR seed: preserving [llength $pr_seed_static_paths] static hierarchy interfaces before implementation"
    puts "PR seed: requested=$seed_region GRID_RANGES=[get_property GRID_RANGES [get_pblocks pblock_prefetcher_seed]] DERIVED_RANGES=[get_property DERIVED_RANGES [get_pblocks pblock_prefetcher_seed]]"
}
