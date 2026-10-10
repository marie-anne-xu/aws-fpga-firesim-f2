# =============================================================================
# PARENT pass 2/2 -- nested DFX via pr_subdivide (AWS F2).

# UG909 describes nested DFX as "step and repeat through hierarchy": pass 1 is a
# outer-RP fully-routed build, pass 2 subdivides. pr_subdivide moves
# HD.RECONFIGURABLE from WRAPPER/CL down to the RM and marks WRAPPER/CL as
# HD.RECONFIGURABLE_CONTAINER -- which is why declaring both as RPs in one
# link_design fails DRC HDPR-13.

# It internally runs update_design -black_box, lock_design -level routing, and
# loads the CL post-synth netlist, so none of those are done by hand here.

#   vivado -mode batch -source main_pr_subdivide.tcl -tclargs \
#     --cl_dir <dir> --build_tag <tag> --pr_module_name <mod> \
#     [--cl_name <name>] [--pblock_region <CLOCKREGION_..:CLOCKREGION_..>]
#     [--output_dir <dir>]  (defaults to the build checkpoints directory)
# =============================================================================

set script_start_time [clock seconds]
set scripts_dir [file dirname [file normalize [info script]]]
source ${scripts_dir}/pr_utils.tcl
source ${scripts_dir}/pr_ddr_placement.tcl

set opts [pr_parse_args $argv {cl_dir build_tag pr_module_name} {cl_name pblock_region clock_recipes output_dir}]
set CL_DIR    [dict get $opts cl_dir]
set TAG       [dict get $opts build_tag]
set PR_MODULE [dict get $opts pr_module_name]
set CL        [pr_opt $opts cl_name cl_firesim]
# Four clock regions in lower-left SLR2, near the prefetcher's original location.
# The current routed parent has zero DDR placements and fixed shell sites in
# this region, with 7,440 usable slice sites. Whole-region boundaries support
# SNAPPING_MODE; RESET_AFTER_RECONFIG is not supported on this device.
# --pblock_region overrides this (build-bitstream.sh passes PR_PBLOCK_REGION).
set REGION [list [pr_opt $opts pblock_region {CLOCKREGION_X1Y8:CLOCKREGION_X2Y9}]]

set checkpoints_dir ${CL_DIR}/build/checkpoints
set reports_dir     ${CL_DIR}/build/reports
set output_dir [pr_opt $opts output_dir $checkpoints_dir]
file mkdir $output_dir

# Pass 1's CL routing is discarded by pr_subdivide, so its timing does not
# matter -- accept the VIOLATED name too. Only pass 2's result becomes the base.
set routed_dcp ${checkpoints_dir}/${CL}.${TAG}.post_route.dcp
if {![file exists $routed_dcp]} {
    set violated ${checkpoints_dir}/${CL}.${TAG}.post_route.VIOLATED.dcp
    if {[file exists $violated]} {
        puts "PR: pass 1 missed timing; using $violated (its routing is discarded anyway)"
        set routed_dcp $violated
    } else {
        error "PR: no pass-1 routed checkpoint in $checkpoints_dir"
    }
}
set cl_synth ${checkpoints_dir}/${CL}.${TAG}.post_synth.dcp
if {![file exists $cl_synth]} { error "PR: pass-1 CL netlist missing: $cl_synth" }

puts "PR: opening pass-1 routed checkpoint"
open_checkpoint $routed_dcp

# The RM must exist as populated hierarchy in the routed outer-CL design.
# Parent synthesis assembles it from its independent OOC checkpoint to preserve
# the interface. Discover its full path (already WRAPPER/CL-prefixed here).
set rp_cells [get_cells -hierarchical -filter "REF_NAME == $PR_MODULE" -quiet]
if {[llength $rp_cells] != 1} {
    error "PR: expected exactly 1 instance of '$PR_MODULE', found [llength $rp_cells]"
}
set rp_path [get_property NAME [lindex $rp_cells 0]]
puts "PR: subdividing WRAPPER/CL -> $rp_path"

# UG909 2025.2: pr_subdivide reloads a synthesized parent RM. Capture the
# package-pin-dependent DDR primitives before it discards the parent placement.
set ddr_placement [pr_capture_ddr_placement]
# read_checkpoint inside pr_subdivide invalidates Vivado object-valued Tcl
# variables (Vivado 12-12435). Serialize the capture so names and sites are
# restored as plain strings, independent of the old design database.
set ddr_placement_file ${output_dir}/${CL}.${TAG}.ddr_phy_placement.tcl
set ddr_placement_fh [open $ddr_placement_file w]
puts $ddr_placement_fh [list set ddr_placement $ddr_placement]
close $ddr_placement_fh
pr_subdivide -cell WRAPPER/CL -subcells [list $rp_path] $cl_synth
source $ddr_placement_file

