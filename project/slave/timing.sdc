create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
rename_clock -name {mic_mclk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_mic_pll/pll_inst.clkc[2]}]
set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {mic_mclk}]
