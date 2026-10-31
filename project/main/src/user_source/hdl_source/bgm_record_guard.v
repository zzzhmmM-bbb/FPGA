`timescale 1ns/1ps
// Video-clock domain: immediately mute in-flight BGM during capture/playback.
// Keep pause until the existing recording mux has actually returned to tone.
module bgm_record_guard (
    input wire I_capture,
    input wire I_play_start,
    input wire I_play_busy,
    input wire I_tone_selected,
    input wire [23:0] I_left,
    input wire [23:0] I_right,
    output wire O_pause,
    output wire [23:0] O_left,
    output wire [23:0] O_right
);
    assign O_pause = I_capture || I_play_start || I_play_busy || !I_tone_selected;
    assign O_left = O_pause ? 24'd0 : I_left;
    assign O_right = O_pause ? 24'd0 : I_right;
endmodule
