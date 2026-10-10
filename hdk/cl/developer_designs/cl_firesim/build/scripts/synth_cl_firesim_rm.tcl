# =============================================================================
# Reconfigurable module out-of-context synthesis -- AWS F2.
# U250 gets this free from project-mode create_reconfig_module (main_pr.tcl:274).
#
# Deliberately does not source synth_cl_header.tcl: that pulls in AWS shell
# collateral an RM has no use for. Only part + RTL + a clock constraint needed.
#
# Invocation (named tclargs; build-bitstream.sh owns this vivado call):
#
#   vivado -mode batch -source synth_cl_firesim_rm.tcl -tclargs \
#     --cl_dir <dir> --build_tag <tag> --pr_module_name <mod> --frequency <mhz> \
#     [--device_type <part>]
# =============================================================================

set scripts_dir [file dirname [file normalize [info script]]]
source ${scripts_dir}/pr_utils.tcl

set opts [pr_parse_args $argv \
              {cl_dir build_tag pr_module_name frequency} \
              {device_type}]

set CL_DIR      [dict get $opts cl_dir]
set TAG         [dict get $opts build_tag]
set PR_MODULE   [dict get $opts pr_module_name]
# The RM runs on the FireSim host clock out of the firesim_clocking MMCM --
# NOT clk_main_a0's fixed 250 MHz.
set PR_FREQ_MHZ [dict get $opts frequency]
set DEVICE_TYPE [pr_opt $opts device_type "xcvu47p-fsvh2892-2-e"]

if {![string is double -strict $PR_FREQ_MHZ] || $PR_FREQ_MHZ <= 0} {
    error "PR: --frequency must be a positive number, got '$PR_FREQ_MHZ'"
}

set clock_period_ns [expr {1000.0 / double($PR_FREQ_MHZ)}]
set checkpoints_dir ${CL_DIR}/build/checkpoints
set reports_dir     ${CL_DIR}/build/reports
set split_dir       ${CL_DIR}/design/split-verilog

puts "PR: RM out-of-context synthesis"
puts "PR:   module      : $PR_MODULE"
puts "PR:   part        : $DEVICE_TYPE"
puts "PR:   clock period: ${clock_period_ns} ns (${PR_FREQ_MHZ} MHz)"

create_project -in_memory -part $DEVICE_TYPE -force
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]

# Read every split-verilog module and let -top select the subtree, so we never
# have to work out which helper modules the RM instantiates.
if {![file isdirectory $split_dir]} {
    error "PR: split-verilog directory not found: $split_dir\
           (run 'make replace-rtl' to populate it)"
}
set split_files [glob -nocomplain -directory $split_dir *.sv]
if {[llength $split_files] == 0} {
    error "PR: no .sv files in $split_dir"
}
if {![file exists ${split_dir}/${PR_MODULE}.sv]} {
    error "PR: ${PR_MODULE}.sv not found in $split_dir.\
           Golden Gate may have inlined the module -- check the split-verilog\
           output for the real generated module name."
}
puts "PR: reading [llength $split_files] split-verilog module file(s)"
read_verilog -sv $split_files

# Out-of-context synthesis. Timing must come from an xdc read with
# -mode out_of_context; no ports exist before synth_design for an inline
# create_clock to attach to.
set ooc_xdc ${CL_DIR}/build/pr_stubs/${PR_MODULE}_ooc.xdc
file mkdir [file dirname $ooc_xdc]
set ooc_fh [open $ooc_xdc w]
puts $ooc_fh "create_clock -name user_clock -period $clock_period_ns \[get_ports clock\]"
close $ooc_fh
read_xdc -mode out_of_context $ooc_xdc

synth_design -mode out_of_context \
             -top $PR_MODULE \
             -part $DEVICE_TYPE \
             -keep_equivalent_registers

pr_fix_constant_output_drivers

set out_dcp ${checkpoints_dir}/${PR_MODULE}.${TAG}.rm_post_synth.dcp
puts "PR: writing RM checkpoint: $out_dcp"
write_checkpoint -force $out_dcp

report_utilization -file ${reports_dir}/${PR_MODULE}.${TAG}.rm_post_synth_utilization.rpt

puts "PR: RM synthesis complete"
puts "PR: pass this to main_pr_rm.tcl as FIRESIM_PR_RM_DCP"
