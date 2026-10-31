`timescale 1ns/1ps
// Physical KEY1 is an ordinary active-low input, not the raw system reset.
// Independent 50 MHz reference clock: 20 ms debounce, 2 s long press.
module key1_mode_control #(
    parameter integer DEBOUNCE_CYCLES = 1000000,
    parameter integer LONG_CYCLES = 100000000,
    parameter integer RESET_CYCLES = 50000
)(
    input wire clk, key_n, input wire inhibit_long,
    output reg system_reset_n,
    output reg auto_mode
);
    // Configuration-time FF initialization; never reset this sequencer from
    // KEY1 or a PLL output. It must keep running while the system/PLLs reset.
    reg [7:0] power_on_pipe = 8'b0;
    always @(posedge clk) power_on_pipe <= {power_on_pipe[6:0], 1'b1};
    wire power_on_n = &power_on_pipe;
    wire short_press, long_press;
    localparam integer RW = (RESET_CYCLES < 2) ? 1 : $clog2(RESET_CYCLES + 1);
    reg [RW-1:0] reset_left;
    (* async_reg = "true" *) reg [1:0] inhibit_sync;
    reg blocked_gesture;
    reg [1:0] key_sync;
    reg [20:0] release_count;
    always @(posedge clk or negedge power_on_n) begin
        if(!power_on_n) begin inhibit_sync<=0;key_sync<=3;blocked_gesture<=0;release_count<=0;end
        else begin
            inhibit_sync<={inhibit_sync[0],inhibit_long};key_sync<={key_sync[0],key_n};
            if(inhibit_sync[1]) begin blocked_gesture<=1;release_count<=0;end
            else if(!key_sync[1]) release_count<=0;
            else if(release_count<DEBOUNCE_CYCLES+4) release_count<=release_count+1'b1;
            else blocked_gesture<=0;
        end
    end
    calibration_key #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),
                      .LONG_CYCLES(LONG_CYCLES)) u_key1_gesture(
        .clk(clk), .rst_n(power_on_n), .key_n(key_n),
        .short_press(short_press), .long_press(long_press)
    );
    always @(posedge clk or negedge power_on_n) begin
        if (!power_on_n) begin
            reset_left <= 0;
            system_reset_n <= 0;
            auto_mode <= 0;
        end else begin
            if (short_press) begin
                reset_left <= RESET_CYCLES;
                system_reset_n <= 0;
                auto_mode <= 0;
            end else begin
                if (reset_left != 0) reset_left <= reset_left - 1'b1;
                // Register the reset output: counter-bit routing skew must not
                // create short deassertion glitches at the PLL reset pins.
                system_reset_n <= (reset_left <= 1);
                if (long_press && !inhibit_sync[1] && !blocked_gesture) auto_mode <= ~auto_mode;
            end
        end
    end
endmodule
