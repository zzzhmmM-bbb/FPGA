`timescale 1ns/1ps

// Three relative-volume labels: quiet / medium / loud, at (64,360).
// Six fixed 16x16 Chinese glyphs sampled from Windows SimSun at size 16,
// rendered at 2x scale. No external font memory or video pipeline stage.
module audio_level_overlay24 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        enable,
    input  wire [1:0]  level,
    output wire [23:0] rgb_out
);
    reg [11:0] pixel_x;
    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    reg [1:0] frame_level;
    wire frame_start = vs_q && !vsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x <= 12'd0;
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
            frame_level <= 2'd0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            if (!vsync || !de)
                pixel_x <= 12'd0;
            else
                pixel_x <= pixel_x + 1'b1;
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;
            if (frame_start)
                frame_level <= level;
        end
    end

    function [15:0] glyph_row;
        input [2:0] glyph;
        input [3:0] row;
        begin
            case ({glyph,row})
                7'd0: glyph_row = 16'h0200;
                7'd1: glyph_row = 16'h0100;
                7'd2: glyph_row = 16'h3ffc;
                7'd3: glyph_row = 16'h2004;
                7'd4: glyph_row = 16'h4208;
                7'd5: glyph_row = 16'h0200;
                7'd6: glyph_row = 16'h0200;
                7'd7: glyph_row = 16'hfffe;
                7'd8: glyph_row = 16'h0420;
                7'd9: glyph_row = 16'h0820;
                7'd10: glyph_row = 16'h1840;
                7'd11: glyph_row = 16'h0640;
                7'd12: glyph_row = 16'h0180;
                7'd13: glyph_row = 16'h0260;
                7'd14: glyph_row = 16'h0c10;
                7'd15: glyph_row = 16'h7008;
                7'd16: glyph_row = 16'h1040;
                7'd17: glyph_row = 16'h1040;
                7'd18: glyph_row = 16'hfe78;
                7'd19: glyph_row = 16'h1088;
                7'd20: glyph_row = 16'h7c10;
                7'd21: glyph_row = 16'h11fc;
                7'd22: glyph_row = 16'hfe24;
                7'd23: glyph_row = 16'h0024;
                7'd24: glyph_row = 16'h7dfe;
                7'd25: glyph_row = 16'h4424;
                7'd26: glyph_row = 16'h7c24;
                7'd27: glyph_row = 16'h45fc;
                7'd28: glyph_row = 16'h7c24;
                7'd29: glyph_row = 16'h4420;
                7'd30: glyph_row = 16'h54a0;
                7'd31: glyph_row = 16'h4840;
                7'd32: glyph_row = 16'h0078;
                7'd33: glyph_row = 16'h23c0;
                7'd34: glyph_row = 16'h1040;
                7'd35: glyph_row = 16'h1040;
                7'd36: glyph_row = 16'h07fe;
                7'd37: glyph_row = 16'h0040;
                7'd38: glyph_row = 16'hf040;
                7'd39: glyph_row = 16'h13f8;
                7'd40: glyph_row = 16'h1208;
                7'd41: glyph_row = 16'h1208;
                7'd42: glyph_row = 16'h1208;
                7'd43: glyph_row = 16'h13f8;
                7'd44: glyph_row = 16'h1208;
                7'd45: glyph_row = 16'h2800;
                7'd46: glyph_row = 16'h47fe;
                7'd47: glyph_row = 16'h0000;
                7'd48: glyph_row = 16'h0100;
                7'd49: glyph_row = 16'h0100;
                7'd50: glyph_row = 16'h0100;
                7'd51: glyph_row = 16'h0100;
                7'd52: glyph_row = 16'h3ff8;
                7'd53: glyph_row = 16'h2108;
                7'd54: glyph_row = 16'h2108;
                7'd55: glyph_row = 16'h2108;
                7'd56: glyph_row = 16'h2108;
                7'd57: glyph_row = 16'h2108;
                7'd58: glyph_row = 16'h3ff8;
                7'd59: glyph_row = 16'h2108;
                7'd60: glyph_row = 16'h0100;
                7'd61: glyph_row = 16'h0100;
                7'd62: glyph_row = 16'h0100;
                7'd63: glyph_row = 16'h0100;
                7'd64: glyph_row = 16'h2040;
                7'd65: glyph_row = 16'h2020;
                7'd66: glyph_row = 16'h2020;
                7'd67: glyph_row = 16'hfdfe;
                7'd68: glyph_row = 16'h4000;
                7'd69: glyph_row = 16'h5088;
                7'd70: glyph_row = 16'h9104;
                7'd71: glyph_row = 16'hfe02;
                7'd72: glyph_row = 16'h1088;
                7'd73: glyph_row = 16'h1088;
                7'd74: glyph_row = 16'h1c50;
                7'd75: glyph_row = 16'hf050;
                7'd76: glyph_row = 16'h5020;
                7'd77: glyph_row = 16'h1050;
                7'd78: glyph_row = 16'h1088;
                7'd79: glyph_row = 16'h1306;
                7'd80: glyph_row = 16'h0040;
                7'd81: glyph_row = 16'h0040;
                7'd82: glyph_row = 16'h7880;
                7'd83: glyph_row = 16'h4bfc;
                7'd84: glyph_row = 16'h4a04;
                7'd85: glyph_row = 16'h4a04;
                7'd86: glyph_row = 16'h4af4;
                7'd87: glyph_row = 16'h4a94;
                7'd88: glyph_row = 16'h4a94;
                7'd89: glyph_row = 16'h4a94;
                7'd90: glyph_row = 16'h7a94;
                7'd91: glyph_row = 16'h4af4;
                7'd92: glyph_row = 16'h0204;
                7'd93: glyph_row = 16'h0204;
                7'd94: glyph_row = 16'h0214;
                7'd95: glyph_row = 16'h0208;
                default: glyph_row = 16'h0000;
            endcase
        end
    endfunction

    wire right_char = (pixel_x >= 12'd100);
    wire [11:0] char_x = right_char ? pixel_x - 12'd100 : pixel_x - 12'd64;
    wire [11:0] char_y = line_y - 12'd360;
    wire [2:0] glyph_index = {frame_level, right_char};
    wire [15:0] glyph_bits = glyph_row(glyph_index, char_y[4:1]);
    wire glyph_hit = rst_n && enable && de &&
                     (line_y >= 12'd360) && (line_y < 12'd392) &&
                     (((pixel_x >= 12'd64) && (pixel_x < 12'd96)) ||
                      ((pixel_x >= 12'd100) && (pixel_x < 12'd132))) &&
                     glyph_bits[4'd15-char_x[4:1]];
    wire [23:0] text_rgb = (frame_level == 2'd0) ? 24'h20ff90 :
                          (frame_level == 2'd1) ? 24'hffdf40 : 24'hff6040;
    assign rgb_out = glyph_hit ? text_rgb : rgb_in;
endmodule
