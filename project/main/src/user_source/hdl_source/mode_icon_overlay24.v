`timescale 1ns/1ps
// Cover page play-mode icon, drawn inside the box x 584..615, y 16..47
// (the TF background has a white disc there, centre (600,32), d ~ 42 px).
//   auto_mode = 1: green solid right-pointing triangle,
//                  vertices ~ (595,23), (595,40), (608,31.5)
//   auto_mode = 0: orange pause bars, x 593..596 and x 603..606, y 23..40
// Selected dwell (4s / 8s / 12s) is transparent text centred at (549.5,44.5)
// inside the cloud, left of the icon. Auto and manual show the configured value.
// Every other pixel passes rgb_in through.
// Coordinates are counted from vsync/de (same scheme as level_focus_overlay24);
// enable/auto_mode are latched at frame start. Zero clocks of pixel latency.
module mode_icon_overlay24 #(
    parameter [23:0] PLAY_COLOR  = 24'h2FBF71,
    parameter [23:0] PAUSE_COLOR = 24'hFF963C
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        enable,
    input  wire        auto_mode,
    input  wire [1:0]  period_index,
    output wire [23:0] rgb_out
);
    // ---------------- Coordinate generation (from vsync/de) ----------------
    // 640 active pixels; drawing ends at row 51, so saturate y at 63.
    reg [9:0] pixel_x;
    reg [5:0] line_y;
    reg de_q, vs_q;
    wire frame_start = vs_q && !vsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x <= 12'd0;
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync || !de)
                pixel_x <= 12'd0;
            else
                pixel_x <= pixel_x + 1'b1;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de && !(&line_y))
                line_y <= line_y + 1'b1;
        end
    end

    // ---------------- Frame-boundary latch ----------------
    reg enable_l, auto_l;
    reg [1:0] period_l;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_l <= 1'b0;
            auto_l   <= 1'b0;
            period_l <= 2'd0;
        end else if (frame_start) begin
            enable_l <= enable;
            auto_l   <= auto_mode;
            period_l <= period_index;
        end
    end

    // ---------------- Shapes ----------------
    wire in_box  = (pixel_x >= 12'd584) && (pixel_x <= 12'd615) &&
                   (line_y  >= 12'd16)  && (line_y  <= 12'd47);
    wire in_rows = (line_y >= 12'd23) && (line_y <= 12'd40);

    // Exact raster of (x-595)*17 <= 26*min(y-23,40-y).
    // A row limit avoids the previous wide subtractors and multipliers.
    reg [3:0] triangle_width;
    always @(*) begin
        case (line_y[5:0])
            6'd23, 6'd40: triangle_width = 4'd0;
            6'd24, 6'd39: triangle_width = 4'd1;
            6'd25, 6'd38: triangle_width = 4'd3;
            6'd26, 6'd37: triangle_width = 4'd4;
            6'd27, 6'd36: triangle_width = 4'd6;
            6'd28, 6'd35: triangle_width = 4'd7;
            6'd29, 6'd34: triangle_width = 4'd9;
            6'd30, 6'd33: triangle_width = 4'd10;
            6'd31, 6'd32: triangle_width = 4'd12;
            default: triangle_width = 4'd0;
        endcase
    end
    wire [3:0] dx = pixel_x[3:0] - 4'd3; // x - 595, valid inside tri_x_ok
    wire        tri_x_ok = (pixel_x >= 12'd595) && (pixel_x <= 12'd608);
    wire play_hit = in_rows && tri_x_ok && (dx <= triangle_width);

    wire pause_hit = in_rows &&
                     (((pixel_x >= 12'd593) && (pixel_x <= 12'd596)) ||
                      ((pixel_x >= 12'd603) && (pixel_x <= 12'd606)));

    wire draw = enable_l && de && in_box && (auto_l ? play_hit : pause_hit);

    // Three 16-pixel character cells, 5x7 font at 2x scale.
    // Shift the two-character values left by half a cell to keep their centre
    // aligned with 12s. Only glyph pixels replace the incoming cloud pixels.
    wire [5:0] text_x = pixel_x[5:0] - ((period_l == 2'd2) ? 6'd17 : 6'd9);
    wire [3:0] text_y = line_y[3:0] - 4'd6;  // y - 38, gated below
    // Read a 5-bit row, avoiding a wide bitmap and variable 35-bit selector.
    function [4:0] digit_row(input [2:0] row, input [1:0] digit);
        begin
            digit_row = 5'd0;
            case ({digit,row}) // 0=1, 1=4, 2=8, 3=2
                5'b00_000: digit_row=5'b00100;
                5'b00_001: digit_row=5'b01100;
                5'b00_010,5'b00_011,5'b00_100,5'b00_101: digit_row=5'b00100;
                5'b00_110: digit_row=5'b01110;
                5'b01_000,5'b01_101,5'b01_110: digit_row=5'b00010;
                5'b01_001: digit_row=5'b00110;
                5'b01_010: digit_row=5'b01010;
                5'b01_011: digit_row=5'b10010;
                5'b01_100: digit_row=5'b11111;
                5'b10_000,5'b10_011,5'b10_110: digit_row=5'b01110;
                5'b10_001,5'b10_010,5'b10_100,5'b10_101: digit_row=5'b10001;
                5'b11_000: digit_row=5'b01110;
                5'b11_001: digit_row=5'b10001;
                5'b11_010: digit_row=5'b00001;
                5'b11_011: digit_row=5'b00010;
                5'b11_100: digit_row=5'b00100;
                5'b11_101: digit_row=5'b01000;
                5'b11_110: digit_row=5'b11111;
                default: digit_row=5'd0;
            endcase
        end
    endfunction
    reg [4:0] font_row;
    wire [1:0] digit = (text_x[5:4] == 2'd0) ? 2'd0 :
                      (period_l == 2'd1) ? 2'd2 :
                      (period_l == 2'd2) ? 2'd3 : 2'd1;
    always @(*) begin
        font_row = 5'd0;
        if (text_x[5:4] == 2'd2) begin
            case (text_y[3:1])
                3'd2: font_row=5'b01111;
                3'd3: font_row=5'b10000;
                3'd4: font_row=5'b01110;
                3'd5: font_row=5'b00001;
                3'd6: font_row=5'b11110;
                default: font_row=5'd0;
            endcase
        end else if ((text_x[5:4] == 2'd1) ||
                     ((text_x[5:4] == 2'd0) && (period_l == 2'd2)))
            font_row = digit_row(text_y[3:1], digit);
    end
    wire text_area = (pixel_x >= 12'd529) && (pixel_x < 12'd571) &&
                     (line_y >= 12'd38) && (line_y < 12'd52) &&
                     (text_x[3:1] < 3'd5);
    wire text_hit = text_area && font_row[3'd4 - text_x[3:1]];
    assign rgb_out = draw ? (auto_l ? PLAY_COLOR : PAUSE_COLOR) :
                     (enable_l && de && text_hit) ? 24'h293455 : rgb_in;

endmodule
