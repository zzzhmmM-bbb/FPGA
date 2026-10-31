// Board2 link receiver (board link protocol v2), oversampled in clk domain.
module board2_link_rx #(
    parameter integer CLK_HZ = 25_000_000
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               link_bclk,
    input  wire               link_ws,
    input  wire               link_sd,
    output reg                sample_valid,
    output reg signed [23:0]  sample_data,
    output reg                link_up,
    output reg  [1:0]         remote_phase,
    output reg                remote_have_result,
    output reg  [1:0]         remote_code,
    output reg                remote_accepted,
    output reg                remote_error,
    output reg  [2:0]         remote_counter,
    output reg  [13:0]        remote_cost,
    output reg                f0_valid,
    output reg  [5:0]         f0_code,
    output reg                vowel_valid,
    output wire               vowel_fresh,
    output reg  [5:0]         f1_bin,
    output reg  [6:0]         f2_bin,
    // Protocol v4: one spectrogram group per accepted even-frame right word
    output reg                spec_grp_valid,
    output reg  [1:0]         spec_seq,
    output reg  [3:0]         spec_grp,
    output reg  [15:0]        spec_mag
);
    localparam integer LINK_CYCLES = CLK_HZ / 250;   // 4 ms
    localparam integer LW = $clog2(LINK_CYCLES + 1);
    localparam [LW-1:0] LINK_MAX = LINK_CYCLES;

    // Independent vowel-field age; unrelated words cannot keep this alive.
    localparam integer FIELD_CYCLES = (CLK_HZ + 249) / 250;
    localparam integer FW = (FIELD_CYCLES < 2) ? 1 : $clog2(FIELD_CYCLES + 1);
    localparam [FW-1:0] FIELD_MAX = FIELD_CYCLES;
    reg [FW-1:0] field_remaining;
    assign vowel_fresh = |field_remaining;
    // Diagnostic age has the original 0..T contract; unused logic prunes in
    // synthesis. A down-counter avoids a wide saturated compare/load mux.
    wire [FW-1:0] vowel_age = FIELD_MAX - field_remaining;
    // Compressed same-frame metadata: seen && CRC correct && odd sequence.
    reg vowel_left_qualified;

    function [7:0] crc8_24;
        input [23:0] d;
        integer k;
        reg [7:0] c;
        begin
            c = 8'h00;
            for (k = 23; k >= 0; k = k - 1)
                c = {c[6:0], 1'b0} ^ ((c[7] ^ d[k]) ? 8'h07 : 8'h00);
            crc8_24 = c;
        end
    endfunction

    // Two-stage synchronizers; no async_reg on the pin-facing stage (TD SYN-5011).
    reg bclk_m, bclk_s, ws_m, ws_s, sd_m, sd_s;
    reg [2:0] bclk_hist;
    reg bclk_f;
    wire [2:0] bclk_next = {bclk_hist[1:0], bclk_s};
    wire bclk_rise = !bclk_f && (bclk_next == 3'b111);

    reg ws_prev;
    reg in_sync;
    reg [5:0] bit_cnt;          // index of the last edge (E0 = 0)
    reg [31:0] left_shift;
    reg [30:0] right_shift;
    reg left_ready, right_ready;
    reg [31:0] left_word, right_word;
    reg [LW-1:0] idle_cnt;

    wire is_e0 = ws_prev && !ws_s;
    wire left_ok  = crc8_24(left_word[31:8])  == left_word[7:0];
    wire right_ok = crc8_24(right_word[31:8]) == right_word[7:0];

    wire any_good_word = (left_ready && left_ok) || (right_ready && right_ok);
    wire stream_timeout = !any_good_word && (idle_cnt >= LINK_CYCLES - 1);
    wire lost_frame = bclk_rise && in_sync &&
        ((is_e0 && bit_cnt != 6'd63) || (!is_e0 && bit_cnt == 6'd63));
    wire vowel_accept = right_ready && !left_ready && right_ok &&
                        vowel_left_qualified && in_sync && !lost_frame;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bclk_m <= 1'b0; bclk_s <= 1'b0;
            ws_m <= 1'b0;   ws_s <= 1'b0;
            sd_m <= 1'b0;   sd_s <= 1'b0;
            bclk_hist <= 3'b000;
            bclk_f <= 1'b0;
            ws_prev <= 1'b0;
            in_sync <= 1'b0;
            bit_cnt <= 6'd0;
            left_shift <= 32'd0;
            right_shift <= 31'd0;
            left_ready <= 1'b0;
            right_ready <= 1'b0;
            left_word <= 32'd0;
            right_word <= 32'd0;
            idle_cnt <= LINK_MAX;
            link_up <= 1'b0;
            sample_valid <= 1'b0;
            sample_data <= 24'sd0;
            remote_phase <= 2'd0;
            remote_have_result <= 1'b0;
            remote_code <= 2'd3;
            remote_accepted <= 1'b0;
            remote_error <= 1'b0;
            remote_counter <= 3'd0;
            remote_cost <= 14'd0;
            f0_valid <= 1'b0;
            f0_code <= 6'd0;
            vowel_valid <= 1'b0;
            field_remaining <= {FW{1'b0}};
            vowel_left_qualified <= 1'b0;
            f1_bin <= 6'd0;
            f2_bin <= 7'd0;
            spec_grp_valid <= 1'b0;
            spec_seq <= 2'd0;
            spec_grp <= 4'd0;
            spec_mag <= 16'd0;
        end else begin
            bclk_m <= link_bclk; bclk_s <= bclk_m;
            ws_m <= link_ws;     ws_s <= ws_m;
            sd_m <= link_sd;     sd_s <= sd_m;

            // 3-sample agreement filter on BCLK.
            bclk_hist <= bclk_next;
            if (bclk_next == 3'b111) bclk_f <= 1'b1;
            else if (bclk_next == 3'b000) bclk_f <= 1'b0;

            left_ready <= 1'b0;
            right_ready <= 1'b0;
            sample_valid <= 1'b0;
            spec_grp_valid <= 1'b0;

            if (bclk_rise) begin
                ws_prev <= ws_s;
                if (is_e0) begin
                    // Right word completes with its bit0 at E0 of the next frame.
                    if (in_sync && bit_cnt == 6'd63) begin
                        right_word <= {right_shift, sd_s};
                        right_ready <= 1'b1;
                    end
                    in_sync <= 1'b1;
                    bit_cnt <= 6'd0;
                end else if (in_sync) begin
                    if (bit_cnt == 6'd63) begin
                        in_sync <= 1'b0;          // 64 edges without E0: lost sync
                    end else begin
                        bit_cnt <= bit_cnt + 6'd1;
                        if (bit_cnt <= 6'd31) begin
                            left_shift <= {left_shift[30:0], sd_s};
                            if (bit_cnt == 6'd31) begin
                                left_word <= {left_shift[30:0], sd_s};
                                left_ready <= 1'b1;
                            end
                        end else begin
                            right_shift <= {right_shift[29:0], sd_s};
                        end
                    end
                end
            end

            if (left_ready && left_ok) begin
                sample_valid <= 1'b1;
                sample_data <= {left_word[31:16], 8'h00};
            end
            if (right_ready && right_ok) begin
                // Protocol v2: right word format selected by left_word[8] (seq[0])
                if (left_word[8]) begin
                    // seq[0]=1: F0 frame
                    f0_valid <= right_word[29];
                    f0_code  <= right_word[28:23];
                    // Protocol v3: formants in 31.25 Hz bins (old board2: all 0)
                    // Vowel fields use the stricter paired acceptance below.
                    // F0 keeps its original protocol/timing for level 2.
                end else begin
                    // seq[0]=0: recognition frame (original format)
                    remote_phase <= right_word[31:30];
                    remote_have_result <= right_word[29];
                    remote_code <= right_word[28:27];
                    remote_accepted <= right_word[26];
                    remote_error <= right_word[25];
                    remote_counter <= right_word[24:22];
                    remote_cost <= right_word[21:8];
                    // Protocol v4: [31:30]=01 marks a spectrogram group
                    // (old board2 sends all 0 here, marker 00: ignored)
                    if (right_word[31:30] == 2'b01) begin
                        spec_grp_valid <= 1'b1;
                        spec_seq <= right_word[29:28];
                        spec_grp <= right_word[27:24];
                        spec_mag <= right_word[23:8];
                    end
                end
            end

            // A right word finishes at E0 and is consumed one clk later.
            // Do not clear its left metadata at the E0 capture edge.
            if (left_ready) vowel_left_qualified <= left_ok && left_word[8];
            if (right_ready || !in_sync || lost_frame || stream_timeout)
                vowel_left_qualified <= 1'b0;

            if (vowel_accept) begin
                vowel_valid <= right_word[22];
                f1_bin <= right_word[21:16];
                f2_bin <= right_word[15:9];
                field_remaining <= FIELD_MAX;
            end else if (!in_sync || lost_frame || stream_timeout) begin
                field_remaining <= {FW{1'b0}};
            end else if (vowel_fresh) begin
                field_remaining <= field_remaining - 1'b1;
            end

            if ((left_ready && left_ok) || (right_ready && right_ok)) begin
                idle_cnt <= {LW{1'b0}};
                link_up <= 1'b1;
            end else if (idle_cnt >= LINK_CYCLES - 1) begin
                idle_cnt <= LINK_MAX;
                link_up <= 1'b0;
            end else begin
                idle_cnt <= idle_cnt + 1'b1;
            end
        end
    end
endmodule
