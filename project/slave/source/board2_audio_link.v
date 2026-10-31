// INMP441 left-channel receiver for the 16 kHz speech path (no resampling),
// plus the board2 -> main board link transmitter (board link protocol v4).
// mclk = 12.295082 MHz; SCK = mclk / 12 = 1.024590 MHz; WS = SCK / 64 = 16.0091 kHz.
// The microphone's internal decimation filter provides the anti-aliasing.
// CDC safety: hold_data changes at most once per WS frame (62.5 us) together with
// sample_toggle, which is far longer than the 3-flop toggle synchronizer latency in clk.
// Link: link_bclk / link_ws equal sck / ws (separate registers for IO packing);
// link_sd changes on falling SCK. The falling edge that sets frame_bit to k
// drives the bit sampled at E(k): k=0 previous right bit0, 1..32 left bit31..0,
// 33..63 right bit31..1. Both words are loaded when frame_bit goes 63 -> 0.
// Protocol v4: right word format selected by seq[0] (left word frame counter LSB):
//   seq[0]=0 (even frames): spectrogram slice
//     {2'b01, spec_m[257:256] (column seq), grp[3:0], spec_m[16*grp+15:16*grp]},
//     grp = mclk-domain counter, +1 per even frame (wraps), so one column
//     (16 slices) is sent every 32 frames (~2 ms) and repeated until replaced.
//   seq[0]=1 (odd frames):  f0_bundle (F0 pitch status, unchanged)
// spec_bundle and f0_bundle cross from clk to mclk by req/ack toggle handshake.
// status_bundle keeps its handshake but is no longer sent (v4); port kept.
module board2_audio_link #(
    parameter integer GAIN_SHIFT = 0   // 0..7
) (
    input  wire               mclk,
    input  wire               mclk_reset,   // active high, released synchronously to mclk
    input  wire               sd,
    output reg                sck,
    output reg                ws,
    output reg                link_bclk,
    output reg                link_ws,
    output reg                link_sd,
    input  wire               clk,          // 50 MHz core clock
    input  wire               reset,        // active high, released synchronously to clk
    output reg                sample_valid, // clk domain, single-cycle pulse
    output reg signed [15:0]  sample_data,  // clk domain, held during and after valid
    input  wire [23:0]        status_bundle,// clk domain, recognition status [31:8]
    input  wire [23:0]        f0_bundle,    // clk domain, F0 status [31:8]
    input  wire [257:0]       spec_bundle   // clk domain, {column seq, 64 x 4-bit column}
);

    // CRC-8/SMBUS (poly 0x07, init 0), 24 bits MSB first.
    function [7:0] crc8_24;
        input [23:0] d;
        integer i;
        reg [7:0] c;
        begin
            c = 8'h00;
            for (i = 23; i >= 0; i = i - 1)
                c = {c[6:0], 1'b0} ^ ((c[7] ^ d[i]) ? 8'h07 : 8'h00);
            crc8_24 = c;
        end
    endfunction

    // ------------------------------------------------------------------
    // mclk domain: SCK/WS generation and serial capture
    // ------------------------------------------------------------------
    reg [2:0]  half_count;
    reg [5:0]  frame_bit;
    reg sd_meta;
    (* async_reg = "true" *) reg sd_sync;
    reg [23:0] shift_data;
    reg [15:0] hold_data;
    reg        sample_toggle;

    // 24-bit word including the bit being consumed now, then gain + saturation.
    wire [23:0] word      = {shift_data[22:0], sd_sync};
    wire [31:0] word_ext  = {{8{word[23]}}, word};
    wire [31:0] word_gain = word_ext << GAIN_SHIFT;
    wire        word_ovf  = (word_gain[31:23] != {9{word_gain[31]}});
    wire [15:0] word_16   = word_ovf ? (word_gain[31] ? 16'h8000 : 16'h7fff)
                                     : word_gain[23:8];

    // Link transmitter state.
    reg [63:0] tx_shift;
    reg [7:0]  seq;
    reg [23:0] bundle_m;        // mclk domain, recognition status
    reg [23:0] f0_bundle_m;     // mclk domain, F0 status
    reg [257:0] spec_m;         // mclk domain, spectrogram column
    reg [3:0]  grp;             // mclk domain, slice index of the next even frame
    wire [23:0] left_payload = {hold_data, seq};

    // Right word payload: mux by seq[0]
    wire [23:0] spec_payload  = {2'b01, spec_m[257:256], grp, spec_m[{grp, 4'd0} +: 16]};
    wire [23:0] right_payload = seq[0] ? f0_bundle_m : spec_payload;

    // Status handshake, mclk side (for status_bundle).
    reg [23:0] bundle_hold;   // clk domain, stable while req != ack
    reg        req;           // clk domain
    reg        ack;
    (* async_reg = "true" *) reg req_s1;
    (* async_reg = "true" *) reg req_s2;
    (* async_reg = "true" *) reg req_s3;

    // F0 handshake, mclk side (for f0_bundle).
    reg [23:0] f0_hold;       // clk domain, stable while f0_req != f0_ack
    reg        f0_req;        // clk domain
    reg        f0_ack;
    (* async_reg = "true" *) reg f0_req_s1;
    (* async_reg = "true" *) reg f0_req_s2;
    (* async_reg = "true" *) reg f0_req_s3;

    // Spectrogram handshake, mclk side (for spec_bundle).
    reg [257:0] spec_hold;    // clk domain, stable while spec_req != spec_ack
    reg        spec_req;      // clk domain
    reg        spec_ack;
    (* async_reg = "true" *) reg spec_req_s1;
    (* async_reg = "true" *) reg spec_req_s2;
    (* async_reg = "true" *) reg spec_req_s3;

    always @(posedge mclk or posedge mclk_reset) begin
        if (mclk_reset) begin
            half_count    <= 3'd0;
            frame_bit     <= 6'd63;
            sck           <= 1'b0;
            ws            <= 1'b1;
            link_bclk     <= 1'b0;
            link_ws       <= 1'b1;
            link_sd       <= 1'b0;
            sd_meta       <= 1'b0;
            sd_sync       <= 1'b0;
            shift_data    <= 24'd0;
            hold_data     <= 16'd0;
            sample_toggle <= 1'b0;
            tx_shift      <= 64'd0;
            seq           <= 8'd0;
            bundle_m      <= 24'd0;
            f0_bundle_m   <= 24'd0;
            req_s1        <= 1'b0;
            req_s2        <= 1'b0;
            req_s3        <= 1'b0;
            ack           <= 1'b0;
            f0_req_s1     <= 1'b0;
            f0_req_s2     <= 1'b0;
            f0_req_s3     <= 1'b0;
            f0_ack        <= 1'b0;
            spec_m        <= 258'd0;
            grp           <= 4'd0;
            spec_req_s1   <= 1'b0;
            spec_req_s2   <= 1'b0;
            spec_req_s3   <= 1'b0;
            spec_ack      <= 1'b0;
        end else begin
            sd_meta <= sd;
            sd_sync <= sd_meta;

            req_s1 <= req;
            req_s2 <= req_s1;
            req_s3 <= req_s2;
            if (req_s2 ^ req_s3) begin
                bundle_m <= bundle_hold;
                ack      <= ~ack;
            end

            f0_req_s1 <= f0_req;
            f0_req_s2 <= f0_req_s1;
            f0_req_s3 <= f0_req_s2;
            if (f0_req_s2 ^ f0_req_s3) begin
                f0_bundle_m <= f0_hold;
                f0_ack      <= ~f0_ack;
            end

            spec_req_s1 <= spec_req;
            spec_req_s2 <= spec_req_s1;
            spec_req_s3 <= spec_req_s2;
            if (spec_req_s2 ^ spec_req_s3) begin
                spec_m   <= spec_hold;
                spec_ack <= ~spec_ack;
            end

            if (half_count == 3'd5) begin
                half_count <= 3'd0;
                sck       <= ~sck;
                link_bclk <= ~sck;
                if (sck) begin
                    // Falling SCK: bit 0 drives WS low (I2S one-bit delay),
                    // bits 1..24 carry left MSB..LSB, bit 32 drives WS high.
                    frame_bit <= frame_bit + 6'd1;
                    if (frame_bit == 6'd63) begin
                        ws      <= 1'b0;
                        link_ws <= 1'b0;
                    end else if (frame_bit == 6'd31) begin
                        ws      <= 1'b1;
                        link_ws <= 1'b1;
                    end
                    link_sd <= tx_shift[63];
                    if (frame_bit == 6'd63) begin
                        tx_shift <= {left_payload, crc8_24(left_payload),
                                     right_payload, crc8_24(right_payload)};
                        seq      <= seq + 8'd1;
                        if (!seq[0]) grp <= grp + 4'd1;
                    end else begin
                        tx_shift <= {tx_shift[62:0], 1'b0};
                    end
                end
            end else begin
                half_count <= half_count + 3'd1;
            end

            // Safe point: sd_sync now holds SD captured 2 mclk (163 ns) after SCK rise,
            // i.e. 8 mclk - tDD after the mic's falling-edge update and 4 mclk before the next one.
            if ((half_count == 3'd3) && sck &&
                (frame_bit >= 6'd1) && (frame_bit <= 6'd24)) begin
                shift_data <= word;
                if (frame_bit == 6'd24) begin
                    hold_data     <= word_16;
                    sample_toggle <= ~sample_toggle;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // clk domain: toggle synchronizer and output register
    // ------------------------------------------------------------------
    (* async_reg = "true" *) reg toggle_s1;
    (* async_reg = "true" *) reg toggle_s2;
    (* async_reg = "true" *) reg toggle_s3;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            toggle_s1    <= 1'b0;
            toggle_s2    <= 1'b0;
            toggle_s3    <= 1'b0;
            sample_valid <= 1'b0;
            sample_data  <= 16'sd0;
        end else begin
            toggle_s1    <= sample_toggle;
            toggle_s2    <= toggle_s1;
            toggle_s3    <= toggle_s2;
            sample_valid <= 1'b0;
            if (toggle_s2 ^ toggle_s3) begin
                sample_data  <= hold_data;
                sample_valid <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // clk domain: status handshake. A new value is taken only when the
    // previous one has been acknowledged, so the last value always gets sent.
    // ------------------------------------------------------------------
    (* async_reg = "true" *) reg ack_s1;
    (* async_reg = "true" *) reg ack_s2;
    (* async_reg = "true" *) reg ack_s3;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            ack_s1      <= 1'b0;
            ack_s2      <= 1'b0;
            ack_s3      <= 1'b0;
            req         <= 1'b0;
            bundle_hold <= 24'd0;
        end else begin
            ack_s1 <= ack;
            ack_s2 <= ack_s1;
            ack_s3 <= ack_s2;
            if ((req == ack_s3) && (status_bundle != bundle_hold)) begin
                bundle_hold <= status_bundle;
                req         <= ~req;
            end
        end
    end

    // ------------------------------------------------------------------
    // clk domain: F0 handshake. Same pattern as status_bundle.
    // ------------------------------------------------------------------
    (* async_reg = "true" *) reg f0_ack_s1;
    (* async_reg = "true" *) reg f0_ack_s2;
    (* async_reg = "true" *) reg f0_ack_s3;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            f0_ack_s1   <= 1'b0;
            f0_ack_s2   <= 1'b0;
            f0_ack_s3   <= 1'b0;
            f0_req      <= 1'b0;
            f0_hold     <= 24'd0;
        end else begin
            f0_ack_s1 <= f0_ack;
            f0_ack_s2 <= f0_ack_s1;
            f0_ack_s3 <= f0_ack_s2;
            if ((f0_req == f0_ack_s3) && (f0_bundle != f0_hold)) begin
                f0_hold <= f0_bundle;
                f0_req  <= ~f0_req;
            end
        end
    end

    // ------------------------------------------------------------------
    // clk domain: spectrogram handshake. Same pattern as status_bundle.
    // ------------------------------------------------------------------
    (* async_reg = "true" *) reg spec_ack_s1;
    (* async_reg = "true" *) reg spec_ack_s2;
    (* async_reg = "true" *) reg spec_ack_s3;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            spec_ack_s1 <= 1'b0;
            spec_ack_s2 <= 1'b0;
            spec_ack_s3 <= 1'b0;
            spec_req    <= 1'b0;
            spec_hold   <= 258'd0;
        end else begin
            spec_ack_s1 <= spec_ack;
            spec_ack_s2 <= spec_ack_s1;
            spec_ack_s3 <= spec_ack_s2;
            if ((spec_req == spec_ack_s3) && (spec_bundle != spec_hold)) begin
                spec_hold <= spec_bundle;
                spec_req  <= ~spec_req;
            end
        end
    end

endmodule
