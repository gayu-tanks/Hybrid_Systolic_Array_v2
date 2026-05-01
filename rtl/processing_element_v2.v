`timescale 1ns / 1ps

// Processing Element v2 — Hybrid Systolic Array
//
// Uses a single 4×4 multiplier iterated L cycles (mode-dependent):
//   L=1 : INT4×INT4   (3'b100)
//   L=2 : BF16×INT4, INT8×INT4   (3'b011, 3'b101)
//   L=4 : BF16×BF16, BF16×INT8, INT8×INT8  (3'b001, 3'b010, 3'b110)
//
// Protocol:
//   - weight_valid_in pulses for exactly 1 cycle per weight step.
//   - PE holds the weight internally for L cycles; after the last
//     partial product, it pulses weight_valid_out=1 and updates acc_out.
//   - During intermediate cycles the accumulator passes through unchanged.
//   - Top-level provides L×j column skew so acc from the left is ready
//     on the final cycle of each PE's computation (proven by timing analysis).
//
// EHU: product exponent vs running acc exponent → shift/swap/exp_out.
// For INT×INT modes: act_exp=0, wt_exp=0 → shift=0, accumulates integers.

module processing_element_v2 #(
    parameter ACC_WIDTH = 24
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [2:0]  mode,

    input  wire [15:0] activation_in,
    input  wire        load_activation,

    input  wire [15:0] weight_in,
    input  wire        weight_valid_in,
    output reg  [15:0] weight_out,
    output reg         weight_valid_out,

    input  wire signed [ACC_WIDTH-1:0] acc_in,
    input  wire [7:0]                  exp_acc_in,
    input  wire                        acc_valid_in,
    output reg  signed [ACC_WIDTH-1:0] acc_out,
    output reg  [7:0]                  exp_acc_out,
    output reg                         acc_valid_out
);

    localparam MODE_BF16_BF16 = 3'b001;
    localparam MODE_BF16_INT8 = 3'b010;
    localparam MODE_BF16_INT4 = 3'b011;
    localparam MODE_INT4_INT4 = 3'b100;
    localparam MODE_INT8_INT4 = 3'b101;
    localparam MODE_INT8_INT8 = 3'b110;

    // ----------------------------------------------------------------
    // Latency: L = 1 << mult_lat_log
    // ----------------------------------------------------------------
    wire [1:0] mult_lat_log =
        (mode == MODE_INT4_INT4)                               ? 2'd0 :  // L=1
        (mode == MODE_BF16_INT4 || mode == MODE_INT8_INT4)    ? 2'd1 :  // L=2
                                                                 2'd2;   // L=4
    wire [2:0] L = 3'd1 << mult_lat_log;   // 1, 2, or 4

    // ----------------------------------------------------------------
    // Activation register
    // ----------------------------------------------------------------
    reg [15:0] act_reg;
    always @(posedge clk) begin
        if (rst)                  act_reg <= 16'd0;
        else if (load_activation) act_reg <= activation_in;
    end

    wire        act_sign = act_reg[15];
    wire [7:0]  act_exp  = (mode[2] == 1'b0) ? act_reg[14:7] : 8'd0;
                // BF16 modes (001,010,011) use BF16 exponent; INT modes (1xx) use 0

    wire [7:0] act_mantissa =
        (mode == MODE_BF16_BF16 || mode == MODE_BF16_INT8 || mode == MODE_BF16_INT4)
            ? ((act_reg[14:7] != 8'd0) ? {1'b1, act_reg[6:0]} : {1'b0, act_reg[6:0]})
            : (mode == MODE_INT8_INT4 || mode == MODE_INT8_INT8)
                ? act_reg[7:0]
                : {4'd0, act_reg[3:0]};    // INT4: zero-extend to 8 bits

    wire [3:0] act_lo = act_mantissa[3:0];
    wire [3:0] act_hi = act_mantissa[7:4];

    // ----------------------------------------------------------------
    // Weight: use weight_in at cycle 0; wt_hold for cycles 1..L-1
    // wt_live is combinational: selects weight_in when starting,
    // wt_hold when mid-computation.
    // ----------------------------------------------------------------
    reg [15:0] wt_hold;
    always @(posedge clk) begin
        if (rst)                   wt_hold <= 16'd0;
        else if (weight_valid_in)  wt_hold <= weight_in;
    end

    reg  mult_busy;
    wire [15:0] wt_live = (weight_valid_in && !mult_busy) ? weight_in : wt_hold;

    wire        wt_sign = (mode == MODE_BF16_BF16) ? wt_live[15] : 1'b0;
    wire [7:0]  wt_exp  = (mode == MODE_BF16_BF16) ? wt_live[14:7] : 8'd0;

    wire [7:0] wt_byte =
        (mode == MODE_BF16_BF16)
            ? ((wt_live[14:7] != 8'd0) ? {1'b1, wt_live[6:0]} : {1'b0, wt_live[6:0]})
            : (mode == MODE_BF16_INT8 || mode == MODE_INT8_INT8)
                ? wt_live[7:0]
                : {4'd0, wt_live[3:0]};   // INT4/BF16×INT4: lower nibble

    wire [3:0] wt_lo = wt_byte[3:0];
    wire [3:0] wt_hi = wt_byte[7:4];

    // ----------------------------------------------------------------
    // 4×4 multiplier operand selection (combinational)
    // ----------------------------------------------------------------
    reg [2:0]  mult_cnt;
    reg  [3:0] m_a, m_b;
    reg        m_a_sgn, m_b_sgn;
    reg  [3:0] pp_shift;   // bit-position shift (0, 4, or 8)

    always @(*) begin
        m_a = 4'd0; m_b = 4'd0; m_a_sgn = 0; m_b_sgn = 0; pp_shift = 0;
        case (mode)
            MODE_BF16_BF16: case (mult_cnt)   // unsigned mantissa × unsigned mantissa
                3'd0: begin m_a=act_lo; m_b=wt_lo; m_a_sgn=0; m_b_sgn=0; pp_shift=0; end
                3'd1: begin m_a=act_lo; m_b=wt_hi; m_a_sgn=0; m_b_sgn=0; pp_shift=4; end
                3'd2: begin m_a=act_hi; m_b=wt_lo; m_a_sgn=0; m_b_sgn=0; pp_shift=4; end
                3'd3: begin m_a=act_hi; m_b=wt_hi; m_a_sgn=0; m_b_sgn=0; pp_shift=8; end
                default:;
            endcase
            MODE_BF16_INT8: case (mult_cnt)   // unsigned mantissa × signed INT8
                3'd0: begin m_a=act_lo; m_b=wt_lo; m_a_sgn=0; m_b_sgn=0; pp_shift=0; end
                3'd1: begin m_a=act_lo; m_b=wt_hi; m_a_sgn=0; m_b_sgn=1; pp_shift=4; end
                3'd2: begin m_a=act_hi; m_b=wt_lo; m_a_sgn=0; m_b_sgn=0; pp_shift=4; end
                3'd3: begin m_a=act_hi; m_b=wt_hi; m_a_sgn=0; m_b_sgn=1; pp_shift=8; end
                default:;
            endcase
            MODE_BF16_INT4: case (mult_cnt)   // unsigned mantissa × signed INT4
                3'd0: begin m_a=act_lo; m_b=wt_lo; m_a_sgn=0; m_b_sgn=1; pp_shift=0; end
                3'd1: begin m_a=act_hi; m_b=wt_lo; m_a_sgn=0; m_b_sgn=1; pp_shift=4; end
                default:;
            endcase
            MODE_INT4_INT4:                    // signed INT4 × signed INT4
                begin m_a=act_lo; m_b=wt_lo; m_a_sgn=1; m_b_sgn=1; pp_shift=0; end
            MODE_INT8_INT4: case (mult_cnt)   // signed INT8 × signed INT4
                3'd0: begin m_a=act_lo; m_b=wt_lo; m_a_sgn=0; m_b_sgn=1; pp_shift=0; end
                3'd1: begin m_a=act_hi; m_b=wt_lo; m_a_sgn=1; m_b_sgn=1; pp_shift=4; end
                default:;
            endcase
            MODE_INT8_INT8: case (mult_cnt)   // signed INT8 × signed INT8
                3'd0: begin m_a=act_lo; m_b=wt_lo; m_a_sgn=0; m_b_sgn=0; pp_shift=0; end
                3'd1: begin m_a=act_lo; m_b=wt_hi; m_a_sgn=0; m_b_sgn=1; pp_shift=4; end
                3'd2: begin m_a=act_hi; m_b=wt_lo; m_a_sgn=1; m_b_sgn=0; pp_shift=4; end
                3'd3: begin m_a=act_hi; m_b=wt_hi; m_a_sgn=1; m_b_sgn=1; pp_shift=8; end
                default:;
            endcase
            default:;
        endcase
    end

    wire signed [8:0] m_out;
    mult_4x4 u_mult (
        .a(m_a), .b(m_b), .a_signed(m_a_sgn), .b_signed(m_b_sgn), .product(m_out)
    );

    // Sign-extended, bit-shifted partial product
    wire signed [ACC_WIDTH-1:0] pp_contrib =
        {{(ACC_WIDTH-9){m_out[8]}}, m_out} <<< pp_shift;

    // ----------------------------------------------------------------
    // Partial product accumulator (internal to this multiply)
    // ----------------------------------------------------------------
    reg signed [ACC_WIDTH-1:0] pp_acc;

    // Final product (used only at last cycle)
    wire signed [ACC_WIDTH-1:0] full_product_raw = pp_acc + pp_contrib;
    wire combined_sign = (mode == MODE_BF16_BF16) ? (act_sign ^ wt_sign) : 1'b0;
    wire signed [ACC_WIDTH-1:0] full_product =
        combined_sign ? (-full_product_raw) : full_product_raw;

    // ----------------------------------------------------------------
    // EHU (combinational)
    // ----------------------------------------------------------------
    wire [7:0] eff_act_exp = (act_exp != 8'd0) ? act_exp : 8'd1;
    wire [7:0] eff_wt_exp  = (wt_exp  != 8'd0) ? wt_exp  : 8'd1;
    wire [8:0] raw_exp_sum = {1'b0, eff_act_exp} + {1'b0, eff_wt_exp};
    wire [7:0] exp_product =
        (mode == MODE_BF16_BF16) ? (raw_exp_sum[7:0] - 8'd127) : act_exp;

    wire ehu_prod_larger = acc_valid_in ? (exp_product > exp_acc_in) : 1'b1;
    wire [7:0] ehu_diff  = ehu_prod_larger
                           ? (exp_product - exp_acc_in)
                           : (exp_acc_in  - exp_product);
    wire ehu_swap        = ehu_prod_larger;
    wire [7:0] ehu_shift = ehu_diff;
    wire [7:0] ehu_exp_out = ehu_prod_larger ? exp_product : exp_acc_in;

    // Shift-adder
    wire signed [ACC_WIDTH-1:0] shifted_smaller =
        ehu_swap ? (acc_in >>> ehu_shift) : (full_product >>> ehu_shift);
    wire signed [ACC_WIDTH-1:0] larger = ehu_swap ? full_product : acc_in;
    wire signed [ACC_WIDTH-1:0] ehu_result = larger + shifted_smaller;

    // If full_product is zero, pass the accumulator through unchanged.
    // This prevents a zero-product (e.g. ±0.0 BF16 weight) from corrupting
    // the running exp_acc via the synthetic eff_exp=1 formula.
    wire product_is_zero = (full_product == {ACC_WIDTH{1'b0}});
    wire signed [ACC_WIDTH-1:0] sum_out    = product_is_zero ? acc_in : ehu_result;
    wire [7:0]                  ehu_exp_effective =
        product_is_zero ? (acc_valid_in ? exp_acc_in : 8'd0) : ehu_exp_out;

    // ----------------------------------------------------------------
    // Sequential state machine
    // ----------------------------------------------------------------
    wire last_cycle = (mult_cnt == (L - 3'd1));

    always @(posedge clk) begin
        if (rst) begin
            mult_busy        <= 1'b0;
            mult_cnt         <= 3'd0;
            pp_acc           <= {ACC_WIDTH{1'b0}};
            weight_out       <= 16'd0;
            weight_valid_out <= 1'b0;
            acc_out          <= {ACC_WIDTH{1'b0}};
            exp_acc_out      <= 8'd0;
            acc_valid_out    <= 1'b0;
        end else begin
            weight_valid_out <= 1'b0;  // default

            if (weight_valid_in && !mult_busy) begin
                // ---- Cycle 0: start multiplication ----
                if (L == 3'd1) begin
                    // L=1: complete in this cycle (pp_acc starts at 0)
                    acc_out          <= sum_out;
                    exp_acc_out      <= ehu_exp_effective;
                    acc_valid_out    <= 1'b1;
                    weight_out       <= weight_in;
                    weight_valid_out <= 1'b1;
                    pp_acc           <= {ACC_WIDTH{1'b0}};
                end else begin
                    // L>1: accumulate first partial product, continue
                    pp_acc        <= pp_contrib;
                    mult_cnt      <= 3'd1;
                    mult_busy     <= 1'b1;
                    acc_out       <= acc_in;
                    exp_acc_out   <= exp_acc_in;
                    acc_valid_out <= acc_valid_in;
                end

            end else if (mult_busy) begin
                // ---- Cycles 1..L-1: continue multiplication ----
                if (last_cycle) begin
                    acc_out          <= sum_out;
                    exp_acc_out      <= ehu_exp_effective;
                    acc_valid_out    <= 1'b1;
                    weight_out       <= wt_hold;
                    weight_valid_out <= 1'b1;
                    mult_busy        <= 1'b0;
                    mult_cnt         <= 3'd0;
                    pp_acc           <= {ACC_WIDTH{1'b0}};
                end else begin
                    pp_acc        <= pp_acc + pp_contrib;
                    mult_cnt      <= mult_cnt + 3'd1;
                    acc_out       <= acc_in;
                    exp_acc_out   <= exp_acc_in;
                    acc_valid_out <= acc_valid_in;
                end

            end else begin
                // ---- Idle: pass through ----
                acc_out       <= acc_in;
                exp_acc_out   <= exp_acc_in;
                acc_valid_out <= acc_valid_in;
            end
        end
    end

endmodule
