derive_pll_clocks
derive_clock_uncertainty

set_multicycle_path -to {*Hq2x*} -setup 4
set_multicycle_path -to {*Hq2x*} -hold 3

set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[1].*|divclk}] -to {ascal|*} -setup 4
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[1].*|divclk}] -to {ascal|*} -hold 3

# The SDRAM read data is registered on clk_ram and consumed on clk_sys by the
# MBUS state machine, which cannot look at it until at least the next clk_sys
# edge.  Inherited from Genesis_MiSTer with the instance names updated for the
# C-2 hierarchy: the module there is `system`, here it is `c2`.
set_multicycle_path -from {emu|sdram|dout*} -to {emu|c2|data*} -setup 2
set_multicycle_path -from {emu|sdram|dout*} -to {emu|c2|data*} -hold 1
