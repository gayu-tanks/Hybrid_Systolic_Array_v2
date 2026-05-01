`timescale 1ns / 1ps

// Output Post-Processor v2 — 3-bit mode
//
// Converts accumulated (mantissa integer + exp) to BF16.
//
// The PE accumulates integer products; the exp_acc tracks the scale.
// Exponent corrections (to compensate for integer mantissa representation):
//
//   BF16×BF16 (001): acc_exp - 14  (both mantissas are 8-bit ints → /128/128 = /2^14)
//   BF16×INT8 (010): acc_exp - 7   (BF16 mantissa is 8-bit int → /128 = /2^7)
//   BF16×INT4 (011): acc_exp - 7   (BF16 mantissa is 8-bit int → /128 = /2^7)
//   INT4×INT4 (100): 127           (pure integer acc; 2^msb * 1.frac, bias = 127)
//   INT8×INT4 (101): 127           (pure integer acc)
//   INT8×INT8 (110): 127           (pure integer acc)
//
// final_exp = corrected_exp + msb_pos

module output_post_processor_v2 #(
    parameter ACC_WIDTH = 24
) (
    input  wire [2:0]  mode,
    input  wire signed [ACC_WIDTH-1:0] acc_mantissa,
    input  wire [7:0]                  acc_exp,
    input  wire                        valid_in,
    output reg  [15:0]                 bf16_out,
    output reg                         valid_out
);

    localparam MODE_BF16_BF16 = 3'b001;
    localparam MODE_BF16_INT8 = 3'b010;
    localparam MODE_BF16_INT4 = 3'b011;
    localparam MODE_INT4_INT4 = 3'b100;
    localparam MODE_INT8_INT4 = 3'b101;
    localparam MODE_INT8_INT8 = 3'b110;

    // Find position of the most-significant set bit (0-indexed from LSB)
    function integer leading_one;
        input [ACC_WIDTH-1:0] val;
        integer idx;
        begin
            leading_one = 0;
            for (idx = 0; idx < ACC_WIDTH; idx = idx+1)
                if (val[idx]) leading_one = idx;
        end
    endfunction

    reg          sign;
    reg [ACC_WIDTH-1:0] abs_mantissa;
    reg [8:0]    corrected_exp;   // 9-bit to handle -14 without underflow
    integer      msb_pos;
    reg [8:0]    final_exp;
    reg [6:0]    frac;
    reg [ACC_WIDTH-1:0] shifted;

    always @(*) begin
        bf16_out  = 16'b0;
        valid_out = valid_in;

        if (valid_in) begin
            sign         = acc_mantissa[ACC_WIDTH-1];
            abs_mantissa = sign ? (-acc_mantissa) : acc_mantissa;

            case (mode)
                MODE_BF16_BF16: corrected_exp = {1'b0, acc_exp} - 9'd14;
                MODE_BF16_INT8,
                MODE_BF16_INT4: corrected_exp = {1'b0, acc_exp} - 9'd7;
                default:        corrected_exp = 9'd127;  // INT×INT: pure integer
            endcase

            if (abs_mantissa == 0) begin
                bf16_out = {sign, 15'b0};
            end else begin
                msb_pos   = leading_one(abs_mantissa);
                final_exp = corrected_exp + msb_pos[8:0];

                if (msb_pos > 7)
                    shifted = abs_mantissa >> (msb_pos - 7);
                else
                    shifted = abs_mantissa << (7 - msb_pos);
                frac = shifted[6:0];

                if (final_exp[8] || final_exp == 9'd0) begin
                    // Underflow / subnormal
                    bf16_out = {sign, 8'b0, frac};
                end else if (final_exp >= 9'd255) begin
                    // Overflow → infinity
                    bf16_out = {sign, 8'hFF, 7'b0};
                end else begin
                    bf16_out = {sign, final_exp[7:0], frac};
                end
            end
        end
    end

endmodule
