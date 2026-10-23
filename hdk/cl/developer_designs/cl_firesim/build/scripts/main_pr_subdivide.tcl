# Base flow pass 2: nested DFX. Pass 1 routed the full CL with the RP region reserved
# (pr_seed_reservation.tcl); here pr_subdivide makes the prefetcher an RP inside WRAPPER/CL,
# reusing pass 1's static placement/routing and implementing only the RP.
#   vivado -mode batch -source main_pr_subdivide.tcl -tclargs --cl_dir <dir> --build_tag <tag> \
#     --pr_module_name <mod> [--cl_name <name>] [--clock_recipes A,B,C,HBM] [--output_dir <dir>]

set script_start_time [clock seconds]
set scripts_dir [file dirname [file normalize [info script]]]
source ${scripts_dir}/pr_utils.tcl
source ${scripts_dir}/pr_ddr_placement.tcl
source ${scripts_dir}/pr_nested_impl.tcl

set opts [pr_parse_args $argv {cl_dir build_tag pr_module_name} {cl_name clock_recipes output_dir}]
set CL_DIR    [dict get $opts cl_dir]
set TAG       [dict get $opts build_tag]
set PR_MODULE [dict get $opts pr_module_name]
set CL        [pr_opt $opts cl_name cl_firesim]

set checkpoints_dir ${CL_DIR}/build/checkpoints
set reports_dir     ${CL_DIR}/build/reports
set constraints_dir ${CL_DIR}/build/constraints
set output_dir [pr_opt $opts output_dir $checkpoints_dir]
file mkdir $output_dir $reports_dir

set HDK_SHELL_DIR [pr_env HDK_SHELL_DIR]
set SHELL_MODE    [pr_env SHELL_MODE small_shell]
if {$HDK_SHELL_DIR eq ""} { error "PR: HDK_SHELL_DIR not set (source hdk_setup.sh)" }
set shell_dcp ${HDK_SHELL_DIR}/build/checkpoints/from_aws/cl_bb_routed.${SHELL_MODE}.dcp

# A VIOLATED pass 1 is accepted; the final timing gate decides.
set routed_dcp ${checkpoints_dir}/${CL}.${TAG}.post_route.dcp
if {![file exists $routed_dcp]} {
    set violated ${checkpoints_dir}/${CL}.${TAG}.post_route.VIOLATED.dcp
    if {[file exists $violated]} {
        puts "PR: pass 1 missed timing; reusing $violated (static timing carries over)"
        set routed_dcp $violated
    } else {
        error "PR: no pass-1 routed checkpoint in $checkpoints_dir"
    }
}
foreach f [list $routed_dcp $shell_dcp] {
    if {![file exists $f]} { error "PR: missing input checkpoint $f" }
}

# a. clean placed CL cell from the routed parent
puts "PR: opening pass-1 routed checkpoint $routed_dcp"
open_checkpoint $routed_dcp

set rp_cells [get_cells -hierarchical -filter "REF_NAME == $PR_MODULE" -quiet]
if {[llength $rp_cells] != 1} {
    error "PR: expected exactly 1 instance of '$PR_MODULE', found [llength $rp_cells]"
}
set rp_path [get_property NAME [lindex $rp_cells 0]]
if {[regexp {[][*?\\]} $rp_path]} { error "PR: RP path contains glob characters: $rp_path" }
puts "PR: subdividing WRAPPER/CL -> $rp_path"

# Static routes were built around pass 1's reservation, so the RP goes exactly there.
set seed_pb [get_pblocks -quiet pblock_prefetcher_seed]
if {[llength $seed_pb] != 1} { error "PR: pass-1 parent has no pblock_prefetcher_seed reservation" }
set REGION [get_property GRID_RANGES $seed_pb]
puts "PR: child region = $REGION"
set rp_placed [llength [get_cells -quiet -hierarchical -filter "IS_PRIMITIVE && STATUS != UNPLACED && NAME =~ $rp_path/*"]]
puts "PR: parent RP primitives placed=$rp_placed"

set cell_dcp  ${output_dir}/${CL}.${TAG}.pr_cl_cell.dcp
set clean_dcp ${output_dir}/${CL}.${TAG}.pr_cl_clean.dcp
pr_write_clean_cl_cell $cell_dcp $clean_dcp

