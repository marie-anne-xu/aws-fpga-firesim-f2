# AWS shell top_late.xdc SPI timing, dropped by pr_subdivide; re-applied by main_pr_subdivide.tcl.
set_clock_groups -asynchronous -group [get_clocks clk_core] -group [get_clocks clk_spi]
set_input_delay  -clock [get_clocks clk_spi] -max 0.000 [get_ports SPI_CS2_N_SLAVE_R]
set_input_delay  -clock [get_clocks clk_spi] -min 5.000 [get_ports SPI_CS2_N_SLAVE_R]
set_input_delay  -clock [get_clocks clk_spi] -max 0.000 [get_ports SPI_MOSI_SLAVE_R]
set_input_delay  -clock [get_clocks clk_spi] -min 5.000 [get_ports SPI_MOSI_SLAVE_R]
set_output_delay -clock [get_clocks clk_spi] -max 0.000 [get_ports SPI_MISO_SLAVE_R]
set_output_delay -clock [get_clocks clk_spi] -min 5.000 [get_ports SPI_MISO_SLAVE_R]
