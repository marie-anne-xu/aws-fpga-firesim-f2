# Base pass 1 (sourced by build_level_1_cl.tcl before opt_design): reserve the future nested RP
# region so pass 2 (main_pr_subdivide.tcl) can reuse pass 1's static placement and routing.
if {$pr_nested_parent} {
    source ${CL_DIR}/build/scripts/pr_utils.tcl
    lassign [pr_read_paths ${checkpoints_dir}/${CL}.pr_partition_paths.txt] seed_mods seed_paths
    if {[llength $seed_paths] != 1} {error "PR seed: expected exactly one nested child"}
    set seed_path [lindex $seed_paths 0]
    if {![string match "WRAPPER/*" $seed_path]} {set seed_path WRAPPER/CL/$seed_path}
    if {[llength [get_cells -quiet $seed_path]] != 1} {error "PR seed: populated child missing"}
    set seed_region [pr_nested_region]
    if {[pr_env FIRESIM_PR_NESTED_REGION] eq ""} {
        # No recipe pr_region: derive it in a separate Vivado on a copy (opt + Quick place), so this design is untouched.
        set t0 [clock milliseconds]
        set pre_dcp ${checkpoints_dir}/${CL}.${TAG}.pre_region.dcp
        set region_file ${checkpoints_dir}/${CL}.${TAG}.derived_region.txt
        write_checkpoint -force $pre_dcp
        file delete -force $region_file
        if {[catch {exec vivado -mode batch -nojournal -log ${checkpoints_dir}/${CL}.${TAG}.derive_region.log \
                -source ${CL_DIR}/build/scripts/pr_derive_region.tcl -tclargs $pre_dcp $seed_path $region_file >@ stdout 2>@ stderr} err] \
                || ![file exists $region_file]} {
            puts "CRITICAL WARNING: PR seed: region derivation failed; using $seed_region (see ${CL}.${TAG}.derive_region.log)"
        } else {
            set fh [open $region_file r]; set seed_region [string trim [read $fh]]; close $fh
        }
        puts "PR_TIME derive_region [expr {([clock milliseconds] - $t0) / 1000.0}]"
        puts "PR: derived RP region $seed_region"
    }
    if {[llength [get_pblocks -quiet pblock_prefetcher_seed]]} {error "PR seed: pblock name already used"}
    create_pblock pblock_prefetcher_seed
    resize_pblock pblock_prefetcher_seed -add $seed_region
    set_property SNAPPING_MODE ON [get_pblocks pblock_prefetcher_seed]
    set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_prefetcher_seed]
    add_cells_to_pblock pblock_prefetcher_seed [get_cells $seed_path]
    pr_check_seed_region pblock_prefetcher_seed
    # Keep static hierarchy interfaces intact so pass 2 can import the cells unchanged.
    source ${CL_DIR}/build/scripts/pr_static_ip_reuse.tcl
    set pr_seed_static_paths [pr_reuse_memory_branches WRAPPER/CL $seed_path]
    foreach path $pr_seed_static_paths {set_property DONT_TOUCH true [pr_reuse_one $path]}
    puts "PR seed: preserving [llength $pr_seed_static_paths] static hierarchy interfaces before implementation"
    puts "PR seed: requested=$seed_region GRID_RANGES=[get_property GRID_RANGES [get_pblocks pblock_prefetcher_seed]] DERIVED_RANGES=[get_property DERIVED_RANGES [get_pblocks pblock_prefetcher_seed]]"
    # The nested base inherits this static timing; Explore closes it (build_level_1_cl.tcl reads these).
    set PLACE_DIRECT   Explore
    set PHY_OPT_DIRECT Explore
    set ROUTE_DIRECT   Explore
    puts "PR seed: nested parent directives place=$PLACE_DIRECT phys_opt=$PHY_OPT_DIRECT route=$ROUTE_DIRECT"
}
