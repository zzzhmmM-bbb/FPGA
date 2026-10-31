`timescale 1ns/1ps
// Cover carousel fade: scales each 8-bit channel by alpha/256.
// alpha = 256 passes the pixel through unchanged, alpha = 0 gives black.
// Pure combinational (zero pixel latency); each channel is a 9x8 multiply.
module fade_transition (
    input  wire [23:0] rgb_in,
    input  wire [8:0]  alpha,      // 0..256, 256 = pass through
    output wire [23:0] rgb_out
);
    wire [16:0] r_mul = rgb_in[23:16] * alpha;
    wire [16:0] g_mul = rgb_in[15:8]  * alpha;
    wire [16:0] b_mul = rgb_in[7:0]   * alpha;

    // c * alpha <= 255 * 256, so bits [15:8] hold the whole result of >> 8.
    assign rgb_out = {r_mul[15:8], g_mul[15:8], b_mul[15:8]};
endmodule
