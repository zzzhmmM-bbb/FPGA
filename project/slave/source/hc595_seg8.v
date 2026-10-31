// 8-digit 7-seg dynamic scan through two cascaded 74HC595 (AC201 board).
// Timing and polarity follow the board example HEX8.v + HC595_Driver.v:
//   16-bit word {seg[7:0], sel[7:0]} shifted MSB first, SCLK = clk / 10,
//   one word per 32 x 5 clk, RCLK pulses high while the next word starts.
//   seg: active low, bit7 = DP (same as v15 codes, no conversion needed).
//   sel: active high one-hot, sel[i] = SEL i.
// seg_data_i drives SEL i. SEL7 is assumed to be the leftmost digit and SEL0
// the rightmost (inferred from the schematic, not checked on the PCB).
// The word is reloaded only at a frame boundary, so a digit change never
// tears a frame.
module hc595_seg8 #(
    parameter integer DIGIT_CYCLES = 50000   // clk cycles per digit (1 ms at 50 MHz)
) (
    input  wire       clk,
    input  wire       reset,
    input  wire [7:0] seg_data_0,
    input  wire [7:0] seg_data_1,
    input  wire [7:0] seg_data_2,
    input  wire [7:0] seg_data_3,
    input  wire [7:0] seg_data_4,
    input  wire [7:0] seg_data_5,
    input  wire [7:0] seg_data_6,
    input  wire [7:0] seg_data_7,
    output reg        seg7_sclk,
    output reg        seg7_rclk,
    output reg        seg7_dio
);
    localparam integer CNT_MAX = 4;

    reg [31:0] digit_timer;
    reg [2:0]  digit;
    reg [2:0]  div_cnt;
    reg [4:0]  edge_cnt;
    reg [15:0] r_data;

    reg [7:0] seg_cur;
    always @(*) begin
        case (digit)
            3'd0: seg_cur = seg_data_0;
            3'd1: seg_cur = seg_data_1;
            3'd2: seg_cur = seg_data_2;
            3'd3: seg_cur = seg_data_3;
            3'd4: seg_cur = seg_data_4;
            3'd5: seg_cur = seg_data_5;
            3'd6: seg_cur = seg_data_6;
            default: seg_cur = seg_data_7;
        endcase
    end

    wire step = (div_cnt == CNT_MAX);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            digit_timer <= 32'd0;
            digit       <= 3'd0;
        end else if (digit_timer == DIGIT_CYCLES - 1) begin
            digit_timer <= 32'd0;
            digit       <= digit + 3'd1;
        end else begin
            digit_timer <= digit_timer + 32'd1;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            div_cnt  <= 3'd0;
            edge_cnt <= 5'd0;
            r_data   <= 16'hff00;
        end else if (step) begin
            div_cnt  <= 3'd0;
            edge_cnt <= edge_cnt + 5'd1;
            if (edge_cnt == 5'd31)
                r_data <= {seg_cur, 8'b0000_0001 << digit};
        end else begin
            div_cnt <= div_cnt + 3'd1;
        end
    end

    // Same state table as HC595_Driver: even states drop SCLK and present the
    // next bit, odd states raise SCLK; RCLK is high during state 0.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            seg7_sclk <= 1'b0;
            seg7_rclk <= 1'b0;
            seg7_dio  <= 1'b0;
        end else begin
            seg7_sclk <= edge_cnt[0];
            seg7_rclk <= (edge_cnt == 5'd0);
            if (!edge_cnt[0])
                seg7_dio <= r_data[5'd15 - edge_cnt[4:1]];
        end
    end
endmodule
