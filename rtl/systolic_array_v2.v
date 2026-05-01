`timescale 1ns / 1ps

// N×N Systolic Array v2 — Hybrid Systolic Array
//
// Activations are stationary (loaded row-wise into each PE).
// Weights flow top-to-bottom (systolically, one column per cycle).
// Accumulators + exp_acc flow left-to-right.
//
// No internal column skew — top-level pre-skews weight_col_timed/weight_valid_timed.
// Single accumulation channel (no dual channel).
// 3-bit mode matches processing_element_v2.

module systolic_array_v2 #(
    parameter N         = 8,
    parameter ACC_WIDTH = 24
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [2:0]  mode,

    // Activation loading (one row at a time)
    input  wire [N*16-1:0]      activation_row,
    input  wire                 load_act,
    input  wire [$clog2(N)-1:0] act_row_sel,

    // Weight inputs — pre-skewed by top-level
    input  wire [N*16-1:0] weight_col_timed,
    input  wire [N-1:0]    weight_valid_timed,

    // Right-boundary outputs (one per row)
    output wire [N*ACC_WIDTH-1:0] result_acc,
    output wire [N*8-1:0]         result_exp,
    output wire [N-1:0]           result_valid
);

    // ================================================================
    // Inter-PE wiring
    // ================================================================

    // Vertical weight wires (top-to-bottom, per column)
    wire [15:0] weight_v       [0:N][0:N-1];
    wire        weight_valid_v [0:N][0:N-1];

    // Horizontal accumulation wires (left-to-right, per row)
    wire signed [ACC_WIDTH-1:0] acc_h       [0:N-1][0:N];
    wire [7:0]                  exp_acc_h   [0:N-1][0:N];
    wire                        acc_valid_h [0:N-1][0:N];

    genvar i, j;
    generate
        // Top boundary: from pre-skewed top-level signals
        for (j = 0; j < N; j = j+1) begin : gen_wt_top
            assign weight_v[0][j]       = weight_col_timed[j*16 +: 16];
            assign weight_valid_v[0][j] = weight_valid_timed[j];
        end

        // Left boundary: zero acc, zero exp, invalid
        for (i = 0; i < N; i = i+1) begin : gen_acc_left
            assign acc_h[i][0]       = {ACC_WIDTH{1'b0}};
            assign exp_acc_h[i][0]   = 8'd0;
            assign acc_valid_h[i][0] = 1'b0;
        end

        // PE array
        for (i = 0; i < N; i = i+1) begin : gen_row
            for (j = 0; j < N; j = j+1) begin : gen_col

                wire load_act_pe = load_act && (act_row_sel == i[$clog2(N)-1:0]);

                processing_element_v2 #(
                    .ACC_WIDTH(ACC_WIDTH)
                ) u_pe (
                    .clk              (clk),
                    .rst              (rst),
                    .mode             (mode),
                    .activation_in    (activation_row[j*16 +: 16]),
                    .load_activation  (load_act_pe),
                    .weight_in        (weight_v[i][j]),
                    .weight_valid_in  (weight_valid_v[i][j]),
                    .weight_out       (weight_v[i+1][j]),
                    .weight_valid_out (weight_valid_v[i+1][j]),
                    .acc_in           (acc_h[i][j]),
                    .exp_acc_in       (exp_acc_h[i][j]),
                    .acc_valid_in     (acc_valid_h[i][j]),
                    .acc_out          (acc_h[i][j+1]),
                    .exp_acc_out      (exp_acc_h[i][j+1]),
                    .acc_valid_out    (acc_valid_h[i][j+1])
                );
            end
        end

        // Right-boundary outputs
        // result_valid uses weight_valid_v[i+1][N-1] (weight_valid_out of rightmost PE),
        // which pulses exactly once per step — avoids the level-signal ambiguity of
        // acc_valid_h which stays high during idle pass-through between steps.
        for (i = 0; i < N; i = i+1) begin : gen_output
            assign result_acc[i*ACC_WIDTH +: ACC_WIDTH] = acc_h[i][N];
            assign result_exp[i*8 +: 8]                 = exp_acc_h[i][N];
            assign result_valid[i]                       = weight_valid_v[i+1][N-1];
        end
    endgenerate

endmodule
