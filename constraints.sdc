# ===========================================================
# Synopsys Design Constraints — Hybrid Systolic Array v2
# Module : systolic_array_v2_top
# ===========================================================
# Clock    : 2 ns period (500 MHz)
# In/Out delay : 20% of clock period = 0.4 ns
#
# Key differences from hybrid_systolic_array v1:
#   - Single output channel: bf16_result / result_valid (not _0 / _1)
#   - mode is 3-bit (was 2-bit)
#   - ACC_WIDTH reduced to 24 (was 44)
#   - mode multicycle relaxed to 3 cycles: 6 modes, wider fanout
#     through 64 PEs (8×8 array)
# ===========================================================

# -----------------------------------------------------------
# Clock definition
# -----------------------------------------------------------
set CLK_PERIOD  2.0
set CLK_TRAN    0.05   ;# 50 ps rise/fall (2.5% of period)
set CLK_UNCERT  0.05   ;# 50 ps jitter/skew margin

create_clock -name clk \
             -period $CLK_PERIOD \
             -waveform [list 0 [expr {$CLK_PERIOD / 2.0}]] \
             [get_ports clk]

set_clock_transition  $CLK_TRAN    [get_clocks clk]
set_clock_uncertainty $CLK_UNCERT  [get_clocks clk]

# Ideal clock network (replace with set_propagated_clock after CTS)
set_ideal_network [get_ports clk]

# -----------------------------------------------------------
# Derived timing budgets
# -----------------------------------------------------------
set IO_DELAY [expr {$CLK_PERIOD * 0.20}]   ;# 0.4 ns

# -----------------------------------------------------------
# Input delays
# All inputs assumed to arrive from registers in the same
# clock domain (single-domain, source-synchronous).
# -----------------------------------------------------------

# Control signals
set_input_delay $IO_DELAY -clock clk [get_ports rst]
set_input_delay $IO_DELAY -clock clk [get_ports mode]
set_input_delay $IO_DELAY -clock clk [get_ports start]
set_input_delay $IO_DELAY -clock clk [get_ports act_load_en]
set_input_delay $IO_DELAY -clock clk [get_ports weight_feed_en]

# Address
set_input_delay $IO_DELAY -clock clk [get_ports act_row_idx]

# Data buses (128-bit each)
set_input_delay $IO_DELAY -clock clk [get_ports act_row_data]
set_input_delay $IO_DELAY -clock clk [get_ports weight_col_data]

# -----------------------------------------------------------
# Output delays
# -----------------------------------------------------------

# Status
set_output_delay $IO_DELAY -clock clk [get_ports busy]
set_output_delay $IO_DELAY -clock clk [get_ports done]
set_output_delay $IO_DELAY -clock clk [get_ports cycle_count]

# Result (single channel, one BF16 per row)
set_output_delay $IO_DELAY -clock clk [get_ports bf16_result]
set_output_delay $IO_DELAY -clock clk [get_ports result_valid]

# -----------------------------------------------------------
# Drive strength and load
# Replace with actual cell models after technology mapping.
# -----------------------------------------------------------
set_driving_cell -no_design_rule \
    [get_ports {rst mode start act_load_en weight_feed_en act_row_idx}]
set_driving_cell -no_design_rule \
    [get_ports {act_row_data weight_col_data}]

set_load 0.01 [get_ports bf16_result]
set_load 0.01 [get_ports {result_valid busy done cycle_count}]

# -----------------------------------------------------------
# Timing exceptions
# -----------------------------------------------------------

# rst: synchronous reset, allow full cycle for reset-tree propagation
set_multicycle_path 1 -setup -from [get_ports rst] -to [get_clocks clk]

# mode: quasi-static (set once before start, held for entire run).
# 3-bit mode fans out to all 64 PEs (operand-selector logic in every PE);
# relax to 3 cycles to ease routing on that wide fanout tree.
set_multicycle_path 3 -setup -from [get_ports mode] -to [get_clocks clk]
set_multicycle_path 2 -hold  -from [get_ports mode] -to [get_clocks clk]

# cycle_count: sampled only when done pulses, not a critical path
set_multicycle_path 2 -setup -to [get_ports cycle_count]
set_multicycle_path 1 -hold  -to [get_ports cycle_count]

# result_valid: 1-cycle pulse output from output_post_processor_v2
# (combinational from weight_valid_v — give it one extra cycle margin)
set_multicycle_path 2 -setup -to [get_ports result_valid]
set_multicycle_path 1 -hold  -to [get_ports result_valid]

# -----------------------------------------------------------
# Area / power intent
# -----------------------------------------------------------
set_max_fanout   16 [current_design]
set_max_transition [expr {$CLK_TRAN * 4.0}] [current_design]
