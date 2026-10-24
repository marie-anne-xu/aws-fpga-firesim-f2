# Child: swap the prefetcher into the routed base, per RapidWright's "Reuse Timing-closed Logic As A Shell".
#   vivado -mode batch -source main_pr_rm.tcl -tclargs --cl_dir <dir> --build_tag <tag> --base_dcp <dcp> \
#     --rm_dcp <dcp> --pr_module_name <mod> [--cl_name <name>]

set script_start_time [clock seconds]
set scripts_dir [file dirname [file normalize [info script]]]
source ${scripts_dir}/pr_utils.tcl
proc pr_t {step script} {
    set t0 [clock milliseconds]
    uplevel 1 $script
    puts "PR_TIME $step [expr {([clock milliseconds] - $t0) / 1000.0}]"
}

set opts [pr_parse_args $argv {cl_dir build_tag base_dcp rm_dcp pr_module_name} {cl_name}]
set CL_DIR   [dict get $opts cl_dir]
set TAG      [dict get $opts build_tag]
set base_dcp [dict get $opts base_dcp]
set rm_dcp   [dict get $opts rm_dcp]
set CL       [pr_opt $opts cl_name cl_firesim]
set ckdir    ${CL_DIR}/build/checkpoints
set work     ${ckdir}/rw_shell
file mkdir $work
set out_dcp  ${ckdir}/${CL}.${TAG}.post_route.dcp

pr_t open_base {open_checkpoint $base_dcp}
set rm [pr_discover_paths [dict get $opts pr_module_name]]
if {[llength $rm] != 1} { error "PR: expected one RM instance, found: $rm" }

# Tutorial step 4 (MakeBlackBox). The AWS shell and WRAPPER/CL are encrypted, so RapidWright gets the
# RM's top-level CL child; its cell checkpoint keeps placement, which is what the shell's PROHIBITs use.
set top [lindex [split [string range $rm [string length WRAPPER/CL/] end] /] 0]
set part WRAPPER/CL/$top
set rel [string range $rm [expr {[string length $part] + 1}] end]
pr_t write_part {write_checkpoint -force -cell $part $work/part.dcp}
pr_t write_edif {write_edif -force -cell $part $work/part_edf}
file copy -force [lindex [glob $work/part_edf/*/*.edn] 0] $work/part.edf
pr_t install_rw {exec bash ${scripts_dir}/rw/install_rw.sh >@ stdout 2>@ stderr}
# Docs' bin/rapidwright with Vivado's JDK; heap via _JAVA_OPTIONS as the docs show.
set jdk [lindex [lsort [glob $::env(XILINX_VIVADO)/tps/lnx64/jre21*/bin]] end]
set rw_home [pr_env RW_HOME /home/ubuntu/rw]
pr_t make_black_box {exec env PATH=$jdk:$::env(PATH) _JAVA_OPTIONS=-Xmx32736m $rw_home/bin/rapidwright \
    MakeBlackBox $work/part.dcp $work/shell.dcp $rel >@ stdout 2>@ stderr}
pr_t shell_xdc {exec sh -c "unzip -p $work/shell.dcp '*_late.xdc' | grep PROHIBIT > $work/shell_prohibit.xdc"}

# Steps 5-6 in the full design: Vivado black-boxes the RM (HD.PARTITION allows it in a routed design),
# applies the shell's PROHIBITs, locks the rest and implements only the new RM.
set_property HD.PARTITION 1 [get_cells $rm]
pr_t black_box {update_design -cell $rm -black_box}
pr_t lock {lock_design -level routing}
pr_t prohibit {read_xdc $work/shell_prohibit.xdc}
pr_t read_rm {read_checkpoint -cell $rm $rm_dcp}
set_property SEVERITY {Warning} [get_drc_checks REQP-1753]
pr_t place {place_design}
pr_t route {route_design}

pr_check_routed "RM swap"
pr_check_timing_met "RM swap"
pr_check_ddr_bram
pr_t write {write_checkpoint -force $out_dcp}
puts "PR: RM swap complete in [expr {[clock seconds] - $script_start_time}]s -> $out_dcp"
