`timescale 1ns / 1ps

// Testbench for systolic_array_v2_top
// Tests all 6 modes, loads hex vectors, checks BF16 results.

module tb_systolic_array_v2;

    parameter N         = 8;
    parameter ACC_WIDTH = 24;

    // ----------------------------------------------------------------
    // DUT ports
    // ----------------------------------------------------------------
    reg        clk, rst;
    reg [2:0]  mode;
    reg [N*16-1:0]      act_row_data;
    reg [$clog2(N)-1:0] act_row_idx;
    reg                 act_load_en;
    reg [N*16-1:0]      weight_col_data;
    reg                 weight_feed_en;
    reg                 start;

    wire        busy, done;
    wire [15:0] cycle_count;
    wire [N*16-1:0] bf16_result;
    wire [N-1:0]    result_valid;

    systolic_array_v2_top #(.N(N), .ACC_WIDTH(ACC_WIDTH)) dut (
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

    // ----------------------------------------------------------------
    // Clock
    // ----------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ----------------------------------------------------------------
    // Memory arrays for hex vectors (indexed [N*N-1:0])
    // ----------------------------------------------------------------
    reg [15:0] act_mem  [0:N*N-1];
    reg [15:0] wt_mem   [0:N*N-1];
    reg [15:0] gold_mem [0:N*N-1];

    // Captured results: captured[i][k] = result for row i, step k
    reg [15:0] captured [0:N-1][0:N-1];
    reg [N-1:0] step_done [0:N-1];   // which steps were captured per row
    integer cap_cnt [0:N-1];          // how many results captured per row

    // ----------------------------------------------------------------
    // BF16 decode helpers (combinational, via tasks)
    // ----------------------------------------------------------------
    function real bf16_to_real;
        input [15:0] b;
        real sign_f, exp_f, mant_f;
        integer e;
        begin
            sign_f = b[15] ? -1.0 : 1.0;
            e      = b[14:7];
            mant_f = 1.0 + b[6:0] / 128.0;
            if (e == 0 && b[6:0] == 0)
                bf16_to_real = 0.0;
            else if (e == 255)
                bf16_to_real = sign_f * 1e38;  // inf/NaN → large
            else
                bf16_to_real = sign_f * mant_f * (2.0 ** (e - 127));
        end
    endfunction

    function real fabs_f;
        input real v;
        begin fabs_f = (v < 0.0) ? -v : v; end
    endfunction

    function real fmax_f;
        input real a, b;
        begin fmax_f = (a > b) ? a : b; end
    endfunction

    // ----------------------------------------------------------------
    // Load activations (N rows)
    // ----------------------------------------------------------------
    task load_activations;
        integer i, j;
        begin
            for (i = 0; i < N; i = i+1) begin
                @(posedge clk); #1;
                act_row_idx  = i[$clog2(N)-1:0];
                act_load_en  = 1'b1;
                for (j = 0; j < N; j = j+1)
                    act_row_data[j*16 +: 16] = act_mem[i*N + j];
                @(posedge clk); #1;
                act_load_en = 1'b0;
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Trigger compute: pulse start, then feed N weight columns
    // ----------------------------------------------------------------
    task trigger_and_load_weights;
        integer k, j;
        begin
            start = 1'b1;
            @(posedge clk); #1;
            start = 1'b0;

            // Feed N weight columns (steps 0..N-1), one per clock cycle.
            // Drive data + weight_feed_en before the posedge so the FSM
            // samples them on the same clock the data is valid.
            for (k = 0; k < N; k = k+1) begin
                for (j = 0; j < N; j = j+1)
                    weight_col_data[j*16 +: 16] = wt_mem[k*N + j];
                weight_feed_en = 1'b1;
                @(posedge clk); #1;
                weight_feed_en = 1'b0;
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Capture results
    // Each row fires result_valid N times (once per step k=0..N-1).
    // We capture in order.
    // ----------------------------------------------------------------
    task capture_results;
        integer total_expected, i;
        integer timeout_cnt;
        reg all_done;
        begin
            // Reset capture state
            for (i = 0; i < N; i = i+1)
                cap_cnt[i] = 0;

            total_expected = N * N;
            timeout_cnt    = 0;
            all_done       = 1'b0;

            while (!all_done && timeout_cnt < 5000) begin
                @(posedge clk); #1;
                timeout_cnt = timeout_cnt + 1;

                for (i = 0; i < N; i = i+1) begin
                    if (result_valid[i] && cap_cnt[i] < N) begin
                        captured[i][cap_cnt[i]] = bf16_result[i*16 +: 16];
                        cap_cnt[i] = cap_cnt[i] + 1;
                    end
                end

                // Check if all captured
                all_done = 1'b1;
                for (i = 0; i < N; i = i+1)
                    if (cap_cnt[i] < N) all_done = 1'b0;
            end

            if (timeout_cnt >= 5000)
                $display("  [WARN] capture_results timeout");
        end
    endtask

    // ----------------------------------------------------------------
    // Output log file (opened once, all modes appended)
    // ----------------------------------------------------------------
    integer log_fd;

    // ----------------------------------------------------------------
    // Write hardware output for one mode:
    //   hw_<mode_str>.hex  — one 4-digit hex per line, same format as gold_*.hex
    //   hw_output_log.txt  — human-readable: hex + decoded float + golden + error
    // ----------------------------------------------------------------
    task write_output;
        input [8*16-1:0] mode_str;  // e.g. "bf16_bf16"
        input [2:0]      m;
        integer hex_fd, i, k;
        real got, exp_v, rel_err, denom;
        reg [8*64-1:0] hex_path;
        begin
            // --- Per-mode hex file (matches gold_*.hex format for diff) ---
            case (m)
                3'b001: hex_fd = $fopen("../vectors/hw_bf16_bf16.hex", "w");
                3'b010: hex_fd = $fopen("../vectors/hw_bf16_int8.hex", "w");
                3'b011: hex_fd = $fopen("../vectors/hw_bf16_int4.hex", "w");
                3'b100: hex_fd = $fopen("../vectors/hw_int4_int4.hex", "w");
                3'b101: hex_fd = $fopen("../vectors/hw_int8_int4.hex", "w");
                3'b110: hex_fd = $fopen("../vectors/hw_int8_int8.hex", "w");
                default: hex_fd = 0;
            endcase

            for (i = 0; i < N; i = i+1)
                for (k = 0; k < N; k = k+1)
                    $fdisplay(hex_fd, "%04h", captured[i][k]);
            $fclose(hex_fd);

            // --- Append to combined log ---
            $fdisplay(log_fd, "");
            $fdisplay(log_fd, "=== Mode %s ===", mode_str);
            $fdisplay(log_fd, "%-6s %-6s %-10s %-10s %-10s %-10s %s",
                      "row", "col", "hw_hex", "gold_hex", "hw_float", "gold_float", "rel_err_%");
            $fdisplay(log_fd, "%s", "----------------------------------------------------------------------");

            for (i = 0; i < N; i = i+1) begin
                for (k = 0; k < N; k = k+1) begin
                    got     = bf16_to_real(captured[i][k]);
                    exp_v   = bf16_to_real(gold_mem[i*N + k]);
                    denom   = fmax_f(fabs_f(exp_v), 1e-6);
                    rel_err = fabs_f(got - exp_v) / denom * 100.0;
                    $fdisplay(log_fd, "%-6d %-6d %04h       %04h       %-10f %-10f %.4f",
                              i, k,
                              captured[i][k], gold_mem[i*N + k],
                              got, exp_v, rel_err);
                end
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Check results for current mode
    // tol_pct: tolerance in percent (relative error)
    // ----------------------------------------------------------------
    integer fail_count;
    task check_results;
        input real tol_pct;
        integer i, k;
        real got, exp_v, rel_err, denom;
        begin
            fail_count = 0;
            for (i = 0; i < N; i = i+1) begin
                for (k = 0; k < N; k = k+1) begin
                    got   = bf16_to_real(captured[i][k]);
                    exp_v = bf16_to_real(gold_mem[i*N + k]);
                    denom = fmax_f(fabs_f(exp_v), 1e-6);
                    rel_err = fabs_f(got - exp_v) / denom * 100.0;
                    if (rel_err > tol_pct) begin
                        $display("  FAIL [%0d][%0d]: got=%f exp=%f (err=%.2f%%)",
                                 i, k, got, exp_v, rel_err);
                        fail_count = fail_count + 1;
                    end
                end
            end
            if (fail_count == 0)
                $display("  PASS (all %0d results within %.0f%%)", N*N, tol_pct);
            else begin
                $display("  FAIL: %0d/%0d results out of tolerance", fail_count, N*N);
                modes_failed = modes_failed + 1;
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Reset and run (called after $readmemh loads are done inline)
    // ----------------------------------------------------------------
    task setup_and_run;
        input [2:0] m;
        begin
            rst  = 1'b1;
            mode = m;
            act_load_en    = 1'b0;
            weight_feed_en = 1'b0;
            start          = 1'b0;
            repeat(4) @(posedge clk);
            #1; rst = 1'b0;

            load_activations;
            trigger_and_load_weights;
            capture_results;

            @(posedge done); #1;
            $display("  Cycle count: %0d", cycle_count);
        end
    endtask

    // ----------------------------------------------------------------
    // Vector-load guard
    //
    // $readmemh leaves a memory *untouched* when the file cannot be opened,
    // so a run from the wrong working directory would compare uninitialised
    // data against uninitialised data and report PASS. Poison the memories
    // with X before each load, then confirm every entry was overwritten.
    // ----------------------------------------------------------------
    integer load_errors;
    integer modes_failed;

    task poison_mems;
        integer i;
        begin
            for (i = 0; i < N*N; i = i+1) begin
                act_mem[i]  = 16'hxxxx;
                wt_mem[i]   = 16'hxxxx;
                gold_mem[i] = 16'hxxxx;
            end
        end
    endtask

    task verify_loaded;
        input [8*16-1:0] tag;
        integer i;
        begin
            load_errors = 0;
            for (i = 0; i < N*N; i = i+1) begin
                if (^act_mem[i]  === 1'bx) load_errors = load_errors + 1;
                if (^wt_mem[i]   === 1'bx) load_errors = load_errors + 1;
                if (^gold_mem[i] === 1'bx) load_errors = load_errors + 1;
            end
            if (load_errors != 0) begin
                $display("");
                $display("  *** VECTOR LOAD FAILED for %0s ***", tag);
                $display("  %0d of %0d entries were never initialised.",
                         load_errors, 3*N*N);
                $display("");
                $display("  The testbench reads ../vectors/*.hex relative to the");
                $display("  current directory, so it must be run from tests/:");
                $display("      cd tests && vvp sim_v2");
                $display("");
                $display("  If the vectors do not exist yet, generate them first:");
                $display("      (cd vectors && python3 gen_vectors.py)");
                $display("");
                $fatal(1, "aborting: refusing to report PASS on unloaded data");
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Main
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("tb_systolic_array_v2.vcd");
        $dumpvars(0, tb_systolic_array_v2);
        modes_failed = 0;

        log_fd = $fopen("../vectors/hw_output_log.txt", "w");
        $fdisplay(log_fd, "Hybrid Systolic Array v2 — Hardware Output Log");
        $fdisplay(log_fd, "N=%0d  ACC_WIDTH=%0d", N, ACC_WIDTH);
        $fdisplay(log_fd, "Columns: row, col, hw_hex, gold_hex, hw_float, gold_float, rel_err_%%");

        clk = 0; rst = 1; start = 0;
        act_load_en = 0; weight_feed_en = 0;

        // --- Mode 001: BF16×BF16 ---
        $display("\n=== Mode 3'b001 (BF16 x BF16) ===");
        poison_mems;
        $readmemh("../vectors/act_bf16_bf16.hex",  act_mem);
        $readmemh("../vectors/wt_bf16_bf16.hex",   wt_mem);
        $readmemh("../vectors/gold_bf16_bf16.hex", gold_mem);
        verify_loaded("bf16_bf16");
        setup_and_run(3'b001);
        check_results(2.0);
        write_output("bf16_bf16", 3'b001);

        // --- Mode 010: BF16×INT8 ---
        $display("\n=== Mode 3'b010 (BF16 x INT8) ===");
        poison_mems;
        $readmemh("../vectors/act_bf16_int8.hex",  act_mem);
        $readmemh("../vectors/wt_bf16_int8.hex",   wt_mem);
        $readmemh("../vectors/gold_bf16_int8.hex", gold_mem);
        verify_loaded("bf16_int8");
        setup_and_run(3'b010);
        check_results(5.0);
        write_output("bf16_int8", 3'b010);

        // --- Mode 011: BF16×INT4 ---
        $display("\n=== Mode 3'b011 (BF16 x INT4) ===");
        poison_mems;
        $readmemh("../vectors/act_bf16_int4.hex",  act_mem);
        $readmemh("../vectors/wt_bf16_int4.hex",   wt_mem);
        $readmemh("../vectors/gold_bf16_int4.hex", gold_mem);
        verify_loaded("bf16_int4");
        setup_and_run(3'b011);
        check_results(15.0);
        write_output("bf16_int4", 3'b011);

        // --- Mode 100: INT4×INT4 ---
        $display("\n=== Mode 3'b100 (INT4 x INT4) ===");
        poison_mems;
        $readmemh("../vectors/act_int4_int4.hex",  act_mem);
        $readmemh("../vectors/wt_int4_int4.hex",   wt_mem);
        $readmemh("../vectors/gold_int4_int4.hex", gold_mem);
        verify_loaded("int4_int4");
        setup_and_run(3'b100);
        check_results(0.1);
        write_output("int4_int4", 3'b100);

        // --- Mode 101: INT8×INT4 ---
        $display("\n=== Mode 3'b101 (INT8 x INT4) ===");
        poison_mems;
        $readmemh("../vectors/act_int8_int4.hex",  act_mem);
        $readmemh("../vectors/wt_int8_int4.hex",   wt_mem);
        $readmemh("../vectors/gold_int8_int4.hex", gold_mem);
        verify_loaded("int8_int4");
        setup_and_run(3'b101);
        check_results(0.1);
        write_output("int8_int4", 3'b101);

        // --- Mode 110: INT8×INT8 ---
        $display("\n=== Mode 3'b110 (INT8 x INT8) ===");
        poison_mems;
        $readmemh("../vectors/act_int8_int8.hex",  act_mem);
        $readmemh("../vectors/wt_int8_int8.hex",   wt_mem);
        $readmemh("../vectors/gold_int8_int8.hex", gold_mem);
        verify_loaded("int8_int8");
        setup_and_run(3'b110);
        check_results(0.1);
        write_output("int8_int8", 3'b110);

        $fclose(log_fd);
        $display("\nAll modes done.");
        $display("Output files written to vectors/:");
        $display("  hw_output_log.txt        — combined log (hex + float + error)");
        $display("  hw_<mode>.hex            — per-mode hex (diff against gold_<mode>.hex)");

        if (modes_failed != 0) begin
            $display("\nRESULT: %0d of 6 modes FAILED", modes_failed);
            $fatal(1, "functional testbench failed");
        end
        $display("\nRESULT: all 6 modes PASSED");
        $finish;
    end

endmodule
