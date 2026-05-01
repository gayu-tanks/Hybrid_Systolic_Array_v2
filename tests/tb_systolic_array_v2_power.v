`timescale 1ns / 1ps

// ============================================================
// Power Estimation Testbench — Hybrid Systolic Array v2
// ============================================================
// Generates power_sim_v2.vcd for downstream power analysis:
//   PrimeTime PX, Cadence Joules, OpenROAD/OpenSTA, etc.
//
// Also reports in-simulation Switching Activity Factor (SAF)
// on major I/O buses for quick relative comparisons without a
// technology library.
//
// SAF definition (bus-level, approximate):
//   SAF = bus_transitions / (sim_cycles * bus_width_bits)
//   SAF = 0.5  → every bit toggles every clock cycle (max)
//   SAF = 0.0  → no switching activity
//
// Scenarios (14 total):
//   1  BF16×BF16  ZERO    — leakage / no-activity reference
//   2  BF16×BF16  RANDOM  — representative ML workload
//   3  BF16×BF16  TOGGLE  — worst-case switching
//   4  BF16×INT8  RANDOM  — mixed-precision typical
//   5  BF16×INT4  RANDOM  — mixed-precision typical
//   6  INT4×INT4  ZERO    — leakage reference, L=1 path
//   7  INT4×INT4  RANDOM  — integer low-precision typical
//   8  INT4×INT4  TOGGLE  — worst-case switching, L=1 path
//   9  INT8×INT4  ZERO    — leakage reference, L=2 path
//  10  INT8×INT4  RANDOM  — integer mixed-precision typical
//  11  INT8×INT4  TOGGLE  — worst-case switching, L=2 path
//  12  INT8×INT8  ZERO    — leakage reference, L=4 path
//  13  INT8×INT8  RANDOM  — integer full-precision typical
//  14  INT8×INT8  TOGGLE  — worst-case switching, L=4 path
//
// Compile and run:
//   iverilog -g2005 -o sim_v2_power \
//     ../rtl/mult_4x4.v ../rtl/processing_element_v2.v \
//     ../rtl/systolic_array_v2.v ../rtl/output_post_processor_v2.v \
//     ../rtl/systolic_array_v2_top.v tb_systolic_array_v2_power.v
//   vvp sim_v2_power
// ============================================================

module tb_systolic_array_v2_power;

    parameter N         = 8;
    parameter ACC_WIDTH = 24;
    parameter BUS_W     = N * 16;   // 128-bit act / weight / result bus

    localparam PAT_ZERO   = 0;
    localparam PAT_RANDOM = 1;
    localparam PAT_TOGGLE = 2;

    // ----------------------------------------------------------------
    // DUT signals
    // ----------------------------------------------------------------
    reg                  clk, rst;
    reg  [2:0]           mode;
    reg                  start;
    reg  [BUS_W-1:0]     act_row_data;
    reg  [$clog2(N)-1:0] act_row_idx;
    reg                  act_load_en;
    reg  [BUS_W-1:0]     weight_col_data;
    reg                  weight_feed_en;
    wire                 busy, done;
    wire [15:0]          cycle_count;
    wire [BUS_W-1:0]     bf16_result;
    wire [N-1:0]         result_valid;

    // ----------------------------------------------------------------
    // DUT instantiation
    // ----------------------------------------------------------------
    systolic_array_v2_top #(
        .N(N),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk             (clk),
        .rst             (rst),
        .mode            (mode),
        .act_row_data    (act_row_data),
        .act_row_idx     (act_row_idx),
        .act_load_en     (act_load_en),
        .weight_col_data (weight_col_data),
        .weight_feed_en  (weight_feed_en),
        .start           (start),
        .busy            (busy),
        .done            (done),
        .cycle_count     (cycle_count),
        .bf16_result     (bf16_result),
        .result_valid    (result_valid)
    );

    always #5 clk = ~clk;

    // ----------------------------------------------------------------
    // Switching-activity counters
    // ----------------------------------------------------------------
    integer tc_act, tc_wt, tc_res, tc_cycles;

    always @(act_row_data)    tc_act    = tc_act  + 1;
    always @(weight_col_data) tc_wt     = tc_wt   + 1;
    always @(bf16_result)     tc_res    = tc_res  + 1;
    always @(posedge clk)     tc_cycles = tc_cycles + 1;

    // ----------------------------------------------------------------
    // Stimulus memories
    // ----------------------------------------------------------------
    reg [15:0] act_mem [0:N-1][0:N-1];
    reg [15:0] wt_mem  [0:N-1][0:N-1];

    // ----------------------------------------------------------------
    // Pattern generator
    //
    // PAT_ZERO   — all zeros; no switching in datapath (leakage proxy)
    // PAT_RANDOM — uniform random 16-bit; proxy for typical NN workload
    // PAT_TOGGLE — alternating 0x5555/0xAAAA; maximises bus switching
    // ----------------------------------------------------------------
    integer pr, pc;
    task gen_pattern;
        input integer pat;
        input [2:0]   m;
        reg [15:0] rval;
        begin
            for (pr = 0; pr < N; pr = pr + 1) begin
                for (pc = 0; pc < N; pc = pc + 1) begin
                    case (pat)
                        PAT_ZERO: begin
                            act_mem[pr][pc] = 16'h0000;
                            wt_mem [pr][pc] = 16'h0000;
                        end
                        PAT_RANDOM: begin
                            // Mask to valid field widths per mode
                            case (m)
                                3'b001: begin  // BF16×BF16: full 16-bit
                                    act_mem[pr][pc] = $random & 16'hFFFF;
                                    wt_mem [pr][pc] = $random & 16'hFFFF;
                                end
                                3'b010: begin  // BF16×INT8: act=BF16, wt=INT8
                                    act_mem[pr][pc] = $random & 16'hFFFF;
                                    wt_mem [pr][pc] = $random & 16'h00FF;
                                end
                                3'b011: begin  // BF16×INT4: act=BF16, wt=INT4
                                    act_mem[pr][pc] = $random & 16'hFFFF;
                                    wt_mem [pr][pc] = $random & 16'h000F;
                                end
                                3'b100: begin  // INT4×INT4
                                    act_mem[pr][pc] = $random & 16'h000F;
                                    wt_mem [pr][pc] = $random & 16'h000F;
                                end
                                3'b101: begin  // INT8×INT4
                                    act_mem[pr][pc] = $random & 16'h00FF;
                                    wt_mem [pr][pc] = $random & 16'h000F;
                                end
                                3'b110: begin  // INT8×INT8
                                    act_mem[pr][pc] = $random & 16'h00FF;
                                    wt_mem [pr][pc] = $random & 16'h00FF;
                                end
                                default: begin
                                    act_mem[pr][pc] = $random & 16'hFFFF;
                                    wt_mem [pr][pc] = $random & 16'hFFFF;
                                end
                            endcase
                        end
                        PAT_TOGGLE: begin
                            act_mem[pr][pc] = pr[0] ? 16'hAAAA : 16'h5555;
                            wt_mem [pr][pc] = pc[0] ? 16'hAAAA : 16'h5555;
                        end
                        default: begin
                            act_mem[pr][pc] = 16'h0000;
                            wt_mem [pr][pc] = 16'h0000;
                        end
                    endcase
                end
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Reset counters between scenarios
    // ----------------------------------------------------------------
    task reset_counters;
        begin
            tc_act    = 0;
            tc_wt     = 0;
            tc_res    = 0;
            tc_cycles = 0;
        end
    endtask

    // ----------------------------------------------------------------
    // Reset DUT
    // ----------------------------------------------------------------
    task do_reset;
        begin
            rst             = 1;
            start           = 0;
            act_load_en     = 0;
            weight_feed_en  = 0;
            act_row_data    = {BUS_W{1'b0}};
            weight_col_data = {BUS_W{1'b0}};
            act_row_idx     = 0;
            repeat(4) @(posedge clk);
            #1; rst = 0;
        end
    endtask

    // ----------------------------------------------------------------
    // Load N activation rows (one per clock, matching functional TB)
    // ----------------------------------------------------------------
    integer la_r, la_c;
    task load_activations;
        begin
            for (la_r = 0; la_r < N; la_r = la_r + 1) begin
                @(posedge clk); #1;
                act_row_idx = la_r[$clog2(N)-1:0];
                act_load_en = 1;
                for (la_c = 0; la_c < N; la_c = la_c + 1)
                    act_row_data[la_c*16 +: 16] = act_mem[la_r][la_c];
                @(posedge clk); #1;
                act_load_en = 0;
            end
            act_row_data = {BUS_W{1'b0}};
        end
    endtask

    // ----------------------------------------------------------------
    // Pulse start then feed N weight columns (one per clock)
    // ----------------------------------------------------------------
    integer fd_k, fd_r;
    task trigger_and_load_weights;
        begin
            start = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;

            for (fd_k = 0; fd_k < N; fd_k = fd_k + 1) begin
                for (fd_r = 0; fd_r < N; fd_r = fd_r + 1)
                    weight_col_data[fd_r*16 +: 16] = wt_mem[fd_r][fd_k];
                weight_feed_en = 1'b1;
                @(posedge clk); #1;
                weight_feed_en = 1'b0;
            end
            weight_col_data = {BUS_W{1'b0}};
        end
    endtask

    // ----------------------------------------------------------------
    // Wait for done signal (with timeout)
    // ----------------------------------------------------------------
    integer wait_cnt;
    task wait_done;
        begin
            wait_cnt = 0;
            while (!done && wait_cnt < 5000) begin
                @(posedge clk); #1;
                wait_cnt = wait_cnt + 1;
            end
            if (wait_cnt >= 5000)
                $display("  [WARN] wait_done timeout");
        end
    endtask

    // ----------------------------------------------------------------
    // Report switching activity for the last scenario
    // ----------------------------------------------------------------
    real saf_act, saf_wt, saf_res;
    task report_activity;
        input [127:0] label;
        begin
            saf_act = (tc_act  * 1.0) / (1.0 * tc_cycles * BUS_W);
            saf_wt  = (tc_wt   * 1.0) / (1.0 * tc_cycles * BUS_W);
            saf_res = (tc_res  * 1.0) / (1.0 * tc_cycles * BUS_W);
            $display("  cycle_count     : %0d", cycle_count);
            $display("  sim_cycles      : %0d", tc_cycles);
            $display("  %-20s %5d bus-events  SAF=%.4f", "act_row_data:",    tc_act, saf_act);
            $display("  %-20s %5d bus-events  SAF=%.4f", "weight_col_data:", tc_wt,  saf_wt);
            $display("  %-20s %5d bus-events  SAF=%.4f", "bf16_result:",     tc_res, saf_res);
        end
    endtask

    // ----------------------------------------------------------------
    // Run one scenario end-to-end
    // ----------------------------------------------------------------
    task run_scenario;
        input [2:0]   m;
        input integer pat;
        begin
            gen_pattern(pat, m);
            do_reset;
            reset_counters;
            mode = m;
            load_activations;
            trigger_and_load_weights;
            wait_done;
        end
    endtask

    // ================================================================
    // Main sequence
    // ================================================================
    initial begin
        clk    = 0;
        tc_act = 0; tc_wt = 0; tc_res = 0; tc_cycles = 0;

        $dumpfile("power_sim_v2.vcd");
        $dumpvars(0, dut);

        $display("");
        $display("============================================================");
        $display("  Power Estimation Testbench — Hybrid Systolic Array v2");
        $display("  N=%0d  ACC_WIDTH=%0d  Bus=%0d bits", N, ACC_WIDTH, BUS_W);
        $display("  Clock period: 10 ns  (100 MHz reference)");
        $display("============================================================");
        $display("  SAF = bus_events / (sim_cycles x bus_width)");
        $display("  bus_events: increments once per ANY-bit change in the bus");
        $display("  For per-bit SAF: vcd2saif -input power_sim_v2.vcd ...");
        $display("============================================================");

        // --- Scenario 1: BF16×BF16 ZERO (leakage reference) ---
        $display("\n--- Scenario 1: BF16xBF16 | ZERO (leakage reference) ---");
        run_scenario(3'b001, PAT_ZERO);
        report_activity("BF16xBF16 ZERO");

        // --- Scenario 2: BF16×BF16 RANDOM (typical workload) ---
        $display("\n--- Scenario 2: BF16xBF16 | RANDOM (typical workload) ---");
        run_scenario(3'b001, PAT_RANDOM);
        report_activity("BF16xBF16 RANDOM");

        // --- Scenario 3: BF16×BF16 TOGGLE (worst-case switching) ---
        $display("\n--- Scenario 3: BF16xBF16 | TOGGLE (worst-case switching) ---");
        run_scenario(3'b001, PAT_TOGGLE);
        report_activity("BF16xBF16 TOGGLE");

        // --- Scenario 4: BF16×INT8 RANDOM ---
        $display("\n--- Scenario 4: BF16xINT8 | RANDOM ---");
        run_scenario(3'b010, PAT_RANDOM);
        report_activity("BF16xINT8 RANDOM");

        // --- Scenario 5: BF16×INT4 RANDOM ---
        $display("\n--- Scenario 5: BF16xINT4 | RANDOM ---");
        run_scenario(3'b011, PAT_RANDOM);
        report_activity("BF16xINT4 RANDOM");

        // --- Scenario 6: INT4×INT4 ZERO (leakage reference, L=1) ---
        $display("\n--- Scenario 6: INT4xINT4 | ZERO (leakage reference, L=1) ---");
        run_scenario(3'b100, PAT_ZERO);
        report_activity("INT4xINT4 ZERO");

        // --- Scenario 7: INT4×INT4 RANDOM ---
        $display("\n--- Scenario 7: INT4xINT4 | RANDOM ---");
        run_scenario(3'b100, PAT_RANDOM);
        report_activity("INT4xINT4 RANDOM");

        // --- Scenario 8: INT4×INT4 TOGGLE (worst-case switching, L=1) ---
        $display("\n--- Scenario 8: INT4xINT4 | TOGGLE (worst-case switching, L=1) ---");
        run_scenario(3'b100, PAT_TOGGLE);
        report_activity("INT4xINT4 TOGGLE");

        // --- Scenario 9: INT8×INT4 ZERO (leakage reference, L=2) ---
        $display("\n--- Scenario 9: INT8xINT4 | ZERO (leakage reference, L=2) ---");
        run_scenario(3'b101, PAT_ZERO);
        report_activity("INT8xINT4 ZERO");

        // --- Scenario 10: INT8×INT4 RANDOM ---
        $display("\n--- Scenario 10: INT8xINT4 | RANDOM ---");
        run_scenario(3'b101, PAT_RANDOM);
        report_activity("INT8xINT4 RANDOM");

        // --- Scenario 11: INT8×INT4 TOGGLE (worst-case switching, L=2) ---
        $display("\n--- Scenario 11: INT8xINT4 | TOGGLE (worst-case switching, L=2) ---");
        run_scenario(3'b101, PAT_TOGGLE);
        report_activity("INT8xINT4 TOGGLE");

        // --- Scenario 12: INT8×INT8 ZERO (leakage reference, L=4) ---
        $display("\n--- Scenario 12: INT8xINT8 | ZERO (leakage reference, L=4) ---");
        run_scenario(3'b110, PAT_ZERO);
        report_activity("INT8xINT8 ZERO");

        // --- Scenario 13: INT8×INT8 RANDOM ---
        $display("\n--- Scenario 13: INT8xINT8 | RANDOM ---");
        run_scenario(3'b110, PAT_RANDOM);
        report_activity("INT8xINT8 RANDOM");

        // --- Scenario 14: INT8×INT8 TOGGLE (worst-case switching, L=4) ---
        $display("\n--- Scenario 14: INT8xINT8 | TOGGLE (worst-case switching, L=4) ---");
        run_scenario(3'b110, PAT_TOGGLE);
        report_activity("INT8xINT8 TOGGLE");

        $display("");
        $display("============================================================");
        $display("  VCD written → power_sim_v2.vcd");
        $display("  Downstream flow options:");
        $display("    Synopsys PrimeTime PX:");
        $display("      read_vcd -strip_path tb_systolic_array_v2_power/dut \\");
        $display("               power_sim_v2.vcd");
        $display("    vcd2saif (open-source):");
        $display("      vcd2saif -input power_sim_v2.vcd -output power_sim_v2.saif");
        $display("============================================================");
        $display("");

        $finish;
    end

endmodule
