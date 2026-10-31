`timescale 1ns/1ps
// STEP-1 isolated interface budget. One pending sample survives pause.
module hdmi_audio_tone_i2s_64fs #(
    parameter [31:0] PHASE_INC = 32'd39370534, // Legacy parameter, score controls pitch.
    parameter signed [23:0] AMP = 24'sd2000000,
    parameter integer NOTE_HOLD_FRAMES = 144000 // Legacy parameter, score controls duration.
)(
    input wire I_mclk,
    input wire I_rst,
    input wire I_song, // registered video-domain scene level
    input wire I_pause, // video-domain level; synchronized here, no pulse CDC.
    output reg O_i2s_BCLK,
    output reg O_i2s_LRCK,
    output reg O_i2s_DOUT
);
    (* async_reg = "true" *) reg S_pause_meta, S_pause_sync;
    reg S_pause_frame;
    (* async_reg = "true" *) reg S_song_meta, S_song_sync;
    reg S_song_frame;
    wire W_song_ready;
    reg [5:0] S_bit_cnt;
    reg [63:0] S_shift_reg;
    reg signed [23:0] S_sample_word;
    wire signed [23:0] W_pending_pcm;
    wire signed [23:0] W_pcm = (S_pause_frame || !W_song_ready) ? 24'sd0 : W_pending_pcm;
    // Request next sample while loading the previously completed sample.
    // 256 clocks/request; load follows by 2 clocks, thus one frame of latency.
    // Pause mutes externally and holds the pending sample for exact continuation.
    wire W_sample_ce = O_i2s_BCLK && O_i2s_LRCK && S_bit_cnt == 6'd62;
    forest_linear_budget #(.HOLD_PCM_ON_PAUSE(1)) u_score (
        .clk(I_mclk), .rst(I_rst), .sample_ce(W_sample_ce),
        .pause(S_pause_frame), .song(S_song_frame), .song_ready(W_song_ready), .pcm(W_pending_pcm), .busy()
    );

    always @(posedge I_mclk or posedge I_rst) begin
        if (I_rst) begin
            S_song_meta <= 1'b0;
            S_song_sync <= 1'b0;
            S_pause_meta <= 1'b1;
            S_pause_sync <= 1'b1;
        end else begin
            S_song_meta <= I_song;
            S_song_sync <= S_song_meta;
            S_pause_meta <= I_pause;
            S_pause_sync <= S_pause_meta;
        end
    end

    always @(posedge I_mclk or posedge I_rst) begin
        if (I_rst) begin
            O_i2s_BCLK <= 1'b0;
            O_i2s_LRCK <= 1'b0;
            O_i2s_DOUT <= 1'b0;
            S_bit_cnt <= 6'd0;
            S_shift_reg <= 64'd0;
            S_sample_word <= 24'sd0;
            S_song_frame <= 1'b0;
            S_pause_frame <= 1'b1;
        end else begin
            // Exact T1 clock edges, 64 BCLKs/channel, 256 mclk edges/stereo frame.
            O_i2s_BCLK <= ~O_i2s_BCLK;
            if (O_i2s_BCLK == 1'b1) begin
                O_i2s_DOUT <= S_shift_reg[63];
                S_shift_reg <= {S_shift_reg[62:0], 1'b0};
                if (O_i2s_LRCK && S_bit_cnt == 6'd61) begin
                    S_pause_frame <= S_pause_sync;
                    S_song_frame <= S_song_sync;
                end
                if (S_bit_cnt == 6'd63) begin
                    S_bit_cnt <= 6'd0;
                    if (O_i2s_LRCK == 1'b0) begin
                        O_i2s_LRCK <= 1'b1;
                        S_shift_reg <= {S_sample_word[23:0], 40'd0};
                    end else begin
                        O_i2s_LRCK <= 1'b0;
                        S_sample_word <= W_pcm;
                        S_shift_reg <= {W_pcm[23:0], 40'd0};
                    end
                end else begin
                    S_bit_cnt <= S_bit_cnt + 6'd1;
                end
            end
        end
    end
endmodule
