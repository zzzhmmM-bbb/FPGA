`timescale 1ns/1ps

module startup_reset_control #(
    parameter integer STABLE_CYCLES = 1_000_000
) (
    input  wire clk,
    input  wire rst_n,
    input  wire sys_pll_locked,
    input  wire video_pll_locked,
    input  wire audio_pll_locked,
    output wire pll_reset,
    output reg  global_reset
);
    localparam integer COUNT_WIDTH = (STABLE_CYCLES < 2) ? 1 : $clog2(STABLE_CYCLES);
    wire [2:0] locks = {sys_pll_locked, video_pll_locked, audio_pll_locked};
    wire reset_request = ~rst_n | ~(&locks);
    (* async_reg = "true" *) reg [2:0] locks_meta, locks_sync;
    reg [COUNT_WIDTH-1:0] stable_count;

    // Never feed loss of lock back into the PLL reset inputs.
    assign pll_reset = ~rst_n;

    always @(posedge clk or posedge reset_request) begin
        if (reset_request) begin
            locks_meta <= 3'b000;
            locks_sync <= 3'b000;
        end else begin
            locks_meta <= locks;
            locks_sync <= locks_meta;
        end
    end

    always @(posedge clk or posedge reset_request) begin
        if (reset_request) begin
            stable_count <= 0;
            global_reset <= 1'b1;
        end else if (&locks_sync) begin
            if (stable_count == STABLE_CYCLES - 1)
                global_reset <= 1'b0;
            else
                stable_count <= stable_count + 1'b1;
        end else begin
            stable_count <= 0;
            global_reset <= 1'b1;
        end
    end
endmodule
