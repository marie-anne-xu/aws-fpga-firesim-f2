# Nested-DFX constraint parity (read by main_pr_subdivide.tcl after pr_subdivide).
# These shell constraints come from the AWS shell's top_late.xdc. They are in
# the routed outer-CL parent but are dropped from the subdivided design.
# Values are verbatim from the parent's constraint archive
# (dfx-nested-scratch/parent_spi_timing_restore.candidate.xdc). Re-applying is
# idempotent: same values, and no -add_delay.
set_clock_groups -asynchronous -group [get_clocks clk_core] -group [get_clocks clk_spi]
set_input_delay  -clock [get_clocks clk_spi] -max 0.000 [get_ports SPI_CS2_N_SLAVE_R]
set_input_delay  -clock [get_clocks clk_spi] -min 5.000 [get_ports SPI_CS2_N_SLAVE_R]
set_input_delay  -clock [get_clocks clk_spi] -max 0.000 [get_ports SPI_MOSI_SLAVE_R]
set_input_delay  -clock [get_clocks clk_spi] -min 5.000 [get_ports SPI_MOSI_SLAVE_R]
set_output_delay -clock [get_clocks clk_spi] -max 0.000 [get_ports SPI_MISO_SLAVE_R]
set_output_delay -clock [get_clocks clk_spi] -min 5.000 [get_ports SPI_MISO_SLAVE_R]
