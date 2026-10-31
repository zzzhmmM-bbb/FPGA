// Board2 logic (v26, link protocol v4), entirely in the clk domain:
// mic PCM -> f0_autocorr (pitch) and formant_lpc (vowel F1/F2, spectrogram)
// -> link f0 / spec bundles, 7-seg codes and LEDs. Speech recognition removed.
// Seven-segment codes are active low, bit7 = decimal point (active low).
//   seg_data_5..4 : f1_bin in hex, seg_data_3..2 : f2_bin in hex
//                   (blank while vowel_valid = 0); other digits blank.
// led (active low): 0 f0_valid, 1 vowel_valid, 2..3 off.
// f0_bundle = link right word [31:8] on seq[0]=1 frames:
//   {2'b00, f0_valid, f0_code[5:0], vowel_valid, f1_bin[5:0], f2_bin[6:0], 1'b0}
// spec_bundle = {spec_seq[1:0], spec_col[255:0]}: one spectrogram column per
//   formant frame (spec_valid), spec_seq counts columns; stable after spec_valid.
//   Sent on seq[0]=0 frames, 16 bits per frame (board2_audio_link, protocol v4).
// status_bundle is fixed to 0 and no longer used from protocol v4 on (port kept).
// key_ptt_n, key_disp_n, link_ptt and the CLK_HZ / DEBOUNCE_MS / MAX_SAMPLES
// parameters are kept only so board2_top and pin.adc stay unchanged; unused.
module board2_logic #(
    parameter integer CLK_HZ      = 50_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter integer MAX_SAMPLES = 80000
) (
    input  wire               clk,
    input  wire               reset,
    input  wire               mic_valid,
    input  wire signed [15:0] mic_data,
    input  wire               key_ptt_n,
    input  wire               key_disp_n,
    input  wire               link_ptt,
    output wire [7:0]         seg_data_0,
    output wire [7:0]         seg_data_1,
    output wire [7:0]         seg_data_2,
    output wire [7:0]         seg_data_3,
    output wire [7:0]         seg_data_4,
    output wire [7:0]         seg_data_5,
    output wire [7:0]         seg_data_6,
    output wire [7:0]         seg_data_7,
    output wire [3:0]         led,
    output wire [23:0]        status_bundle,
    output wire [23:0]        f0_bundle,      // F0 + F1/F2 payload, link protocol v3/v4
    output wire [257:0]       spec_bundle     // spectrogram column, link protocol v4
);
    // ---- F0 (pitch) extraction ----
    wire               f0_valid;
    wire [5:0]         f0_code;

    f0_autocorr #(
        .FRAME_LEN(256),
        .LAG_MIN(32),
        .LAG_MAX(200),
        .VOICED_THR(512)
    ) u_f0 (
        .clk(clk),
        .rst_n(~reset),
        .pcm_valid(mic_valid),
        .pcm_sample(mic_data),
        .f0_valid(f0_valid),
        .f0_code(f0_code)
    );

    // ---- Vowel formants (F1/F2, 31.25 Hz bins) ----
    wire               vowel_valid;
    wire [5:0]         f1_bin;
    wire [6:0]         f2_bin;
    wire               spec_valid;
    wire [255:0]       spec_col;

    formant_lpc #(
        .ENERGY_THR(32768)
    ) u_formant (
        .clk(clk),
        .rst_n(~reset),
        .pcm_valid(mic_valid),
        .pcm_sample(mic_data),
        .vowel_valid(vowel_valid),
        .f1_bin(f1_bin),
        .f2_bin(f2_bin),
        .spec_valid(spec_valid),
        .spec_col(spec_col)
    );

    // ---- Spectrogram column counter ----
    // spec_cnt counts spec_valid pulses; spec_seq already includes the pulse
    // in its own clk, so spec_seq and spec_col change in the same clk (no torn
    // {old seq, new column} value is offered to the link handshake).
    reg  [1:0] spec_cnt;
    wire [1:0] spec_seq = spec_cnt + {1'b0, spec_valid};
    always @(posedge clk or posedge reset) begin
        if (reset)           spec_cnt <= 2'd0;
        else if (spec_valid) spec_cnt <= spec_cnt + 2'd1;
    end

    // ---- Link protocol v4 ----
    assign f0_bundle     = {2'b00, f0_valid, f0_code, vowel_valid, f1_bin, f2_bin, 1'b0};
    assign status_bundle = 24'd0;   // unused from v4 on
    assign spec_bundle   = {spec_seq, spec_col};

    assign led[0] = ~f0_valid;
    assign led[1] = ~vowel_valid;
    assign led[2] = 1'b1;
    assign led[3] = 1'b1;

    wire [6:0] seg7_5, seg7_4, seg7_3, seg7_2;
    seg_decoder u_dec_5 (.bin_data({2'b00, f1_bin[5:4]}), .seg_data(seg7_5));
    seg_decoder u_dec_4 (.bin_data(f1_bin[3:0]),          .seg_data(seg7_4));
    seg_decoder u_dec_3 (.bin_data({1'b0, f2_bin[6:4]}),  .seg_data(seg7_3));
    seg_decoder u_dec_2 (.bin_data(f2_bin[3:0]),          .seg_data(seg7_2));

    assign seg_data_7 = 8'hff;
    assign seg_data_6 = 8'hff;
    assign seg_data_5 = vowel_valid ? {1'b1, seg7_5} : 8'hff;
    assign seg_data_4 = vowel_valid ? {1'b1, seg7_4} : 8'hff;
    assign seg_data_3 = vowel_valid ? {1'b1, seg7_3} : 8'hff;
    assign seg_data_2 = vowel_valid ? {1'b1, seg7_2} : 8'hff;
    assign seg_data_1 = 8'hff;
    assign seg_data_0 = 8'hff;
endmodule