# b. subdivide inside the locked AWS shell
puts "PR: opening AWS shell $shell_dcp"
open_checkpoint $shell_dcp
lock_design -level routing
pr_subdivide -cell WRAPPER/CL -subcells [list $rp_path] $clean_dcp
if {![get_property HD.RECONFIGURABLE_CONTAINER [get_cells WRAPPER/CL]] || ![get_property HD.RECONFIGURABLE [get_cells $rp_path]]} {
    error "PR: pr_subdivide did not produce WRAPPER/CL container + RP $rp_path"
}
puts "PR: subdivided in [expr {[clock seconds] - $script_start_time}]s"

# Re-apply CL constraints (aws_clock_properties.tcl reads the recipes as globals).
lassign [pr_split [pr_opt $opts clock_recipes "A1,B0,C0,H2"]] \
        clock_recipe_a clock_recipe_b clock_recipe_c clock_recipe_hbm
puts "PR: clock recipes = $clock_recipe_a $clock_recipe_b $clock_recipe_c $clock_recipe_hbm"
source ${HDK_SHELL_DIR}/build/scripts/aws_clock_properties.tcl
read_xdc ${HDK_SHELL_DIR}/build/constraints/cl_pins.xdc
read_xdc -cells [get_cells WRAPPER/CL] ${HDK_SHELL_DIR}/build/constraints/cl_ddr_timing_aws.xdc
read_xdc ${HDK_SHELL_DIR}/build/constraints/${SHELL_MODE}_level_1_fp_cl.xdc
read_xdc ${constraints_dir}/${SHELL_MODE}_cl_pnr_user.xdc
source ${HDK_SHELL_DIR}/build/scripts/ddr_io_train.tcl
# Shell SPI timing from top_late.xdc is lost by pr_subdivide.
read_xdc ${constraints_dir}/pr_nested_shell_timing.xdc
foreach clk {clk_core clk_spi} {
    if {![llength [get_clocks -quiet $clk]]} { puts "PR: NOTE shell clock $clk not found; SPI timing parity incomplete" }
}

# c. freeze static, implement the RP only
set rp_pblock [pr_make_rp_pblock $rp_path $REGION]
pr_lock_static_lut_pins $rp_path
pr_lock_ddr_placement
pr_unplace_partial_macros $rp_path
pr_lock_static_except_rp $rp_path
pr_set_partpin_ranges $rp_path $rp_pblock
pr_check_ddr_anchors pre_place

write_checkpoint -force ${output_dir}/${CL}.${TAG}.pr_subdivide.pre_place.dcp
# No opt_design: it regenerates the MIG and unplaces the DDR PHY.
place_design
write_checkpoint -force ${output_dir}/${CL}.${TAG}.pr_subdivide.post_place.dcp
pr_check_placed post_place
pr_check_ddr_anchors post_place

# Route and gate; on any failure keep the design for debugging.
if {[catch {
    pr_route_rp $rp_path $rp_pblock

    report_utilization -cells [get_cells $rp_path] \
                       -file ${reports_dir}/${CL}.${TAG}.pr_subdivide_utilization.rpt
    report_timing_summary -file ${reports_dir}/${CL}.${TAG}.pr_subdivide_timing.rpt
    report_route_status -file ${reports_dir}/${CL}.${TAG}.pr_subdivide_route_status.rpt
    pr_check_routed "pr_subdivide implementation"
    pr_check_ddr_anchors post_route
    pr_check_hdpr_drc "pr_subdivide implementation" ${reports_dir}/${CL}.${TAG}.pr_subdivide_hdpr_drc.rpt
    pr_check_timing_met "pr_subdivide implementation"
} gate_err]} {
    write_checkpoint -force ${output_dir}/${CL}.${TAG}.pr_subdivide.post_route.FAILED.dcp
    error $gate_err
}

# Overwrite pass 1's checkpoint: this is the real base, with the RM as an RP.
pr_check_ddr_bram
set nested_dcp ${output_dir}/${CL}.${TAG}.post_route.dcp
puts "PR: writing subdivided base checkpoint: $nested_dcp"
write_checkpoint -force $nested_dcp

pr_write_paths ${output_dir}/${CL}.pr_partition_paths.txt [list $PR_MODULE] [list $rp_path]

close_design
puts "PR: subdivide complete in [expr {[clock seconds] - $script_start_time}]s"
