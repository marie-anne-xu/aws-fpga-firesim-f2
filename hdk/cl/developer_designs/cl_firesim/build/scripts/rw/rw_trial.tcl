# CHIA trial preamble for rw_* trials (argv[0] = trial dir holding copies of pr_utils.tcl + rw/*).
set ::TD [lindex $argv 0]
set ::RWD $::TD
source $::TD/chia_marks.tcl
source $::TD/pr_utils.tcl
source $::TD/rw_common.tcl
set ::S3I s3://firesim-593814964324-us-west-2/chia-f2-dfx/inputs/rapidwright
set ::W /home/ubuntu/dfx-nested-scratch/rw_work; file mkdir $::W
set ::SHELL /home/ubuntu/cy-smartagent/sims/firesim/platforms/f2/aws-fpga-firesim-f2/hdk/common/shell_stable/build/checkpoints/from_aws/cl_bb_routed.small_shell.dcp
set ::env(HDK_SHELL_DIR) /home/ubuntu/cy-smartagent/sims/firesim/platforms/f2/aws-fpga-firesim-f2/hdk/common/shell_stable
proc rw_fetch {f} { return [chia_fetch $::S3I/$f $::W/$f] }
set_param general.maxThreads 8
