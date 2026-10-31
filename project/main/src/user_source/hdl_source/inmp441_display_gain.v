// Fixed display gain: 16x relative to taking sample_in[23:8].
// Arithmetic shift by four, with signed 16-bit saturation.
module inmp441_display_gain(
    input  signed [23:0] sample_in,
    output signed [15:0] sample_out
);
assign sample_out = (sample_in > 24'sd524287) ? 16'sh7fff :
                    (sample_in < -24'sd524288) ? 16'sh8000 :
                    sample_in[19:4];
endmodule
