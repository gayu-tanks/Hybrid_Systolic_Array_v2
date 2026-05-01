`timescale 1ns / 1ps

// Top-level for Hybrid Systolic Array v2
//
// FSM: IDLE → LOAD (N weight columns) → COMPUTE → DRAIN → DONE
//
// L-cycle j-skew: column j receives step k when compute_cycle == k*L + j.
// L is derived from mode:
//   3'b100 (INT4×INT4):  L=1
//   3'b011 (BF16×INT4),
//   3'b101 (INT8×INT4):  L=2
//   3'b001 (BF16×BF16),
//   3'b010 (BF16×INT8),
//   3'b110 (INT8×INT8):  L=4
//
// Compute phase runs for (2N-1)*L + (N-1) cycles total.

module systolic_array_v2_top #(
    parameter N         = 8,
    parameter ACC_WIDTH = 24
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [2:0]  mode,

    // Activation loading (user drives these directly)
    input  wire [N*16-1:0]      act_row_data,
    input  wire [$clog2(N)-1:0] act_row_idx,
    input  wire                 act_load_en,

    // Weight loading: feed N columns sequentially after start
    input  wire [N*16-1:0] weight_col_data,
    input  wire            weight_feed_en,

    // Control
    input  wire start,
    output reg  busy,
    output reg  done,
    output wire [15:0] cycle_count,

    // Results (one per row, BF16)
    output wire [N*16-1:0] bf16_result,
    output wire [N-1:0]    result_valid
);

    // ----------------------------------------------------------------
    // Mode decode
    // ----------------------------------------------------------------
    localparam MODE_BF16_BF16 = 3'b001;
    localparam MODE_BF16_INT8 = 3'b010;
    localparam MODE_BF16_INT4 = 3'b011;
    localparam MODE_INT4_INT4 = 3'b100;
    localparam MODE_INT8_INT4 = 3'b101;
    localparam MODE_INT8_INT8 = 3'b110;

    reg [1:0] mult_lat_log;  // log2(L)
    always @(*) begin
        case (mode)
            MODE_INT4_INT4: mult_lat_log = 2'd0;  // L=1
            MODE_BF16_INT4,
            MODE_INT8_INT4: mult_lat_log = 2'd1;  // L=2
            default:        mult_lat_log = 2'd2;  // L=4
        endcase
    end

    wire [2:0] L = 3'd1 << mult_lat_log;  // 1, 2, or 4

    // ----------------------------------------------------------------
    // Weight buffer: wt_buf[step][col]
    // ----------------------------------------------------------------
    reg [15:0] wt_buf [0:N-1][0:N-1];

    // ----------------------------------------------------------------
    // FSM
    // ----------------------------------------------------------------
    localparam S_IDLE    = 3'd0;
    localparam S_LOAD    = 3'd1;
    localparam S_COMPUTE = 3'd2;
    localparam S_DRAIN   = 3'd3;
    localparam S_DONE    = 3'd4;

    reg [2:0]  state;
    reg [$clog2(N)-1:0] load_col;       // which weight column we're loading
    reg [8:0]  compute_cycle;

    // compute phase ends when compute_cycle == (2N-1)*L + (N-2)
    wire [8:0] compute_max = (2*N-1) * {6'b0, L} + (N-2);

    // ----------------------------------------------------------------
    // Cycle counter
    // ----------------------------------------------------------------
    reg [15:0] cycle_running;
    reg [15:0] cycle_count_r;
    assign cycle_count = cycle_count_r;

    always @(posedge clk) begin
        if (rst) begin
            cycle_running <= 16'd0;
            cycle_count_r <= 16'd0;
        end else begin
            if (start)
                cycle_running <= 16'd1;
            else if (state != S_IDLE)
                cycle_running <= cycle_running + 16'd1;
            if (state == S_DRAIN)
                cycle_count_r <= cycle_running + 16'd1;
        end
    end

    // ----------------------------------------------------------------
    // FSM transitions + weight buffer loading
    // ----------------------------------------------------------------
    integer k, c;
    always @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            load_col      <= {$clog2(N){1'b0}};
            compute_cycle <= 9'd0;
            for (k = 0; k < N; k = k+1)
                for (c = 0; c < N; c = c+1)
                    wt_buf[k][c] <= 16'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        busy     <= 1'b1;
                        load_col <= {$clog2(N){1'b0}};
                        state    <= S_LOAD;
                    end
                end

                S_LOAD: begin
                    if (weight_feed_en) begin
                        // Store column weight_col_data as step load_col
                        for (k = 0; k < N; k = k+1)
                            wt_buf[load_col][k] <= weight_col_data[k*16 +: 16];

                        if (load_col == N-1) begin
                            compute_cycle <= 9'd0;
                            state         <= S_COMPUTE;
                        end else begin
                            load_col <= load_col + 1'b1;
                        end
                    end
                end

                S_COMPUTE: begin
                    if (compute_cycle == compute_max)
                        state <= S_DRAIN;
                    else
                        compute_cycle <= compute_cycle + 9'd1;
                end

                S_DRAIN: begin
                    state <= S_DONE;
                end

                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ----------------------------------------------------------------
    // Pre-skewed weight delivery to array
    //
    // Column j gets step k when compute_cycle == k*L + j, i.e.:
    //   diff = compute_cycle - j  (unsigned; check no underflow)
    //   valid when in_compute && diff[0:0] == 0 (L=2) or diff[1:0]==0 (L=4)
    //             && diff >> mult_lat_log < N
    // ----------------------------------------------------------------
    wire in_compute = (state == S_COMPUTE);

    wire [N*16-1:0] weight_col_timed;
    wire [N-1:0]    weight_valid_timed;

    genvar gj;
    generate
        for (gj = 0; gj < N; gj = gj+1) begin : gen_skew
            wire [8:0] diff = compute_cycle - gj[8:0];
            // No underflow: compute_cycle >= gj (since gj < N and we start at 0)
            wire        no_underflow  = (compute_cycle >= gj[8:0]);
            wire        aligned       = ((diff & ({7'b0, L} - 9'd1)) == 9'd0);
            wire [8:0]  step_idx_ext  = diff >> mult_lat_log;
            wire        step_in_range = (step_idx_ext < N);
            wire        valid         = in_compute && no_underflow && aligned && step_in_range;

            assign weight_valid_timed[gj]          = valid;
            assign weight_col_timed[gj*16 +: 16]  = valid ? wt_buf[step_idx_ext[$clog2(N)-1:0]][gj] : 16'd0;
        end
    endgenerate

    // ----------------------------------------------------------------
    // Systolic array
    // ----------------------------------------------------------------
    wire [N*ACC_WIDTH-1:0] sa_acc;
    wire [N*8-1:0]         sa_exp;
    wire [N-1:0]           sa_valid;

    systolic_array_v2 #(
        .N(N),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_sa (
        .clk               (clk),
        .rst               (rst),
        .mode              (mode),
        .activation_row    (act_row_data),
        .load_act          (act_load_en),
        .act_row_sel       (act_row_idx),
        .weight_col_timed  (weight_col_timed),
        .weight_valid_timed(weight_valid_timed),
        .result_acc        (sa_acc),
        .result_exp        (sa_exp),
        .result_valid      (sa_valid)
    );

    // ----------------------------------------------------------------
    // Output post-processors (one per row)
    // ----------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi+1) begin : gen_pp
            output_post_processor_v2 #(
                .ACC_WIDTH(ACC_WIDTH)
            ) u_pp (
                .mode         (mode),
                .acc_mantissa (sa_acc[gi*ACC_WIDTH +: ACC_WIDTH]),
                .acc_exp      (sa_exp[gi*8 +: 8]),
                .valid_in     (sa_valid[gi]),
                .bf16_out     (bf16_result[gi*16 +: 16]),
                .valid_out    (result_valid[gi])
            );
        end
    endgenerate

endmodule
