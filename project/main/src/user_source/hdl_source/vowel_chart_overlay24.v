`timescale 1ns/1ps
// Vowel chart overlay (level 3): F2 on the x axis (front vowels left), F1 on
// the y axis (close vowels top), six target boxes with 5x7 labels (2x), the
// live formant point and a 16-point trail.
// Inputs (link protocol v3): f1_bin / f2_bin in 31.25 Hz bins, vowel_valid.
// Mapping (bins clamped first, no division):
//   x = 128 + (83 - f2c) * 6   f2c in 19..83  (594..2594 Hz)  x 128..512
//   y =  64 + (f1c -  6) * 8   f1c in  6..32  (187..1000 Hz)  y  64..272
// All inputs are latched at frame start; the point, trail and nearest-target
// registers are then updated in a few clocks of vertical blanking.
// Trail: each lattice point sits on a 6 px column grid and an 8 px row grid,
// so the trail is stored as (column, row) indices and compared by equality
// against running per-pixel column / per-line row counters (no 12-bit range
// compares for the 16 trail entries).
// Nearest target: 8*|df1| + 6*|df2| (bins), i.e. Manhattan distance in screen
// pixels; ties go to the lower index (a, e, o, u, i, yu).
// Zero clocks of pixel latency (combinational mux).
module vowel_chart_overlay24 #(
    parameter integer ENTER_RADIUS = 2,
    parameter integer KEEP_RADIUS  = 3
) (
    input  wire        clk, rst_n, vsync, de,
    input  wire [23:0] rgb_in,
    input  wire        enable,
    input  wire        vowel_valid,
    input  wire [5:0]  f1_bin,
    input  wire [6:0]  f2_bin,
    input  wire        target_en,
    input  wire [2:0]  target_id,
    input  wire        target_blink,
    input  wire [5:0]  hold_progress,
    input  wire        hold_progress_en,
    input  wire [1:0]  hold_phase,
    output wire [23:0] rgb_out
);
    localparam [23:0] C_PANEL = 24'h0A0D12;
    localparam [23:0] C_POINT = 24'h38BDF8;
    localparam [23:0] C_TRAIL = 24'h1E6A8C;
    localparam [23:0] C_NEAR  = 24'hFFFFFF;
    localparam [23:0] C_GOLD  = 24'hFFD200;
    localparam [23:0] C_TGT   = 24'hB0C0D0;

    localparam integer PX0 = 112, PX1 = 527, PY0 = 52, PY1 = 283;

    // Target bins (Hz / 31.25, rounded) and screen centres.
    localparam integer A_F1 = 26, A_F2 = 40;   // a  820 / 1240 Hz
    localparam integer E_F1 = 17, E_F2 = 37;   // e  535 / 1170 Hz
    localparam integer O_F1 = 20, O_F2 = 30;   // o  620 /  940 Hz
    localparam integer U_F1 = 12, U_F2 = 23;   // u  390 /  705 Hz
    localparam integer I_F1 = 10, I_F2 = 76;   // i  310 / 2380 Hz
    localparam integer Y_F1 = 10, Y_F2 = 69;   // yu 310 / 2160 Hz
    localparam integer A_X = 128 + (83 - A_F2) * 6, A_Y = 64 + (A_F1 - 6) * 8;
    localparam integer E_X = 128 + (83 - E_F2) * 6, E_Y = 64 + (E_F1 - 6) * 8;
    localparam integer O_X = 128 + (83 - O_F2) * 6, O_Y = 64 + (O_F1 - 6) * 8;
    localparam integer U_X = 128 + (83 - U_F2) * 6, U_Y = 64 + (U_F1 - 6) * 8;
    localparam integer I_X = 128 + (83 - I_F2) * 6, I_Y = 64 + (I_F1 - 6) * 8;
    localparam integer Y_X = 128 + (83 - Y_F2) * 6, Y_Y = 64 + (Y_F1 - 6) * 8;

    // ---------------- Coordinate generation (from vsync/de) ----------------
    reg [9:0] pixel_x, line_y;
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
            if (!vsync || !de) begin
                pixel_x <= 12'd0;
            end else begin
                pixel_x <= pixel_x + 1'b1;
            end
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;
        end
    end

    // Lattice counters, advanced together with pixel_x / line_y:
    //   col_q = pixel_x / 6, col_p = pixel_x % 6
    //   row_q = (line_y - 14) / 8 (mod 64), row_p = (line_y - 14) % 8
    //   (row_q starts at 62 = -2, row_p at 2 on line 0; row_q = 0 from line 14)
    // Trail square of column index c covers x = 6c .. 6c+3 (centre 6c+2),
    // of row index r covers y = 8r+14 .. 8r+17 (centre 8r+16 = 64 + (r-6)*8).
    reg [6:0] col_q;
    reg [2:0] col_p;
    reg [5:0] row_q;
    reg [2:0] row_p;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_q <= 7'd0; col_p <= 3'd0;
            row_q <= 6'd62; row_p <= 3'd2;
        end else begin
            if (!vsync || !de) begin
                col_q <= 7'd0; col_p <= 3'd0;
            end else if (col_p == 3'd5) begin
                col_q <= col_q + 1'b1; col_p <= 3'd0;
            end else begin
                col_p <= col_p + 1'b1;
            end
            if (!vsync) begin
                row_q <= 6'd62; row_p <= 3'd2;
            end else if (de_q && !de) begin
                if (row_p == 3'd7) begin
                    row_q <= row_q + 1'b1; row_p <= 3'd0;
                end else begin
                    row_p <= row_p + 1'b1;
                end
            end
        end
    end

    // ---------------- Frame-boundary latch ----------------
    reg       enable_l, valid_l;
    reg progress_en_l;
    reg [5:0] progress_l;
    reg [5:0] f1_l;
    reg [6:0] f2_l;
    reg       st1, st2, st3;
    reg       tgt_en_l, tgt_blink_l;
    reg [2:0] tgt_id_l;
    reg [1:0] phase_l;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_l <= 1'b0;
            progress_en_l <= 1'b0; progress_l <= 6'd0;
            valid_l  <= 1'b0;
            f1_l     <= 6'd0;
            f2_l     <= 7'd0;
            st1 <= 1'b0; st2 <= 1'b0; st3 <= 1'b0;
            tgt_en_l <= 1'b0; tgt_blink_l <= 1'b0; tgt_id_l <= 3'd0;
            phase_l  <= 2'b00;
        end else begin
            st1 <= frame_start;
            st2 <= st1;
            st3 <= st2;
            if (frame_start) begin
                enable_l <= enable;
                progress_en_l <= hold_progress_en; progress_l <= hold_progress;
                valid_l  <= vowel_valid;
                f1_l     <= f1_bin;
                f2_l     <= f2_bin;
                tgt_en_l    <= target_en;
                tgt_id_l    <= target_id;
                tgt_blink_l <= target_blink;
                phase_l     <= hold_phase;
            end
        end
    end

    // ---------------- Blanking-time pipeline ----------------
    // st1: clamp, map to screen, distances. st2: trail push, pairwise min.
    // st3: final nearest target.
    wire [5:0] f1c = (f1_l < 6'd6) ? 6'd6 : (f1_l > 6'd32) ? 6'd32 : f1_l;
    wire [6:0] f2c = (f2_l < 7'd19) ? 7'd19 : (f2_l > 7'd83) ? 7'd83 : f2_l;
    wire [6:0] k2  = 7'd83 - f2c;                  // 0..64
    wire [5:0] k1  = f1c - 6'd6;                   // 0..26
    wire [11:0] map_x = 12'd128 + {3'd0, k2, 2'b00} + {4'd0, k2, 1'b0};
    wire [11:0] map_y = 12'd64 + {3'd0, k1, 3'b000};
    wire [6:0] map_col = 7'd104 - f2c;             // (map_x - 2) / 6
    wire [5:0] map_row = f1c;                      // (map_y - 16) / 8

    function [10:0] tgt_dist;
        input [5:0] a1; input [6:0] a2;
        input [5:0] t1; input [6:0] t2;
        reg [5:0] e1; reg [6:0] e2;
        begin
            e1 = (a1 >= t1) ? (a1 - t1) : (t1 - a1);
            e2 = (a2 >= t2) ? (a2 - t2) : (t2 - a2);
            tgt_dist = {2'd0, e1, 3'b000}
                 + {2'd0, e2, 2'b00} + {3'd0, e2, 1'b0};
        end
    endfunction

    reg [11:0] cur_x, cur_y;
    reg [6:0]  cur_col;
    reg [5:0]  cur_row;
    reg [10:0] d0, d1, d2, d3, d4, d5;
    reg [10:0] m01, m23, m45;
    reg [2:0]  i01, i23, i45;
    reg [2:0]  nearest;           // 0..5, 7 = none
    reg [6:0]  tr_col [0:15];
    reg [5:0]  tr_row [0:15];
    reg [15:0] tr_v;
    integer t;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_x <= 12'd0; cur_y <= 12'd0;
            cur_col <= 7'd0; cur_row <= 6'd0;
            d0 <= 11'd0; d1 <= 11'd0; d2 <= 11'd0;
            d3 <= 11'd0; d4 <= 11'd0; d5 <= 11'd0;
            m01 <= 11'd0; m23 <= 11'd0; m45 <= 11'd0;
            i01 <= 3'd0; i23 <= 3'd0; i45 <= 3'd0;
            nearest <= 3'd7;
            tr_v <= 16'd0;
            for (t = 0; t < 16; t = t + 1) begin
                tr_col[t] <= 7'd0;
                tr_row[t] <= 6'd0;
            end
        end else begin
            if (st1) begin
                cur_x <= map_x; cur_y <= map_y;
                cur_col <= map_col; cur_row <= map_row;
                d0 <= tgt_dist(f1c, f2c, A_F1, A_F2);
                d1 <= tgt_dist(f1c, f2c, E_F1, E_F2);
                d2 <= tgt_dist(f1c, f2c, O_F1, O_F2);
                d3 <= tgt_dist(f1c, f2c, U_F1, U_F2);
                d4 <= tgt_dist(f1c, f2c, I_F1, I_F2);
                d5 <= tgt_dist(f1c, f2c, Y_F1, Y_F2);
            end
            if (st2) begin
                if (valid_l) begin
                    for (t = 15; t > 0; t = t - 1) begin
                        tr_col[t] <= tr_col[t-1];
                        tr_row[t] <= tr_row[t-1];
                    end
                    tr_col[0] <= cur_col;
                    tr_row[0] <= cur_row;
                    tr_v <= {tr_v[14:0], 1'b1};
                end
                if (d1 < d0) begin m01 <= d1; i01 <= 3'd1; end else begin m01 <= d0; i01 <= 3'd0; end
                if (d3 < d2) begin m23 <= d3; i23 <= 3'd3; end else begin m23 <= d2; i23 <= 3'd2; end
                if (d5 < d4) begin m45 <= d5; i45 <= 3'd5; end else begin m45 <= d4; i45 <= 3'd4; end
            end
            if (st3) begin
                if (!valid_l)
                    nearest <= 3'd7;
                else if (m23 < m01 && m23 <= m45)
                    nearest <= i23;
                else if (m45 < m01 && m45 < m23)
                    nearest <= i45;
                else
                    nearest <= i01;
            end
        end
    end

    // ---------------- Trail hit (row mask per line, column equality per pixel) ----------------
    reg [15:0] row_mask;
    integer r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            row_mask <= 16'd0;
        else
            for (r = 0; r < 16; r = r + 1)
                row_mask[r] <= tr_v[r] && (tr_row[r] == row_q) && (row_p <= 3'd3);
    end

    reg [15:0] col_hit;
    integer c;
    always @(*) begin
        for (c = 0; c < 16; c = c + 1)
            col_hit[c] = (tr_col[c] == col_q);
    end
    wire trail_hit = (col_p <= 3'd3) && |(row_mask & col_hit);

    // ---------------- Glyphs: 5x7, bit 4 = leftmost column ----------------
    function [4:0] glyph_row;
        input [2:0] id;   // 0 a, 1 e, 2 o, 3 u, 4 i, 5 yu (u with diaeresis)
        input [2:0] row;
        begin
            glyph_row = 5'b00000;
            case (id)
                3'd0: case (row) 3'd2: glyph_row = 5'b01110; 3'd3: glyph_row = 5'b00001;
                                 3'd4: glyph_row = 5'b01111; 3'd5: glyph_row = 5'b10001;
                                 3'd6: glyph_row = 5'b01111; default: glyph_row = 5'b00000; endcase
                3'd1: case (row) 3'd2: glyph_row = 5'b01110; 3'd3: glyph_row = 5'b10001;
                                 3'd4: glyph_row = 5'b11111; 3'd5: glyph_row = 5'b10000;
                                 3'd6: glyph_row = 5'b01110; default: glyph_row = 5'b00000; endcase
                3'd2: case (row) 3'd2: glyph_row = 5'b01110; 3'd3: glyph_row = 5'b10001;
                                 3'd4: glyph_row = 5'b10001; 3'd5: glyph_row = 5'b10001;
                                 3'd6: glyph_row = 5'b01110; default: glyph_row = 5'b00000; endcase
                3'd3: case (row) 3'd2: glyph_row = 5'b10001; 3'd3: glyph_row = 5'b10001;
                                 3'd4: glyph_row = 5'b10001; 3'd5: glyph_row = 5'b10011;
                                 3'd6: glyph_row = 5'b01101; default: glyph_row = 5'b00000; endcase
                3'd4: case (row) 3'd0: glyph_row = 5'b00100; 3'd2: glyph_row = 5'b01100;
                                 3'd3: glyph_row = 5'b00100; 3'd4: glyph_row = 5'b00100;
                                 3'd5: glyph_row = 5'b00100; 3'd6: glyph_row = 5'b01110;
                                 default: glyph_row = 5'b00000; endcase
                3'd5: case (row) 3'd0: glyph_row = 5'b01010; 3'd2: glyph_row = 5'b10001;
                                 3'd3: glyph_row = 5'b10001; 3'd4: glyph_row = 5'b10001;
                                 3'd5: glyph_row = 5'b10011; 3'd6: glyph_row = 5'b01101;
                                 default: glyph_row = 5'b00000; endcase
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    // ---------------- Decomposed 1D X/Y target box, gold ring, and label decode ----------------
    function [6:0] decode_x_eouiy;
        input [7:0] xh;
        begin
            case (xh)
                8'd78: decode_x_eouiy = 7'd67;
                8'd79: decode_x_eouiy = 7'd66;
                8'd80: decode_x_eouiy = 7'd65;
                8'd81: decode_x_eouiy = 7'd65;
                8'd82: decode_x_eouiy = 7'd65;
                8'd83: decode_x_eouiy = 7'd65;
                8'd84: decode_x_eouiy = 7'd65;
                8'd85: decode_x_eouiy = 7'd65;
                8'd86: decode_x_eouiy = 7'd65;
                8'd87: decode_x_eouiy = 7'd65;
                8'd88: decode_x_eouiy = 7'd65;
                8'd89: decode_x_eouiy = 7'd65;
                8'd90: decode_x_eouiy = 7'd66;
                8'd91: decode_x_eouiy = 7'd67;
                8'd92: decode_x_eouiy = 7'd76;
                8'd93: decode_x_eouiy = 7'd75;
                8'd94: decode_x_eouiy = 7'd74;
                8'd95: decode_x_eouiy = 7'd73;
                8'd96: decode_x_eouiy = 7'd72;
                8'd99: decode_x_eouiy = 7'd83;
                8'd100: decode_x_eouiy = 7'd82;
                8'd101: decode_x_eouiy = 7'd81;
                8'd102: decode_x_eouiy = 7'd81;
                8'd103: decode_x_eouiy = 7'd81;
                8'd104: decode_x_eouiy = 7'd81;
                8'd105: decode_x_eouiy = 7'd81;
                8'd106: decode_x_eouiy = 7'd81;
                8'd107: decode_x_eouiy = 7'd81;
                8'd108: decode_x_eouiy = 7'd81;
                8'd109: decode_x_eouiy = 7'd81;
                8'd110: decode_x_eouiy = 7'd81;
                8'd111: decode_x_eouiy = 7'd82;
                8'd112: decode_x_eouiy = 7'd83;
                8'd113: decode_x_eouiy = 7'd92;
                8'd114: decode_x_eouiy = 7'd91;
                8'd115: decode_x_eouiy = 7'd90;
                8'd116: decode_x_eouiy = 7'd89;
                8'd117: decode_x_eouiy = 7'd88;
                8'd195: decode_x_eouiy = 7'd19;
                8'd196: decode_x_eouiy = 7'd18;
                8'd197: decode_x_eouiy = 7'd17;
                8'd198: decode_x_eouiy = 7'd17;
                8'd199: decode_x_eouiy = 7'd17;
                8'd200: decode_x_eouiy = 7'd17;
                8'd201: decode_x_eouiy = 7'd17;
                8'd202: decode_x_eouiy = 7'd17;
                8'd203: decode_x_eouiy = 7'd17;
                8'd204: decode_x_eouiy = 7'd17;
                8'd205: decode_x_eouiy = 7'd17;
                8'd206: decode_x_eouiy = 7'd17;
                8'd207: decode_x_eouiy = 7'd18;
                8'd208: decode_x_eouiy = 7'd19;
                8'd209: decode_x_eouiy = 7'd28;
                8'd210: decode_x_eouiy = 7'd27;
                8'd211: decode_x_eouiy = 7'd26;
                8'd212: decode_x_eouiy = 7'd25;
                8'd213: decode_x_eouiy = 7'd24;
                8'd216: decode_x_eouiy = 7'd35;
                8'd217: decode_x_eouiy = 7'd34;
                8'd218: decode_x_eouiy = 7'd33;
                8'd219: decode_x_eouiy = 7'd33;
                8'd220: decode_x_eouiy = 7'd33;
                8'd221: decode_x_eouiy = 7'd33;
                8'd222: decode_x_eouiy = 7'd33;
                8'd223: decode_x_eouiy = 7'd33;
                8'd224: decode_x_eouiy = 7'd33;
                8'd225: decode_x_eouiy = 7'd33;
                8'd226: decode_x_eouiy = 7'd33;
                8'd227: decode_x_eouiy = 7'd33;
                8'd228: decode_x_eouiy = 7'd34;
                8'd229: decode_x_eouiy = 7'd35;
                8'd230: decode_x_eouiy = 7'd44;
                8'd231: decode_x_eouiy = 7'd43;
                8'd232: decode_x_eouiy = 7'd42;
                8'd233: decode_x_eouiy = 7'd41;
                8'd234: decode_x_eouiy = 7'd40;
                8'd237: decode_x_eouiy = 7'd51;
                8'd238: decode_x_eouiy = 7'd50;
                8'd239: decode_x_eouiy = 7'd49;
                8'd240: decode_x_eouiy = 7'd49;
                8'd241: decode_x_eouiy = 7'd49;
                8'd242: decode_x_eouiy = 7'd49;
                8'd243: decode_x_eouiy = 7'd49;
                8'd244: decode_x_eouiy = 7'd49;
                8'd245: decode_x_eouiy = 7'd49;
                8'd246: decode_x_eouiy = 7'd49;
                8'd247: decode_x_eouiy = 7'd49;
                8'd248: decode_x_eouiy = 7'd49;
                8'd249: decode_x_eouiy = 7'd50;
                8'd250: decode_x_eouiy = 7'd51;
                8'd251: decode_x_eouiy = 7'd60;
                8'd252: decode_x_eouiy = 7'd59;
                8'd253: decode_x_eouiy = 7'd58;
                8'd254: decode_x_eouiy = 7'd57;
                8'd255: decode_x_eouiy = 7'd56;
                default: decode_x_eouiy = 7'b111_0000;
            endcase
        end
    endfunction
    function [3:0] decode_x_a;
        input [7:0] xh;
        begin
            case (xh)
                8'd186: decode_x_a = 4'd3;
                8'd187: decode_x_a = 4'd2;
                8'd188: decode_x_a = 4'd1;
                8'd189: decode_x_a = 4'd1;
                8'd190: decode_x_a = 4'd1;
                8'd191: decode_x_a = 4'd1;
                8'd192: decode_x_a = 4'd1;
                8'd193: decode_x_a = 4'd1;
                8'd194: decode_x_a = 4'd1;
                8'd195: decode_x_a = 4'd1;
                8'd196: decode_x_a = 4'd1;
                8'd197: decode_x_a = 4'd1;
                8'd198: decode_x_a = 4'd2;
                8'd199: decode_x_a = 4'd3;
                8'd200: decode_x_a = 4'd12;
                8'd201: decode_x_a = 4'd11;
                8'd202: decode_x_a = 4'd10;
                8'd203: decode_x_a = 4'd9;
                8'd204: decode_x_a = 4'd8;
                default: decode_x_a = 4'd0;
            endcase
        end
    endfunction
    function [9:0] decode_yh_zones;
        input [6:0] yh;
        begin
            case (yh)
                7'd41: decode_yh_zones = 10'd768;
                7'd42: decode_yh_zones = 10'd512;
                7'd43: decode_yh_zones = 10'd256;
                7'd44: decode_yh_zones = 10'd256;
                7'd45: decode_yh_zones = 10'd256;
                7'd46: decode_yh_zones = 10'd256;
                7'd47: decode_yh_zones = 10'd256;
                7'd48: decode_yh_zones = 10'd256;
                7'd49: decode_yh_zones = 10'd448;
                7'd50: decode_yh_zones = 10'd384;
                7'd51: decode_yh_zones = 10'd320;
                7'd52: decode_yh_zones = 10'd320;
                7'd53: decode_yh_zones = 10'd576;
                7'd54: decode_yh_zones = 10'd832;
                7'd55: decode_yh_zones = 10'd64;
                7'd56: decode_yh_zones = 10'd64;
                7'd57: decode_yh_zones = 10'd64;
                7'd58: decode_yh_zones = 10'd64;
                7'd59: decode_yh_zones = 10'd64;
                7'd60: decode_yh_zones = 10'd64;
                7'd61: decode_yh_zones = 10'd128;
                7'd62: decode_yh_zones = 10'd192;
                7'd69: decode_yh_zones = 10'd12;
                7'd70: decode_yh_zones = 10'd8;
                7'd71: decode_yh_zones = 10'd4;
                7'd72: decode_yh_zones = 10'd4;
                7'd73: decode_yh_zones = 10'd4;
                7'd74: decode_yh_zones = 10'd4;
                7'd75: decode_yh_zones = 10'd4;
                7'd76: decode_yh_zones = 10'd4;
                7'd77: decode_yh_zones = 10'd4;
                7'd78: decode_yh_zones = 10'd4;
                7'd79: decode_yh_zones = 10'd4;
                7'd80: decode_yh_zones = 10'd4;
                7'd81: decode_yh_zones = 10'd56;
                7'd82: decode_yh_zones = 10'd44;
                7'd83: decode_yh_zones = 10'd16;
                7'd84: decode_yh_zones = 10'd16;
                7'd85: decode_yh_zones = 10'd16;
                7'd86: decode_yh_zones = 10'd16;
                7'd87: decode_yh_zones = 10'd16;
                7'd88: decode_yh_zones = 10'd16;
                7'd89: decode_yh_zones = 10'd16;
                7'd90: decode_yh_zones = 10'd16;
                7'd91: decode_yh_zones = 10'd16;
                7'd92: decode_yh_zones = 10'd16;
                7'd93: decode_yh_zones = 10'd32;
                7'd94: decode_yh_zones = 10'd48;
                7'd105: decode_yh_zones = 10'd3;
                7'd106: decode_yh_zones = 10'd2;
                7'd107: decode_yh_zones = 10'd1;
                7'd108: decode_yh_zones = 10'd1;
                7'd109: decode_yh_zones = 10'd1;
                7'd110: decode_yh_zones = 10'd1;
                7'd111: decode_yh_zones = 10'd1;
                7'd112: decode_yh_zones = 10'd1;
                7'd113: decode_yh_zones = 10'd1;
                7'd114: decode_yh_zones = 10'd1;
                7'd115: decode_yh_zones = 10'd1;
                7'd116: decode_yh_zones = 10'd1;
                7'd117: decode_yh_zones = 10'd2;
                7'd118: decode_yh_zones = 10'd3;
                default: decode_yh_zones = 10'd0;
            endcase
        end
    endfunction
    function [5:0] decode_y_lbl;
        input [7:0] y8;
        begin
            case (y8)
                8'd89: decode_y_lbl = 6'd32;
                8'd90: decode_y_lbl = 6'd32;
                8'd91: decode_y_lbl = 6'd33;
                8'd92: decode_y_lbl = 6'd33;
                8'd93: decode_y_lbl = 6'd34;
                8'd94: decode_y_lbl = 6'd34;
                8'd95: decode_y_lbl = 6'd35;
                8'd96: decode_y_lbl = 6'd35;
                8'd97: decode_y_lbl = 6'd36;
                8'd98: decode_y_lbl = 6'd36;
                8'd99: decode_y_lbl = 6'd37;
                8'd100: decode_y_lbl = 6'd37;
                8'd101: decode_y_lbl = 6'd38;
                8'd102: decode_y_lbl = 6'd38;
                8'd105: decode_y_lbl = 6'd24;
                8'd106: decode_y_lbl = 6'd24;
                8'd107: decode_y_lbl = 6'd25;
                8'd108: decode_y_lbl = 6'd25;
                8'd109: decode_y_lbl = 6'd26;
                8'd110: decode_y_lbl = 6'd26;
                8'd111: decode_y_lbl = 6'd27;
                8'd112: decode_y_lbl = 6'd27;
                8'd113: decode_y_lbl = 6'd28;
                8'd114: decode_y_lbl = 6'd28;
                8'd115: decode_y_lbl = 6'd29;
                8'd116: decode_y_lbl = 6'd29;
                8'd117: decode_y_lbl = 6'd30;
                8'd118: decode_y_lbl = 6'd30;
                8'd145: decode_y_lbl = 6'd8;
                8'd146: decode_y_lbl = 6'd8;
                8'd147: decode_y_lbl = 6'd9;
                8'd148: decode_y_lbl = 6'd9;
                8'd149: decode_y_lbl = 6'd10;
                8'd150: decode_y_lbl = 6'd10;
                8'd151: decode_y_lbl = 6'd11;
                8'd152: decode_y_lbl = 6'd11;
                8'd153: decode_y_lbl = 6'd12;
                8'd154: decode_y_lbl = 6'd12;
                8'd155: decode_y_lbl = 6'd13;
                8'd156: decode_y_lbl = 6'd13;
                8'd157: decode_y_lbl = 6'd14;
                8'd158: decode_y_lbl = 6'd14;
                8'd169: decode_y_lbl = 6'd16;
                8'd170: decode_y_lbl = 6'd16;
                8'd171: decode_y_lbl = 6'd17;
                8'd172: decode_y_lbl = 6'd17;
                8'd173: decode_y_lbl = 6'd18;
                8'd174: decode_y_lbl = 6'd18;
                8'd175: decode_y_lbl = 6'd19;
                8'd176: decode_y_lbl = 6'd19;
                8'd177: decode_y_lbl = 6'd20;
                8'd178: decode_y_lbl = 6'd20;
                8'd179: decode_y_lbl = 6'd21;
                8'd180: decode_y_lbl = 6'd21;
                8'd181: decode_y_lbl = 6'd22;
                8'd182: decode_y_lbl = 6'd22;
                8'd217: decode_y_lbl = 6'd0;
                8'd218: decode_y_lbl = 6'd0;
                8'd219: decode_y_lbl = 6'd1;
                8'd220: decode_y_lbl = 6'd1;
                8'd221: decode_y_lbl = 6'd2;
                8'd222: decode_y_lbl = 6'd2;
                8'd223: decode_y_lbl = 6'd3;
                8'd224: decode_y_lbl = 6'd3;
                8'd225: decode_y_lbl = 6'd4;
                8'd226: decode_y_lbl = 6'd4;
                8'd227: decode_y_lbl = 6'd5;
                8'd228: decode_y_lbl = 6'd5;
                8'd229: decode_y_lbl = 6'd6;
                8'd230: decode_y_lbl = 6'd6;
                default: decode_y_lbl = 6'b111_000;
            endcase
        end
    endfunction

    wire in_tgt_quadrant = !pixel_x[9] && (line_y[9:8] == 2'b00);
    wire is_a_band = (line_y[7:6] == 2'b11);
    wire [6:0] x_eouiy = decode_x_eouiy(pixel_x[8:1]);
    wire [3:0] x_a     = decode_x_a(pixel_x[8:1]);
    wire [2:0] act_tid = !in_tgt_quadrant ? 3'd7 : is_a_band ? 3'd0 : x_eouiy[6:4];
    wire [3:0] act_xz  = !in_tgt_quadrant ? 4'd0 : is_a_band ? x_a  : x_eouiy[3:0];

    wire [9:0] yh_zones = decode_yh_zones(line_y[7:1]);
    reg  [1:0] act_yz;
    always @(*) begin
        case (act_tid)
            3'd0: act_yz = yh_zones[1:0];
            3'd1: act_yz = yh_zones[3:2];
            3'd2: act_yz = yh_zones[5:4];
            3'd3: act_yz = yh_zones[7:6];
            3'd4, 3'd5: act_yz = yh_zones[9:8];
            default: act_yz = 2'd0;
        endcase
    end

    wire [5:0] y_lbl = decode_y_lbl(line_y[7:0]);
    wire [2:0] act_ygrp = (act_tid == 3'd5) ? 3'd4 : act_tid;
    wire lbl_y_ok = in_tgt_quadrant && (y_lbl[5:3] == act_ygrp) && (act_tid != 3'd7);
    wire [4:0] lbl_bits = glyph_row(act_tid, y_lbl[2:0]);
    wire [2:0] lbl_col  = act_xz[2:0];

    wire in10_x = (act_xz == 4'd1);
    wire in12_x = (act_xz == 4'd1) || (act_xz == 4'd2);
    wire in14_x = (act_xz == 4'd1) || (act_xz == 4'd2) || (act_xz == 4'd3);
    wire in10_y = (act_yz == 2'd1);
    wire in12_y = (act_yz == 2'd1) || (act_yz == 2'd2);
    wire in14_y = (act_yz != 2'd0);

    wire is_box_hit  = (in12_x && in12_y) && !(in10_x && in10_y);
    wire is_gold_hit = (in14_x && in14_y) && !(in10_x && in10_y);
    wire is_lbl_hit  = act_xz[3] && lbl_y_ok && lbl_bits[lbl_col];

    wire tgt_any  = is_box_hit || is_lbl_hit;
    wire tgt_near = tgt_any && (nearest == act_tid);
    wire tgt_gold = is_gold_hit && tgt_en_l && tgt_blink_l && (tgt_id_l == act_tid);

    // Ripple-free panel & bar X/Y decode
    function decode_panel_x;
        input [5:0] x4;
        begin
            case (x4)
                6'd7, 6'd8, 6'd9, 6'd10, 6'd11, 6'd12, 6'd13, 6'd14,
                6'd15, 6'd16, 6'd17, 6'd18, 6'd19, 6'd20, 6'd21, 6'd22,
                6'd23, 6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29, 6'd30,
                6'd31, 6'd32: decode_panel_x = 1'b1;
                default: decode_panel_x = 1'b0;
            endcase
        end
    endfunction

    function decode_panel_y;
        input [7:0] y2;
        begin
            case (y2)
                8'd13, 8'd14, 8'd15, 8'd16, 8'd17, 8'd18, 8'd19, 8'd20,
                8'd21, 8'd22, 8'd23, 8'd24, 8'd25, 8'd26, 8'd27, 8'd28,
                8'd29, 8'd30, 8'd31, 8'd32, 8'd33, 8'd34, 8'd35, 8'd36,
                8'd37, 8'd38, 8'd39, 8'd40, 8'd41, 8'd42, 8'd43, 8'd44,
                8'd45, 8'd46, 8'd47, 8'd48, 8'd49, 8'd50, 8'd51, 8'd52,
                8'd53, 8'd54, 8'd55, 8'd56, 8'd57, 8'd58, 8'd59, 8'd60,
                8'd61, 8'd62, 8'd63, 8'd64, 8'd65, 8'd66, 8'd67, 8'd68,
                8'd69, 8'd70: decode_panel_y = 1'b1;
                default: decode_panel_y = 1'b0;
            endcase
        end
    endfunction

    function decode_bar_x;
        input [7:0] x2;
        begin
            case (x2)
                8'd51, 8'd52, 8'd53, 8'd54, 8'd55, 8'd56, 8'd57, 8'd58,
                8'd59, 8'd60, 8'd61, 8'd62, 8'd63, 8'd64, 8'd65, 8'd66,
                8'd67, 8'd68, 8'd69, 8'd70, 8'd71, 8'd72, 8'd73, 8'd74,
                8'd75, 8'd76, 8'd77, 8'd78, 8'd79, 8'd80, 8'd81, 8'd82,
                8'd83, 8'd84, 8'd85, 8'd86, 8'd87, 8'd88, 8'd89, 8'd90,
                8'd91, 8'd92, 8'd93, 8'd94, 8'd95, 8'd96, 8'd97, 8'd98,
                8'd99, 8'd100, 8'd101, 8'd102, 8'd103, 8'd104, 8'd105, 8'd106,
                8'd107: decode_bar_x = 1'b1;
                default: decode_bar_x = 1'b0;
            endcase
        end
    endfunction

    wire in_panel = decode_panel_x(pixel_x[9:4]) && decode_panel_y(line_y[9:2]);
    wire point_hit = valid_l &&
                     ({3'b000, pixel_x} + 13'd4 >= {1'b0, cur_x}) &&
                     ({3'b000, pixel_x} < {1'b0, cur_x} + 13'd4) &&
                     ({3'b000, line_y} + 13'd4 >= {1'b0, cur_y}) &&
                     ({3'b000, line_y} < {1'b0, cur_y} + 13'd4);

    wire draw = enable_l && de && in_panel;
    // Shorten the bar symmetrically by 16 pixels per side. Same centre and
    // height: border x=204..431, y=304..319; interior x=208..427, y=306..317.
    // floor(7*progress/2) maps 0..63 to 0..220 pixels without division logic.
    wire [8:0] bar_scaled = {progress_l, 3'b000} - {3'b000, progress_l};
    wire [8:0] bar_fill_end = 9'd208 + {1'b0, bar_scaled[8:1]};
    wire bar_area = decode_bar_x(pixel_x[9:2]) && (line_y[9:4] == 6'd19);
    wire bar_border = pixel_x[9:2] == 8'd51 || pixel_x[9:2] == 8'd107 ||
                      line_y[3:1] == 3'd0 || line_y[3:1] == 3'd7;
    wire bar_fill = pixel_x < {1'b0, bar_fill_end};
    wire bar_draw = enable_l && progress_en_l && de && bar_area;
    // Target centers for auxiliary borders
    localparam [9:0] ENTER_DX = 6 * ENTER_RADIUS + 3;
    localparam [9:0] ENTER_DY = 8 * ENTER_RADIUS + 4;
    localparam [9:0] KEEP_DX  = 6 * KEEP_RADIUS + 3;
    localparam [9:0] KEEP_DY  = 8 * KEEP_RADIUS + 4;

    reg [9:0] sel_cx, sel_cy;
    always @(*) begin
        case (tgt_id_l)
            3'd0: begin sel_cx = A_X[9:0]; sel_cy = A_Y[9:0]; end
            3'd1: begin sel_cx = E_X[9:0]; sel_cy = E_Y[9:0]; end
            3'd2: begin sel_cx = O_X[9:0]; sel_cy = O_Y[9:0]; end
            3'd3: begin sel_cx = U_X[9:0]; sel_cy = U_Y[9:0]; end
            3'd4: begin sel_cx = I_X[9:0]; sel_cy = I_Y[9:0]; end
            3'd5: begin sel_cx = Y_X[9:0]; sel_cy = Y_Y[9:0]; end
            default: begin sel_cx = 10'd0; sel_cy = 10'd0; end
        endcase
    end

    wire signed [11:0] sx = ({2'b00, pixel_x});
    wire signed [11:0] sy = ({2'b00, line_y});
    wire signed [11:0] cx = ({2'b00, sel_cx});
    wire signed [11:0] cy = ({2'b00, sel_cy});
    wire signed [11:0] edx = ({2'b00, ENTER_DX});
    wire signed [11:0] edy = ({2'b00, ENTER_DY});
    wire signed [11:0] kdx = ({2'b00, KEEP_DX});
    wire signed [11:0] kdy = ({2'b00, KEEP_DY});

    // Auxiliary inner border (ENTER): solid gold 24'hFFD200
    wire enter_x_match = (sx == cx - edx) || (sx == cx + edx);
    wire enter_y_match = (sy == cy - edy) || (sy == cy + edy);
    wire enter_x_in    = (sx >= cx - edx) && (sx <= cx + edx);
    wire enter_y_in    = (sy >= cy - edy) && (sy <= cy + edy);
    wire enter_hit     = tgt_en_l && (tgt_id_l < 3'd6) &&
                         ((enter_x_match && enter_y_in) || (enter_y_match && enter_x_in));

    // Auxiliary outer border (KEEP): dashed gray 24'hB0C0D0 (2 px on, 2 px off)
    wire keep_x_match  = (sx == cx - kdx) || (sx == cx + kdx);
    wire keep_y_match  = (sy == cy - kdy) || (sy == cy + kdy);
    wire keep_x_in     = (sx >= cx - kdx) && (sx <= cx + kdx);
    wire keep_y_in     = (sy >= cy - kdy) && (sy <= cy + kdy);
    wire keep_dash_h   = (pixel_x[1] == 1'b0);
    wire keep_dash_v   = (line_y[1] == 1'b0);
    wire keep_hit      = tgt_en_l && (tgt_id_l < 3'd6) &&
                         ((keep_y_match && keep_x_in && keep_dash_h) ||
                          (keep_x_match && keep_y_in && keep_dash_v));

    wire [23:0] bar_fill_color = (phase_l == 2'b11) ? 24'h22C55E
                               : (phase_l == 2'b10) ? 24'hF59E0B
                               : C_POINT;
    wire [23:0] bar_rgb = bar_border ? C_TGT : !bar_fill ? C_PANEL : bar_fill_color;
    assign rgb_out = bar_draw  ? bar_rgb : !draw    ? rgb_in
                   : point_hit ? C_POINT
                   : trail_hit ? C_TRAIL
                   : tgt_gold  ? C_GOLD
                   : tgt_near  ? C_NEAR
                   : tgt_any   ? C_TGT
                   : enter_hit ? C_GOLD
                   : keep_hit  ? C_TGT
                   : C_PANEL;

endmodule
