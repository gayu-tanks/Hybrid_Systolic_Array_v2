`timescale 1ns / 1ps

// 4×4 Shift-and-Add Multiplier (no * operator).
//
// Mirrors the structure of mult_8x4_shift_add from hybrid_systolic_array.
// 'a' is sign-extended to 5 bits based on a_signed, then multiplied by
// 'b' using shift-and-add over b's four bits.
// When b_signed=1, b[3] is the 2's-complement MSB (weight -8), so its
// partial product is subtracted rather than added.
//
// Output: 9-bit signed, covers all operand combinations:
//   U×U: 0..225   S×U: -120..105   U×S: -120..105   S×S: -64..56

module mult_4x4 (
    input  wire [3:0] a,
    input  wire [3:0] b,
    input  wire       a_signed,
    input  wire       b_signed,
    output wire signed [8:0] product
);

    // Sign- or zero-extend a to 5 bits
    wire signed [4:0] a_ext = a_signed ? {a[3], a} : {1'b0, a};

    // Partial products: a_ext shifted by 0..3, sign-extended to 9 bits.
    // Each is gated by the corresponding bit of b.
    wire signed [8:0] pp0 = b[0] ? {{4{a_ext[4]}}, a_ext}       : 9'sb0;
    wire signed [8:0] pp1 = b[1] ? {{3{a_ext[4]}}, a_ext, 1'b0} : 9'sb0;
    wire signed [8:0] pp2 = b[2] ? {{2{a_ext[4]}}, a_ext, 2'b0} : 9'sb0;
    wire signed [8:0] pp3 = b[3] ? { {a_ext[4]},   a_ext, 3'b0} : 9'sb0;

    // Lower three partial products always added
    wire signed [8:0] sum_lower = pp0 + pp1 + pp2;

    // MSB partial product: subtract (2's complement -8·b[3]) when b_signed
    assign product = b_signed ? (sum_lower - pp3) : (sum_lower + pp3);

endmodule