# Re-apply CL implementation constraints after the synthesized netlist reload.
set HDK_SHELL_DIR [pr_env HDK_SHELL_DIR]
set SHELL_MODE    [pr_env SHELL_MODE small_shell]
if {$HDK_SHELL_DIR eq ""} { error "PR: HDK_SHELL_DIR not set (source hdk_setup.sh)" }

# aws_clock_properties.tcl reads these as globals; build_all.tcl sets them from
# argv in pass 1 (:134-137), but pass 2 is a standalone vivado invocation.
lassign [pr_split [pr_opt $opts clock_recipes "A1,B0,C0,H2"]] \
        clock_recipe_a clock_recipe_b clock_recipe_c clock_recipe_hbm
puts "PR: clock recipes = $clock_recipe_a $clock_recipe_b $clock_recipe_c $clock_recipe_hbm"

puts "PR: re-applying clock properties"
source ${HDK_SHELL_DIR}/build/scripts/aws_clock_properties.tcl

# Do not replay the OOC generated clocks at device scope (clk_main_a0 is a CL
# boundary pin). Carving an RM clears its embedded I/O constraints, so apply
# package pins before optimization so the I/O macros are expanded consistently.
puts "PR: applying embedded DDR package-pin constraints before optimization"
read_xdc ${HDK_SHELL_DIR}/build/constraints/cl_pins.xdc
# Scope CL timing constraints by instance, not the output artifact filename.
puts "PR: re-applying CL-scoped timing constraints"
read_xdc -cells [get_cells WRAPPER/CL] ${HDK_SHELL_DIR}/build/constraints/cl_ddr_timing_aws.xdc

puts "PR: re-applying floorplan constraints"
read_xdc ${HDK_SHELL_DIR}/build/constraints/${SHELL_MODE}_level_1_fp_cl.xdc
read_xdc ${CL_DIR}/build/constraints/${SHELL_MODE}_cl_pnr_user.xdc

# Retain AWS's DDR timing-oriented placement policy for the nested parent.
source ${HDK_SHELL_DIR}/build/scripts/ddr_io_train.tcl

# Package pins anchor I/O buffers. Keep the captured PHY placements for
# diagnostics; replaying leaf LOC/BEL constraints breaks expanded I/O shapes.

# Carve the RP region out of the SLR grouping pblocks so the only pblock that
# geometrically encloses the RP is its true container, pblock_CL. Otherwise
# Vivado attributes the RP to the enclosing grouping pblock (DRC HDPR-2).
foreach rng $REGION {
    foreach grp {pblock_CL_SLR0 pblock_CL_SLR1 pblock_CL_SLR2} {
        if {[llength [get_pblocks -quiet $grp]] > 0} {
            resize_pblock $grp -remove $rng
        }
    }
}

# Floorplan the new child RP. Parent is ROOT (DRC HDPR-2); EXCLUDE_PLACEMENT and
# CONTAIN_ROUTING are required on a reconfigurable cell's pblock.
create_pblock pblock_pr_region_0
foreach rng $REGION {
    puts "PR:   region += $rng"
    resize_pblock pblock_pr_region_0 -add $rng
}
set_property SNAPPING_MODE ON        [get_pblocks pblock_pr_region_0]
set_property EXCLUDE_PLACEMENT true  [get_pblocks pblock_pr_region_0]
set_property CONTAIN_ROUTING true    [get_pblocks pblock_pr_region_0]
add_cells_to_pblock pblock_pr_region_0 [get_cells $rp_path] -clear_locs

write_checkpoint -force ${output_dir}/${CL}.${TAG}.pr_subdivide.pre_opt.dcp
opt_design
write_checkpoint -force ${output_dir}/${CL}.${TAG}.pr_subdivide.post_opt.dcp
# Let placement construct the physical I/O shapes from the early package-pin
# constraints. Do not replay independent DDR leaf placements after expansion.
write_checkpoint -force ${output_dir}/${CL}.${TAG}.pr_subdivide.pre_place.dcp
place_design
write_checkpoint -force ${output_dir}/${CL}.${TAG}.pr_subdivide.post_place.dcp
phys_opt_design
route_design -tns_cleanup

pr_check_routed "pr_subdivide implementation"

report_utilization -cells [get_cells $rp_path] \
                   -file ${reports_dir}/${CL}.${TAG}.pr_subdivide_utilization.rpt
report_timing_summary -file ${reports_dir}/${CL}.${TAG}.pr_subdivide_timing.rpt

# Overwrite pass 1's checkpoint: this is the real base, with the RM as an RP.
set nested_dcp ${output_dir}/${CL}.${TAG}.post_route.dcp
puts "PR: writing subdivided base checkpoint: $nested_dcp"
write_checkpoint -force $nested_dcp

pr_write_paths ${output_dir}/${CL}.pr_partition_paths.txt [list $PR_MODULE] [list $rp_path]

close_design
puts "PR: subdivide complete in [expr {[clock seconds] - $script_start_time}]s"
