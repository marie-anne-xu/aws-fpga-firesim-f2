# =============================================================================
# Amazon FPGA Hardware Development Kit
#
# Copyright 2024 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Amazon Software License (the "License"). You may not use
# this file except in compliance with the License. A copy of the License is
# located at
#
#    http://aws.amazon.com/asl/
#
# or in the "license" file accompanying this file. This file is distributed on
# an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. See the License for the specific language governing permissions and
# limitations under the License.
# =============================================================================

# Level 1 CL_DRAM_HBM_DMA floorplan for Small Shell


###############################################################################
# Child Pblock in SLR2
###############################################################################
########################################
# Pblock
########################################
create_pblock pblock_CL_SLR2

# Complete CRs in SLR2
resize_pblock pblock_CL_SLR2 -add {CLOCKREGION_X0Y8:CLOCKREGION_X7Y11}

set_property parent pblock_CL [get_pblocks pblock_CL_SLR2]

########################################
# Module Mapping
########################################
add_cells_to_pblock pblock_CL_SLR2 [get_cells [list WRAPPER/CL/SH_DDR \
                                                    WRAPPER/CL/clock_convert_dramslim_0 \
                                                    WRAPPER/CL/dwidth_adapt_64bits_512bits_0 ]]


###############################################################################
# Child Pblock in SLR1
###############################################################################
########################################
# Pblock
########################################
create_pblock pblock_CL_SLR1

# Complete CRs in SLR1
resize_pblock pblock_CL_SLR1 -add {CLOCKREGION_X0Y4:CLOCKREGION_X3Y7}
resize_pblock pblock_CL_SLR1 -add {CLOCKREGION_X5Y4:CLOCKREGION_X5Y7}
resize_pblock pblock_CL_SLR1 -add {CLOCKREGION_X4Y6:CLOCKREGION_X4Y7}
resize_pblock pblock_CL_SLR1 -add {CLOCKREGION_X4Y4:CLOCKREGION_X4Y4}

# Partial CRs
resize_pblock pblock_CL_SLR1 -add {SLICE_X122Y300:SLICE_X145Y359 \
                                   DSP48E2_X16Y114:DSP48E2_X19Y137 \
                                   RAMB18_X9Y120:RAMB18_X9Y143 \
                                   RAMB36_X9Y60:RAMB36_X9Y71 \
                                   URAM288_X2Y80:URAM288_X2Y95}
resize_pblock pblock_CL_SLR1 -add {RAMB18_X8Y120:RAMB18_X8Y143 \
                                   RAMB36_X8Y60:RAMB36_X8Y71}

set_property SNAPPING_MODE ON [get_pblocks pblock_CL_SLR1]

set_property parent pblock_CL [get_pblocks pblock_CL_SLR1]

########################################
# Module Mapping
########################################
add_cells_to_pblock pblock_CL_SLR1 [get_cells [list WRAPPER/CL/firesim_clocking \
                                                    WRAPPER/CL/ocl_clock_convert \
                                                    WRAPPER/CL/wide_pcis_clock_convert ]]


###############################################################################
# Grandchild Pblock
# NOTE:
#   This pblock is to help move the PCIS interconnect away from the Shell to
#   avoid routing congestion
###############################################################################
########################################
# Pblock
########################################
# FIX: Commenting out pblock_CL_SLR1_XBAR because the module WRAPPER/CL/CL_DMA_PCIS_SLV/AXI4_CROSSBAR
# doesn't exist in the FireSim design (FireSim has a different DMA architecture)
# create_pblock pblock_CL_SLR1_XBAR
# resize_pblock pblock_CL_SLR1_XBAR -add {CLOCKREGION_X0Y4:CLOCKREGION_X3Y7}
# set_property parent pblock_CL_SLR1 [get_pblocks pblock_CL_SLR1_XBAR]
# add_cells_to_pblock pblock_CL_SLR1_XBAR [get_cells [list WRAPPER/CL/CL_DMA_PCIS_SLV/AXI4_CROSSBAR ]]


###############################################################################
# Child Pblock in SLR0
###############################################################################
########################################
# Pblock
########################################
create_pblock pblock_CL_SLR0

