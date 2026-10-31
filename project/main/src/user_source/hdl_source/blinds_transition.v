`timescale 1ns/1ps
// Isolated step-1 candidate. vs/de/rgb_in are the FINAL, aligned video signals.
// No new RGB/DE/VS latency. An active line keeps one fixed row_phase.
module blinds_transition (
    input wire clk, rst_n,
    input wire vs, de,
    input wire [23:0] rgb_in,
    input wire [8:0] alpha,
    input wire blinds_active,
    output wire [23:0] rgb_out
);
    reg vs_q, de_q;
    reg [4:0] row_phase;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q <= 1'b1;
            de_q <= 1'b0;
            row_phase <= 5'd0;
        end else begin
            vs_q <= vs;
            de_q <= de;
            if (vs_q && !vs)
                row_phase <= 5'd0;
            else if (de_q && !de)
                row_phase <= row_phase + 5'd1;
        end
    end
    // alpha=0..256 -> 0..32 visible rows in each 32-line strip.
    // Feed binary 0/256 to the EXISTING fade instead of adding a 24-bit mux.
    wire visible = alpha[8] || (row_phase < alpha[7:3]);
    wire [8:0] effective_alpha = blinds_active ? {visible, 8'd0} : alpha;
    fade_transition u_fade(.rgb_in(rgb_in), .alpha(effective_alpha), .rgb_out(rgb_out));
endmodule
