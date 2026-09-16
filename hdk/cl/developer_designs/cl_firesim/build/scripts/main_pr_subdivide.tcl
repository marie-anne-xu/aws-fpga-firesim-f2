# =============================================================================
# PARENT pass 2/2 -- nested DFX via pr_subdivide (AWS F2).

# UG909 describes nested DFX as "step and repeat through hierarchy": pass 1 is a
# stock fully-routed build, pass 2 subdivides. pr_subdivide moves
# HD.RECONFIGURABLE from WRAPPER/CL down to the RM and marks WRAPPER/CL as
# HD.RECONFIGURABLE_CONTAINER -- which is why declaring both as RPs in one
# link_design fails DRC HDPR-13.

# It internally runs update_design -black_box, lock_design -level routing, and
# loads the CL post-synth netlist, so none of those are done by hand here.

#   vivado -mode batch -source main_pr_subdivide.tcl -tclargs \
#     --cl_dir <dir> --build_tag <tag> --pr_module_name <mod> \
#     [--cl_name <name>] [--pblock_region <CLOCKREGION_..:CLOCKREGION_..>]
# =============================================================================

set script_start_time [clock seconds]
set scripts_dir [file dirname [file normalize [info script]]]
source ${scripts_dir}/pr_utils.tcl

set opts [pr_parse_args $argv {cl_dir build_tag pr_module_name} {cl_name pblock_region clock_recipes}]
set CL_DIR    [dict get $opts cl_dir]
set TAG       [dict get $opts build_tag]
set PR_MODULE [dict get $opts pr_module_name]
set CL        [pr_opt $opts cl_name cl_firesim]
# GUI-validated site-range rectangles for the RP, chosen to avoid the DDR sites.
# Two rectangles -> one RP pblock (a partition has a single pblock; multiple
# -add regions are allowed). Site ranges, so pass via the script, not tclargs.
set REGION [list \
  {SLICE_X31Y630:SLICE_X110Y719 DSP48E2_X4Y246:DSP48E2_X14Y281 RAMB18_X2Y252:RAMB18_X6Y287 RAMB36_X2Y126:RAMB36_X6Y143 URAM288_X0Y168:URAM288_X1Y191} \
  {SLICE_X31Y525:SLICE_X89Y644 DSP48E2_X3Y204:DSP48E2_X11Y251 RAMB18_X2Y210:RAMB18_X5Y257 RAMB36_X2Y105:RAMB36_X5Y128 URAM288_X0Y140:URAM288_X0Y171} \
]

set checkpoints_dir ${CL_DIR}/build/checkpoints
set reports_dir     ${CL_DIR}/build/reports

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

# The RM must exist as real hierarchy in the routed design; pass 1 is stock, so
# it does. Discover its full path (already WRAPPER/CL-prefixed here).
set rp_cells [get_cells -hierarchical -filter "REF_NAME == $PR_MODULE" -quiet]
if {[llength $rp_cells] != 1} {
    error "PR: expected exactly 1 instance of '$PR_MODULE', found [llength $rp_cells]"
}
set rp_path [get_property NAME [lindex $rp_cells 0]]
puts "PR: subdividing WRAPPER/CL -> $rp_path"

pr_subdivide -cell WRAPPER/CL -subcells [list $rp_path] $cl_synth

# pr_subdivide unplaced the whole CL, so re-apply the constraint steps that
# build_level_1_cl.tcl:47-59 runs after assembly. Without ddr_io_train.tcl the
# SH_DDR bitslices have no location constraints ([Place 30-687]).
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

# The DDR/C2C package pins enter at the SYNTHESIS stage (synth_cl_header.tcl:70-72),
# and pr_subdivide reloads the CL as a netlist, dropping them. Without these the
# SH_DDR bitslices have no I/O to anchor to ([Place 30-687]).
puts "PR: re-applying synthesis-stage IO constraints"
read_xdc ${HDK_SHELL_DIR}/build/constraints/cl_pins.xdc
set gen_clk_xdc ${CL_DIR}/build/constraints/generated_cl_clocks_aws.xdc
if {[file exists $gen_clk_xdc]} {
    read_xdc $gen_clk_xdc
} else {
    puts "PR: WARNING -- $gen_clk_xdc not found; pass 1 should have generated it"
}
read_xdc -ref $CL ${HDK_SHELL_DIR}/build/constraints/cl_ddr_timing_aws.xdc

puts "PR: re-applying floorplan constraints"
read_xdc ${HDK_SHELL_DIR}/build/constraints/${SHELL_MODE}_level_1_fp_cl.xdc
read_xdc ${CL_DIR}/build/constraints/${SHELL_MODE}_cl_pnr_user.xdc

puts "PR: re-applying MIG I/O training"
source ${HDK_SHELL_DIR}/build/scripts/ddr_io_train.tcl

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

opt_design
place_design
phys_opt_design
route_design -tns_cleanup

pr_check_routed "pr_subdivide implementation"

report_utilization -cells [get_cells $rp_path] \
                   -file ${reports_dir}/${CL}.${TAG}.pr_subdivide_utilization.rpt
report_timing_summary -file ${reports_dir}/${CL}.${TAG}.pr_subdivide_timing.rpt

# Overwrite pass 1's checkpoint: this is the real base, with the RM as an RP.
puts "PR: writing subdivided base checkpoint: $routed_dcp"
write_checkpoint -force $routed_dcp

pr_write_paths ${checkpoints_dir}/${CL}.pr_partition_paths.txt [list $PR_MODULE] [list $rp_path]

close_design
puts "PR: subdivide complete in [expr {[clock seconds] - $script_start_time}]s"