# Complete CRs
resize_pblock pblock_CL_SLR0 -add {CLOCKREGION_X0Y0:CLOCKREGION_X3Y3}
resize_pblock pblock_CL_SLR0 -add {CLOCKREGION_X4Y0:CLOCKREGION_X7Y0}
resize_pblock pblock_CL_SLR0 -add {CLOCKREGION_X4Y3:CLOCKREGION_X4Y3}
resize_pblock pblock_CL_SLR0 -add {CLOCKREGION_X6Y1:CLOCKREGION_X6Y1}
resize_pblock pblock_CL_SLR0 -add {CLOCKREGION_X5Y1:CLOCKREGION_X5Y3}

# Partial CRs
resize_pblock pblock_CL_SLR0 -add {SLICE_X120Y120:SLICE_X145Y179 \
                                   DSP48E2_X16Y42:DSP48E2_X19Y65 \
                                   RAMB18_X8Y48:RAMB18_X9Y71 \
                                   RAMB36_X8Y24:RAMB36_X9Y35 \
                                   URAM288_X2Y32:URAM288_X2Y47}

resize_pblock pblock_CL_SLR0 -add {SLICE_X118Y60:SLICE_X145Y119 \
                                   DSP48E2_X16Y18:DSP48E2_X19Y41 \
                                   RAMB18_X8Y24:RAMB18_X9Y47 \
                                   RAMB36_X8Y12:RAMB36_X9Y23 \
                                   URAM288_X2Y16:URAM288_X2Y31}

resize_pblock pblock_CL_SLR0 -add {SLICE_X206Y60:SLICE_X219Y119 \
                                   DSP48E2_X30Y18:DSP48E2_X30Y41 \
                                   RAMB18_X12Y24:RAMB18_X12Y47 \
                                   RAMB36_X12Y12:RAMB36_X12Y23}

resize_pblock pblock_CL_SLR0 -add {SLICE_X221Y60:SLICE_X232Y119 \
                                   DSP48E2_X31Y18:DSP48E2_X31Y41 \
                                   RAMB18_X13Y24:RAMB18_X13Y47 \
                                   RAMB36_X13Y12:RAMB36_X13Y23 \
                                   BUFG_GT_X1Y24:BUFG_GT_X1Y47 \
                                   BUFG_GT_SYNC_X1Y15:BUFG_GT_SYNC_X1Y29 \
                                   GTYE4_COMMON_X1Y1:GTYE4_COMMON_X1Y1 \
                                   GTYE4_CHANNEL_X1Y4:GTYE4_CHANNEL_X1Y7}

set_property parent pblock_CL [get_pblocks pblock_CL_SLR0]

########################################
# Module Mapping
########################################
set_false_path -from [get_clocks clk_main_a0] \
               -to   [get_cells {WRAPPER/CL/pre_sync_rst_n_firesim_reg* \
                                 WRAPPER/CL/rst_firesim_n_sync_reg* }]

set firesim_host_clock [get_clocks -of_objects \
    [get_pins WRAPPER/CL/firesim_clocking/inst/mmcme4_adv_inst/CLKOUT0]]

set cl_clk_main_a0 [get_clocks -of_objects \
    [get_pins -hierarchical -regexp {.*WRAPPER/CL/clk_main_a0}]]

set ddr_a_ui_clk [get_clocks -of_objects \
    [get_pins WRAPPER/CL/SH_DDR/genblk1.IS_DDR_PRESENT.DDR4_0/inst/u_ddr4_infrastructure/gen_mmcme4.u_mmcme_adv_inst/CLKOUT0]]

set_clock_groups -asynchronous \
    -group [get_clocks clk_main_a0] \
    -group $cl_clk_main_a0 \
    -group $firesim_host_clock \
    -group $ddr_a_ui_clk

set_false_path \
    -from [get_pins -of_objects \
              [get_cells -hierarchical -filter \
                  {NAME =~ WRAPPER/CL/SH_DDR/*ram_reg*}] \
              -filter {REF_PIN_NAME == CLK}] \
    -to   [get_cells -hierarchical -filter \
              {NAME =~ WRAPPER/CL/SH_DDR/*rd_do_reg[*]}]

