`timescale 1ns/1ps
// v36 level 1 "bird flies back to the nest" sustain game overlay
// with the v37 child guide:
// IDLE guide card + dashed arrow, DEMO "看小鸟示范", COUNTDOWN "深吸一口气",
// sound-wave bubble next to the bird (IDLE / DEMO / PRACTICE in band).
// rgb_in -> rgb_out: 0 clocks. v37: the colour of pixel pxn (= pixel_x + 1) is
// computed one clock early and registered (ov_bg / ov_col); rgb_out is only
// (!enable || !de || ov_bg) ? rgb_in : ov_col. So every BRAM is read two pixels
// ahead (scene: px2 = pixel_x + 2; bird / flag / label windows start one clock
// earlier than in v36), and its registered output describes pixel pxn.
// All inputs are latched at frame_start (vs_q && !vsync); the derived values
// (category, 7-step division, display position, debounce, decimal digits,
// subtitle slot, label pointers) are computed serially in clocks 1..24 after
// frame_start. No multiplier, no combinational divide.
// Layers (high -> low), all but the timer digits, the card and the time bar clipped to
// the stage x 64..575, y 64..383:
//   label run B (hint / card line 1) > bird + bubble > label run A (timer digits /
//   card line 2 / DEMO, COUNTDOWN label) > guide card > stars > nest + arrow > flag >
//   post / branch > arrow shaft > cloud > channel border > channel fill > grass > sky >
//   time bar > rgb_in.
// BRAM9K: sprite ROM 2048x5 (2 blocks, 2 read ports: bird / bubble, scene), label ROM 12 x 2048x4.
module sustain_game_overlay24 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,           // active low
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        enable,          // osd valid && practice_view && state != 5
    input  wire [2:0]  state,           // controller state
    input  wire [1:0]  countdown_digit,
    input  wire [15:0] energy,          // current_energy
    input  wire [15:0] reference_level, // target_reference (DEMO)
    input  wire [15:0] target_low,
    input  wire [15:0] target_high,
    input  wire [12:0] current_ms,
    input  wire [12:0] best_ms,
    input  wire [12:0] progress_ms,
    input  wire [12:0] elapsed_ms,
    input  wire        in_target,
    input  wire        result_success,
    output wire [23:0] rgb_out,
    output reg         l1_sub_en,
    output reg  [3:0]  slot_en,
    output reg  [19:0] slot_id,
    output reg  [39:0] slot_cx,
    output reg  [35:0] slot_cy,
    output reg  [11:0] slot_kind
);
`include "sustain_sprite.vh"
`include "sustain_label.vh"

    // ---------------- Coordinates (same as tone_game_overlay24) ----------------
    reg [9:0] pixel_x, line_y;
    reg de_q, vs_q;
    wire frame_start = vs_q && !vsync;
    wire blank = !vsync || !de;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x <= 10'd0; line_y <= 10'd0; de_q <= 1'b0; vs_q <= 1'b1;
        end else begin
            de_q <= de; vs_q <= vsync;
            if (blank) pixel_x <= 10'd0; else pixel_x <= pixel_x + 1'b1;
            if (!vsync) line_y <= 10'd0; else if (de_q && !de) line_y <= line_y + 1'b1;
        end
    end
    wire [9:0] pxn = blank ? 10'd0 : pixel_x + 1'b1;   // pixel of the next clock
    // Pixel two clocks ahead (scene ROM address). Wrong only for pixels 0 and 1
    // of a line, which are outside the stage.
    wire [9:0] px2 = pixel_x + 10'd2;
    wire line_end = de_q && !de;

    // ---------------- Frame latch ----------------
    reg        en_l, it_l, rs_l;
    reg [2:0]  st_l;
    reg [1:0]  cd_l;
    reg [15:0] e_l, lo_l, hi_l;       // e_l = E_src (reference_level in DEMO, else energy)
    reg [12:0] cur_l, best_l, prog_l, ela_l;
    reg [3:0]  fcnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            en_l <= 1'b0; it_l <= 1'b0; rs_l <= 1'b0; st_l <= 3'd0; cd_l <= 2'd0;
            e_l <= 16'd0; lo_l <= 16'd0; hi_l <= 16'd0;
            cur_l <= 13'd0; best_l <= 13'd0; prog_l <= 13'd0; ela_l <= 13'd0;
            fcnt <= 4'd0;
        end else if (frame_start) begin
            en_l <= enable; it_l <= in_target; rs_l <= result_success;
            st_l <= state; cd_l <= countdown_digit;
            e_l <= (state == 3'd2) ? reference_level : energy;
            lo_l <= target_low; hi_l <= target_high;
            cur_l <= current_ms; best_l <= best_ms; prog_l <= progress_ms; ela_l <= elapsed_ms;
            fcnt <= fcnt + 1'b1;
        end
    end
    wire st_idle = (st_l == 3'd1);
    wire st_demo = (st_l == 3'd2);
    wire st_cd   = (st_l == 3'd3);
    wire st_prac = (st_l == 3'd4);
    wire succ    = st_prac && rs_l;

    // ---------------- Blanking-time calculation ----------------
    reg  [4:0] cc;                    // 0 idle, 1..24 running
    wire calc = (cc != 5'd0);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cc <= 5'd0;
        else if (frame_start) cc <= 5'd1;
        else if (calc) cc <= (cc == 5'd24) ? 5'd0 : cc + 1'b1;
    end

    // 4.1 category (from the latched values, valid from cc 1)
    wire        e_lt_lo = (e_l < lo_l);
    wire        e_ge_hi = (e_l >= hi_l);
    wire [1:0]  c_n   = e_lt_lo ? 2'd0 : e_ge_hi ? 2'd2 : 2'd1;
    wire [15:0] num_n = e_lt_lo ? e_l : e_l - (e_ge_hi ? hi_l : lo_l);
    wire [15:0] den_n = e_lt_lo ? lo_l : e_ge_hi ? hi_l : hi_l - lo_l;

    // 4.3 7-step restoring division q = floor(num * 128 / den) (num < den), cc 2..8
    reg  [1:0]  c_r;
    reg  [15:0] rem, den_r;
    reg  [6:0]  q;
    reg         sat;
    wire [16:0] r2   = {rem, 1'b0};
    wire [17:0] rdif = {1'b0, r2} - {2'b0, den_r};
    wire        r_ge = !rdif[17];
    // 4.6 serial decimal: cc 2..9 subtract 1000 (<= 8 times), cc 10..18 subtract 100
    reg  [12:0] dr;
    reg  [3:0]  d_s, d_t;
    wire        d_k = (cc <= 5'd9);
    wire [13:0] ddif = {1'b0, dr} - (d_k ? 14'd1000 : 14'd100);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_r <= 2'd0; rem <= 16'd0; den_r <= 16'd0; q <= 7'd0; sat <= 1'b1;
            dr <= 13'd0; d_s <= 4'd0; d_t <= 4'd0;
        end else if (cc == 5'd1) begin
            c_r <= c_n; rem <= num_n; den_r <= den_n; q <= 7'd0;
            sat <= (den_n == 16'd0) || (num_n >= den_n);
            dr <= succ ? best_l : cur_l; d_s <= 4'd0; d_t <= 4'd0;
        end else if (calc) begin
            if (cc <= 5'd8) begin
                rem <= r_ge ? rdif[15:0] : r2[15:0];
                q   <= {q[5:0], r_ge};
            end
            if (cc <= 5'd18 && !ddif[13]) begin
                dr <= ddif[12:0];
                if (d_k) d_s <= d_s + 1'b1; else d_t <= d_t + 1'b1;
            end
        end
    end
    wire [6:0] qv = sat ? 7'd127 : q;
    wire [8:0] y_tgt = (c_r == 2'd0) ? 9'd351 - {3'd0, qv[6:1]} :
                       (c_r == 2'd1) ? 9'd287 - {2'd0, qv} :
                                       9'd159 - {3'd0, qv[6:1]};

    // 4.2 x mapping; DEMO source cm_eff = progress * 2.5 (full width, no wrap)
    // bx(ms) = ms >= 5000 ? 392 : (ms >> 4) + (ms >> 6); bx_lo is the second branch.
    function [8:0] bx_lo;
        input [12:0] ms;
        begin
            bx_lo = ms[12:4] + {2'b0, ms[12:6]};
        end
    endfunction
    wire [14:0] cm_eff = {1'b0, prog_l, 1'b0} + {3'b0, prog_l[12:1]};
    wire [14:0] tsrc   = st_demo ? cm_eff : st_prac ? {2'b0, cur_l} : 15'd0;
    wire [8:0]  tgt_bx = (tsrc >= 15'd5000) ? 9'd392 : bx_lo(tsrc[12:0]);
    wire [8:0]  bxf    = (best_l >= 13'd5000) ? 9'd392 : bx_lo(best_l);
    wire [14:0] ssrc   = st_demo ? cm_eff : {2'b0, best_l};
    wire [2:0]  lit    = {ssrc >= 15'd5000, ssrc >= 15'd3500, ssrc >= 15'd2000};

    // 4.4 display position, 4.5 debounce: cc 10
    reg  [8:0] bx_disp, y_disp;
    reg  [1:0] cand, hc;
    reg  [2:0] dcnt;
    wire [9:0]  bdif = {1'b0, bx_disp} - {1'b0, tgt_bx};
    wire signed [10:0] yd = $signed({2'b0, y_tgt}) - $signed({2'b0, y_disp});
    wire        yd_small = (yd > -11'sd4) && (yd < 11'sd4);
    wire signed [10:0] yd4 = yd >>> 2;
    wire [10:0] y_step = {2'b0, y_disp} + yd4;
    wire [2:0]  dn = (c_r == cand) ? ((dcnt == 3'd7) ? 3'd7 : dcnt + 1'b1) : 3'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bx_disp <= 9'd0; y_disp <= 9'd351; cand <= 2'd0; dcnt <= 3'd0; hc <= 2'd3;
        end else if (cc == 5'd10) begin
            bx_disp <= (tgt_bx >= bx_disp) ? tgt_bx :
                       (bdif > 10'd16) ? bx_disp - 9'd16 : tgt_bx;
            y_disp  <= yd_small ? y_tgt : y_step[8:0];
            if (!st_prac) begin
                cand <= c_r; dcnt <= 3'd0; hc <= 2'd3;
            end else begin
                cand <= c_r; dcnt <= dn;
                if (dn == 3'd7) hc <= c_r;
            end
        end
    end

    // Per-frame drawing parameters: cc 11
    // v37: window start compares (bsx, hsx, fsx, sxA) are one pixel earlier than in v36,
    // because the output colour is computed for pxn and registered.
    reg [9:0] bsx, hsx, fsx, tb_end;  // pixel_x two or three clocks before the window
    reg [9:0] bsy, hyt;               // line_y just before the first row
    reg       showB, showF, spark_on, in_band, storm, hint_lo;
    reg [2:0] lit_r;
    reg [4:0] eB;                     // run B rows - 1
    reg [2:0] fsB, lastA;             // run B first slot, run A last slot
    reg [9:0] sxA, yA;                // run A: start pixel_x (= x - 3), line just before the first row
    reg [5:0] eA;                     // run A rows - 1
    reg       x2A, showA, showBub, showCard, showArw;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bsx <= 10'd101; bsy <= 10'd336; hsx <= 10'd85; hyt <= 10'd310; fsx <= 10'd118;
            tb_end <= 10'd70; showB <= 1'b0; showF <= 1'b0; spark_on <= 1'b0;
            in_band <= 1'b0; storm <= 1'b0; hint_lo <= 1'b0; lit_r <= 3'd0;
            eB <= 5'd21; fsB <= 3'd4; sxA <= 10'd461; yA <= 10'd7; eA <= 6'd43; lastA <= 3'd3;
            x2A <= 1'b1; showA <= 1'b0; showBub <= 1'b0; showCard <= 1'b0; showArw <= 1'b0;
        end else if (cc == 5'd11) begin
            // bird window x cx-16..cx+15 (b_h starts at pixel_x == cx - 19), rows cy-14..cy+13;
            // v37 bubble x cx+16..cx+47 in the same window (64 wide)
            bsx <= succ ? 10'd517 : 10'd101 + {1'b0, bx_disp};
            bsy <= succ ? 10'd195 : {1'b0, y_disp} - 10'd15;
            // run B: hint label x = cx - 32 / IDLE card line 1 x = 212 (engine starts at pixel_x == x - 3)
            hsx <= st_idle ? 10'd209 : 10'd85 + {1'b0, bx_disp};
            hyt <= st_idle ? 10'd106 :
                   (hc == 2'd0) ? {1'b0, y_disp} - 10'd41 : {1'b0, y_disp} + 10'd17;
            hint_lo <= (hc == 2'd0);
            showB <= st_idle || (st_prac && !succ && (hc == 2'd0 || hc == 2'd2));
            eB  <= st_idle ? 5'd24 : 5'd21;
            fsB <= st_idle ? 3'd3 : 3'd4;
            // run A: PRACTICE timer digits x 464 rows 8..51 (2x); IDLE card line 2 x 186 rows 139..185;
            // DEMO / COUNTDOWN label x 216 rows 104..150 (1x)
            sxA   <= st_prac ? 10'd461 : st_idle ? 10'd183 : 10'd213;
            yA    <= st_prac ? 10'd7   : st_idle ? 10'd138 : 10'd103;
            eA    <= st_prac ? 6'd43 : 6'd46;
            lastA <= st_prac ? 3'd3 : st_idle ? 3'd2 : 3'd1;
            x2A   <= st_prac;
            showA <= st_idle || st_demo || st_cd || st_prac;
            showBub  <= st_idle || st_demo || (st_prac && !succ && (c_r == 2'd1) && it_l);
            showCard <= st_idle;
            showArw  <= st_idle;
            // flag at xf = 120 + bx(best): f_h starts at pixel_x == xf - 2
            fsx <= 10'd118 + {1'b0, bxf};
            showF <= st_prac && !succ && (best_l > cur_l);
            tb_end <= 10'd70 + (st_prac ? {1'b0, ela_l[12:4]} : 10'd0);
            spark_on <= succ && fcnt[3];
            in_band <= (c_r == 2'd1) && it_l;
            storm <= !st_demo && (c_r == 2'd2);
            lit_r <= lit;
        end
    end

    // Subtitle slot 0: cc 11 (after hc update)
    reg       sb_on;
    reg [4:0] sb_id;
    reg [2:0] sb_kind;
    always @(*) begin
        sb_on = 1'b0; sb_id = 5'd0; sb_kind = 3'd0;
        case (st_l)
            3'd1: begin sb_on = 1'b1; sb_id = 5'd0; sb_kind = 3'd0; end
            3'd3: begin sb_on = (cd_l != 2'd0); sb_id = 5'd4 - {3'd0, cd_l}; sb_kind = 3'd0; end
            3'd4: begin
                if (rs_l)                    begin sb_on = 1'b1; sb_id = 5'd6;  sb_kind = 3'd4; end
                else if (ela_l < 13'd1000)   begin sb_on = 1'b1; sb_id = 5'd4;  sb_kind = 3'd0; end
                else if (hc == 2'd1)         begin sb_on = 1'b1; sb_id = 5'd19; sb_kind = 3'd1; end
                else if (hc == 2'd0)         begin sb_on = 1'b1; sb_id = 5'd5;  sb_kind = 3'd2; end
            end
            default: ;
        endcase
    end
    wire sb_v = en_l && sb_on;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l1_sub_en <= 1'b0; slot_en <= 4'd0; slot_id <= 20'd0;
            slot_cx <= 40'd0; slot_cy <= 36'd0; slot_kind <= 12'd0;
        end else if (cc == 5'd11) begin
            l1_sub_en <= en_l;
            slot_en   <= {3'd0, sb_v};
            slot_id   <= {15'd0, sb_v ? sb_id : 5'd0};
            slot_cx   <= {30'd0, sb_v ? 10'd320 : 10'd0};
            slot_cy   <= {27'd0, sb_v ? 9'd30 : 9'd0};
            slot_kind <= {9'd0, sb_v ? sb_kind : 3'd0};
        end
    end

    // ---------------- Vertical / horizontal regions (v37: of pixel pxn) ----------------
    wire ly_stage = (line_y >= 10'd64)  && (line_y <= 10'd383);
    wire px_stage = (pxn >= 10'd64) && (pxn <= 10'd575);
    wire in_stage = ly_stage && px_stage;
    wire ly_cloud = (line_y >= 10'd64)  && (line_y <= 10'd95);
    wire ly_chan  = (line_y >= 10'd160) && (line_y <= 10'd287);
    wire ly_bord  = (line_y == 10'd160) || (line_y == 10'd161) ||
                    (line_y == 10'd286) || (line_y == 10'd287);
    wire ly_grass = (line_y >= 10'd352) && (line_y <= 10'd383);
    wire ly_gdark = (line_y <= 10'd355);
    wire ly_post  = (line_y >= 10'd312) && (line_y <= 10'd351);
    wire ly_brch  = (line_y >= 10'd236) && (line_y <= 10'd241);
    wire ly_flag  = (line_y >= 10'd136) && (line_y <= 10'd159);
    wire ly_fface = (line_y <= 10'd145);
    wire ly_sprk  = (line_y >= 10'd168) && (line_y <= 10'd183);
    wire ly_s3    = (line_y >= 10'd184) && (line_y <= 10'd199);
    wire ly_s12   = (line_y >= 10'd216) && (line_y <= 10'd231);
    wire ly_nest  = (line_y >= 10'd208) && (line_y <= 10'd239);
    wire ly_tbo   = (line_y >= 10'd402) && (line_y <= 10'd415);
    wire ly_tbi   = (line_y >= 10'd404) && (line_y <= 10'd413);
    wire px_post  = (pxn[9:2] == 8'd23);                             // 92..95
    wire px_brch  = (pxn >= 10'd552) && (pxn <= 10'd575);
    wire px_tbo   = (pxn >= 10'd68)  && (pxn <= 10'd571);
    wire px_tbi   = (pxn >= 10'd70)  && (pxn <= 10'd569);
    // v37 guide card x 176..463 y 100..195 (inner x 178..461 y 102..193), arrow shaft x 176..503 y 221..226
    wire ly_card    = (line_y >= 10'd100) && (line_y <= 10'd195);
    wire ly_cardi   = (line_y >= 10'd102) && (line_y <= 10'd193);
    wire px_card    = (pxn >= 10'd176) && (pxn <= 10'd463);
    wire px_cardi   = (pxn >= 10'd178) && (pxn <= 10'd461);
    wire ly_shaft   = (line_y >= 10'd221) && (line_y <= 10'd226);
    wire ly_shaft_e = (line_y == 10'd221) || (line_y == 10'd226);
    wire px_shaft   = (pxn >= 10'd176) && (pxn <= 10'd503);

    // ---------------- Sprite ROM (bird + bubble, scene) ----------------
    (* rom_style = "bram" *) reg [4:0] spa_rom [0:2047];
    integer ri;
    initial for (ri = 0; ri < 2048; ri = ri + 1) spa_rom[ri] = spa_px(ri[10:8], ri[7:4], ri[3:0]);

    // Scene sprite of pixel px2 (windows are disjoint): 0 none, 1 cloud, 2 star, 3 nest / arrow.
    // Star tops 168 / 184 / 216 are all 8 mod 16 -> row = line_y[3:0] ^ 8.
    // Nest top 208 = 16 mod 32 -> row = line_y[4:0] ^ 16 (>> 1); left 520 = 8 mod 32.
    // Arrow x 504..519 (504 = 8 mod 16), rows 216..231 (= ly_s12).
    wire       xn_sp  = (px2[9:4] == 6'd31) || (px2[9:4] == 6'd35);  // 496..511, 560..575
    wire       xn_s3  = (px2[9:4] == 6'd33);                         // 528..543
    wire       xn_s2  = (px2[9:4] == 6'd24);                         // 384..399
    wire       xn_s1  = (px2 >= 10'd268) && (px2 <= 10'd283);
    wire       xn_ns  = (px2 >= 10'd520) && (px2 <= 10'd551);
    wire       xn_ah  = (px2 >= 10'd504) && (px2 <= 10'd519);
    wire [3:0] s_row  = {~line_y[3], line_y[2:0]};
    wire [4:0] n_col  = px2[4:0] + 5'd24;
    reg  [1:0] sc_t;
    reg        sc_dim;
    reg  [10:0] sc_addr;
    always @(*) begin
        sc_t = 2'd0; sc_dim = 1'b0; sc_addr = {3'd3, line_y[4:1], px2[4:1]};
        if (ly_cloud) begin
            sc_t = 2'd1;
        end else if (ly_sprk && xn_sp && spark_on) begin
            sc_t = 2'd2; sc_addr = {3'd1, s_row, px2[3:0]};
        end else if (ly_s3 && xn_s3) begin
            sc_t = 2'd2; sc_dim = !lit_r[2]; sc_addr = {3'd1, s_row, px2[3:0]};
        end else if (ly_s12 && xn_s1) begin
            sc_t = 2'd2; sc_dim = !lit_r[0]; sc_addr = {3'd1, s_row, px2[3:0] + 4'd4};
        end else if (ly_s12 && xn_s2) begin
            sc_t = 2'd2; sc_dim = !lit_r[1]; sc_addr = {3'd1, s_row, px2[3:0]};
        end else if (ly_nest && xn_ns) begin
            sc_t = 2'd3; sc_addr = {3'd2, ~line_y[4], line_y[3:1], n_col[4:1]};
        end else if (showArw && ly_s12 && xn_ah) begin
            sc_t = 2'd3; sc_addr = {3'd5, s_row, ~px2[3], px2[2:0]};
        end
    end

    // Bird + bubble: 64x28 window, 2x upscale (b_dx 0..31 bird sel 0, 32..63 bubble sel 4).
    reg       b_h, b_v;
    reg [5:0] b_dx;
    reg [4:0] b_dy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_h <= 1'b0; b_v <= 1'b0; b_dx <= 6'd0; b_dy <= 5'd0;
        end else begin
            if (blank) b_h <= 1'b0;
            else if (pixel_x == bsx) begin b_h <= 1'b1; b_dx <= 6'd0; end
            else if (b_h) begin
                b_dx <= b_dx + 1'b1;
                if (b_dx == 6'd63) b_h <= 1'b0;
            end
            if (!vsync) b_v <= 1'b0;
            else if (line_end) begin
                if (line_y == bsy) begin b_v <= 1'b1; b_dy <= 5'd0; end
                else if (b_v) begin
                    b_dy <= b_dy + 1'b1;
                    if (b_dy == 5'd27) b_v <= 1'b0;
                end
            end
        end
    end
    wire [10:0] b_addr = {b_dx[5] ? 3'd4 : 3'd0, b_dy[4:1], b_dx[4:1]};

    reg [4:0] spr_s, spr_b;
    reg [1:0] sc_t_d;
    reg       sc_dim_d, b_in_d, b_rt_d;
    always @(posedge clk) begin
        spr_s <= spa_rom[sc_addr];
        spr_b <= spa_rom[b_addr];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sc_t_d <= 2'd0; sc_dim_d <= 1'b0; b_in_d <= 1'b0; b_rt_d <= 1'b0; end
        else begin sc_t_d <= sc_t; sc_dim_d <= sc_dim; b_in_d <= b_h && b_v; b_rt_d <= b_dx[5]; end
    end
    wire bird_hit  = b_in_d && (spr_b != 5'd0) && (!b_rt_d || showBub);
    wire sc_nz     = (spr_s != 5'd0);
    wire star_hit  = (sc_t_d == 2'd2) && sc_nz;
    wire nest_hit  = (sc_t_d == 2'd3) && sc_nz;
    wire cloud_hit = (sc_t_d == 2'd1) && sc_nz;
    wire [4:0] star_idx  = sc_dim_d ? spr_s + 5'd4 : spr_s;   // SPA_DIM_OFS
    wire [4:0] cloud_idx = storm ? spr_s + 5'd3 : spr_s;      // SPA_STORM_OFS

    // Flag: pole x xf..xf+1 rows 136..159, face x xf+2..xf+13 rows 136..145.
    reg       f_h;
    reg [3:0] f_dx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_h <= 1'b0; f_dx <= 4'd0;
        end else if (blank) begin
            f_h <= 1'b0;
        end else if (pixel_x == fsx) begin
            f_h <= 1'b1; f_dx <= 4'd0;
        end else if (f_h) begin
            f_dx <= f_dx + 1'b1;
            if (f_dx == 4'd13) f_h <= 1'b0;
        end
    end
    wire f_pole   = (f_dx[3:1] == 3'd0);
    wire flag_hit = showF && f_h && ly_flag && (f_pole || ly_fface);

    // ---------------- Label engine (sustain_label.vh, p_mem row pointers) ----------------
    // Run A (slots 0..lastA): PRACTICE timer digits at (464, 8), 2x, slots 0..3 = s, ".", t, "秒";
    //   IDLE card line 2 at (186, 139), slots 0..2; DEMO / COUNTDOWN label at (216, 104), slots 0..1; 1x.
    // Run B (slots fsB..4, 1x): PRACTICE hint at (cx - 32, cy - 40 / cy + 18), slot 4 = 12 / 13;
    //   IDLE card line 1 at (212, 107), slots 3..4.
    // Within one state the two runs never share a line.
    (* rom_style = "bram" *) reg [3:0] lbl_m0  [0:2047];
    (* rom_style = "bram" *) reg [3:0] lbl_m1  [0:2047];
    (* rom_style = "bram" *) reg [3:0] lbl_m2  [0:2047];
    (* rom_style = "bram" *) reg [3:0] lbl_m3  [0:2047];
    (* rom_style = "bram" *) reg [3:0] lbl_m4  [0:2047];
    (* rom_style = "bram" *) reg [3:0] lbl_m5  [0:2047];
    (* rom_style = "bram" *) reg [3:0] lbl_m6  [0:2047];
    (* rom_style = "bram" *) reg [3:0] lbl_m7  [0:2047];
    (* rom_style = "bram" *) reg [3:0] lbl_m8  [0:2047];
    (* rom_style = "bram" *) reg [3:0] lbl_m9  [0:2047];
    (* rom_style = "bram" *) reg [3:0] lbl_m10 [0:2047];
    (* rom_style = "bram" *) reg [3:0] lbl_m11 [0:2047];
    // bank k nibble j = bits [4*j[0]+3 : 4*j[0]] of ROM word k * 1024 + j / 2
    function [3:0] lbl_nib;
        input [13:0] a;
        input        h;
        reg   [7:0]  w;
        begin
            w = sla_rom(a);
            lbl_nib = h ? w[7:4] : w[3:0];
        end
    endfunction
    integer li;
    initial begin
        for (li = 0; li < 2048; li = li + 1) begin
            lbl_m0[li]  = lbl_nib((li >> 1), li[0]);
            lbl_m1[li]  = lbl_nib((li >> 1) + 1024, li[0]);
            lbl_m2[li]  = lbl_nib((li >> 1) + 2048, li[0]);
            lbl_m3[li]  = lbl_nib((li >> 1) + 3072, li[0]);
            lbl_m4[li]  = lbl_nib((li >> 1) + 4096, li[0]);
            lbl_m5[li]  = lbl_nib((li >> 1) + 5120, li[0]);
            lbl_m6[li]  = lbl_nib((li >> 1) + 6144, li[0]);
            lbl_m7[li]  = lbl_nib((li >> 1) + 7168, li[0]);
            lbl_m8[li]  = lbl_nib((li >> 1) + 8192, li[0]);
            lbl_m9[li]  = lbl_nib((li >> 1) + 9216, li[0]);
            lbl_m10[li] = lbl_nib((li >> 1) + 10240, li[0]);
            lbl_m11[li] = lbl_nib((li >> 1) + 11264, li[0]);
        end
    end
    function [4:0] slot_gid;
        input [2:0] st;
        input [2:0] s;
        input [3:0] ds, dt;
        input       lo;
        begin
            case (st)
                3'd1: case (s)                       // IDLE: line 2 = 16..18, line 1 = 14, 15
                          3'd0:    slot_gid = 5'd16;
                          3'd1:    slot_gid = 5'd17;
                          3'd2:    slot_gid = 5'd18;
                          3'd3:    slot_gid = 5'd14;
                          default: slot_gid = 5'd15;
                      endcase
                3'd2:    slot_gid = (s == 3'd1) ? 5'd20 : 5'd19;   // DEMO
                3'd3:    slot_gid = (s == 3'd1) ? 5'd22 : 5'd21;   // COUNTDOWN
                default: case (s)                    // PRACTICE (v36)
                          3'd0:    slot_gid = {1'b0, ds};
                          3'd1:    slot_gid = 5'd10;
                          3'd2:    slot_gid = {1'b0, dt};
                          3'd3:    slot_gid = 5'd11;
                          default: slot_gid = lo ? 5'd12 : 5'd13;
                      endcase
            endcase
        end
    endfunction

    // fB: line_y - run B top in 0..eB; fA: line_y - run A top in 0..eA; updated with line_y.
    reg       fB, fA;
    reg [4:0] rB;
    reg [5:0] rA;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fB <= 1'b0; rB <= 5'd0; fA <= 1'b0; rA <= 6'd0;
        end else if (!vsync) begin
            fB <= 1'b0; fA <= 1'b0;
        end else if (line_end) begin
            if (line_y == hyt) begin fB <= 1'b1; rB <= 5'd0; end
            else if (fB) begin rB <= rB + 1'b1; if (rB == eB) fB <= 1'b0; end
            if (line_y == yA) begin fA <= 1'b1; rA <= 6'd0; end
            else if (fA) begin rA <= rA + 1'b1; if (rA == eA) fA <= 1'b0; end
        end
    end
    wire startA = showA && fA && (pixel_x == sxA);
    wire startB = showB && fB && (pixel_x == hsx);
    wire l_start = startA || startB;

    reg        l_act, l_x2, l_isA;
    reg [2:0]  l_s;
    reg [6:0]  l_col;
    reg [13:0] l_addr;
    reg [13:0] p_mem [0:4];
    reg  [6:0]  wm_mem [0:4];                              // per slot: shown width - 1 (filled at cc 20..24)
    wire [6:0]  l_wm1  = wm_mem[l_s];
    wire        l_end  = l_act && (l_col == l_wm1);
    wire        l_last = (l_s == (l_isA ? lastA : 3'd4));
    wire [2:0]  p_ri   = l_start ? (startA ? 3'd0 : fsB) : l_s + 1'b1;
    wire [13:0] p_rd   = p_mem[p_ri];
    wire [13:0] l_inc  = l_addr + 1'b1;
    wire        l_wadv = l_x2 ? (l_col[2:0] == 3'd7) : (l_col[1:0] == 2'd3);
    wire        p_init = (cc >= 5'd20);                    // cc 20..24 -> slot 0..4
    wire [2:0]  p_wi   = p_init ? cc[2:0] - 3'd4 : l_s;
    wire        p_wb   = !blank && !l_start && l_end && (!l_x2 || line_y[0]);
    wire [4:0]  i_gid  = slot_gid(st_l, p_wi, d_s, d_t, hint_lo);
    wire [6:0]  i_w    = sla_w(i_gid);
    wire        i_x2   = x2A && (p_wi <= lastA);           // run A slots are 2x when x2A
    always @(posedge clk) begin
        if (p_init) begin
            p_mem[p_wi]  <= sla_base(i_gid);
            wm_mem[p_wi] <= (i_x2 ? {i_w[5:0], 1'b0} : i_w) - 1'b1;
        end else if (p_wb) p_mem[p_wi] <= l_inc;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l_act <= 1'b0; l_x2 <= 1'b0; l_isA <= 1'b0; l_s <= 3'd0; l_col <= 7'd0; l_addr <= 14'd0;
        end else if (blank) begin
            l_act <= 1'b0;
        end else if (l_start) begin
            l_act <= 1'b1; l_x2 <= startA ? x2A : 1'b0; l_isA <= startA;
            l_s <= p_ri; l_col <= 7'd0; l_addr <= p_rd;
        end else if (l_act) begin
            if (l_end) begin
                l_col <= 7'd0;
                if (l_last) l_act <= 1'b0;
                else begin l_s <= p_ri; l_addr <= p_rd; end
            end else begin
                l_col <= l_col + 1'b1;
                if (l_wadv) l_addr <= l_inc;
            end
        end
    end
    // 12 banks of 2048 x 4 (word address, nibble); bank select registered as one-hot, then AND-OR.
    wire [10:0] l_ra = {l_addr[9:0], l_x2 ? l_col[2] : l_col[1]};
    reg  [3:0]  lq0, lq1, lq2, lq3, lq4, lq5, lq6, lq7, lq8, lq9, lq10, lq11;
    reg  [11:0] l_oh_d;
    reg         l_act_d, l_isA_d, l_sub_d;
    always @(posedge clk) begin
        lq0  <= lbl_m0[l_ra];
        lq1  <= lbl_m1[l_ra];
        lq2  <= lbl_m2[l_ra];
        lq3  <= lbl_m3[l_ra];
        lq4  <= lbl_m4[l_ra];
        lq5  <= lbl_m5[l_ra];
        lq6  <= lbl_m6[l_ra];
        lq7  <= lbl_m7[l_ra];
        lq8  <= lbl_m8[l_ra];
        lq9  <= lbl_m9[l_ra];
        lq10 <= lbl_m10[l_ra];
        lq11 <= lbl_m11[l_ra];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l_act_d <= 1'b0; l_isA_d <= 1'b0; l_sub_d <= 1'b0; l_oh_d <= 12'd0;
        end else begin
            l_act_d <= l_act; l_isA_d <= l_isA;
            l_oh_d  <= 12'd1 << l_addr[13:10];
            l_sub_d <= l_x2 ? l_col[1] : l_col[0];
        end
    end
    wire [3:0] lbl_q = ({4{l_oh_d[0]}}  & lq0)  | ({4{l_oh_d[1]}}  & lq1)  |
                       ({4{l_oh_d[2]}}  & lq2)  | ({4{l_oh_d[3]}}  & lq3)  |
                       ({4{l_oh_d[4]}}  & lq4)  | ({4{l_oh_d[5]}}  & lq5)  |
                       ({4{l_oh_d[6]}}  & lq6)  | ({4{l_oh_d[7]}}  & lq7)  |
                       ({4{l_oh_d[8]}}  & lq8)  | ({4{l_oh_d[9]}}  & lq9)  |
                       ({4{l_oh_d[10]}} & lq10) | ({4{l_oh_d[11]}} & lq11);
    wire [1:0] l_code = l_sub_d ? lbl_q[3:2] : lbl_q[1:0];
    wire       l_nz   = l_act_d && (l_code != 2'd0);
    wire       hint_hit = l_nz && !l_isA_d && in_stage;
    wire       cnt_hit  = l_nz && l_isA_d;

    // ---------------- Sky / channel line colour ----------------
    function [23:0] sky_tab;
        input [4:0] b;
        begin
            case (b)
                5'd4:  sky_tab = 24'hB2DEFC;  5'd5:  sky_tab = 24'hB5DFFC;
                5'd6:  sky_tab = 24'hB7E1FC;  5'd7:  sky_tab = 24'hBAE2FC;
                5'd8:  sky_tab = 24'hBDE3FD;  5'd9:  sky_tab = 24'hBFE4FD;
                5'd10: sky_tab = 24'hC2E6FD;  5'd11: sky_tab = 24'hC4E7FD;
                5'd12: sky_tab = 24'hC7E8FD;  5'd13: sky_tab = 24'hCAE9FD;
                5'd14: sky_tab = 24'hCCEBFE;  5'd15: sky_tab = 24'hCFECFE;
                5'd16: sky_tab = 24'hD2EDFE;  5'd17: sky_tab = 24'hD4EEFE;
                5'd18: sky_tab = 24'hD7F0FE;  5'd19: sky_tab = 24'hD9F1FE;
                5'd20: sky_tab = 24'hDCF2FF;  5'd21: sky_tab = 24'hDFF3FF;
                5'd22: sky_tab = 24'hE1F5FF;  5'd23: sky_tab = 24'hE4F6FF;
                default: sky_tab = 24'h000000;
            endcase
        end
    endfunction
    // channel fill: per channel (sky + C_TUNNEL) >> 1, C_TUNNEL = (170, 240, 140)
    function [23:0] tun_mix;
        input [23:0] s;
        reg [8:0] r, g, b;
        begin
            r = {1'b0, s[23:16]} + 9'd170;
            g = {1'b0, s[15:8]}  + 9'd240;
            b = {1'b0, s[7:0]}   + 9'd140;
            tun_mix = {r[8:1], g[8:1], b[8:1]};
        end
    endfunction
    // Channel rows 160..287 are exactly b = 10..17.
    function [23:0] line_tab;
        input [4:0] b;
        begin
            case (b)
                5'd10: line_tab = tun_mix(24'hC2E6FD);
                5'd11: line_tab = tun_mix(24'hC4E7FD);
                5'd12: line_tab = tun_mix(24'hC7E8FD);
                5'd13: line_tab = tun_mix(24'hCAE9FD);
                5'd14: line_tab = tun_mix(24'hCCEBFE);
                5'd15: line_tab = tun_mix(24'hCFECFE);
                5'd16: line_tab = tun_mix(24'hD2EDFE);
                5'd17: line_tab = tun_mix(24'hD4EEFE);
                default: line_tab = sky_tab(b);
            endcase
        end
    endfunction
    reg [23:0] line_col;                // follows line_y one clock later (horizontal blanking)
    always @(posedge clk) line_col <= line_tab(line_y[8:4]);

    // ---------------- Output mux ----------------
    // Colour ids: 0..24 spa_pal, 25..27 label codes 1..3, 28 flag face, 29 flag pole,
    // 30 wood, 31 gold, 32 white, 33..35 grass dark / A / B, 36..38 time bar line / used / left,
    // 39 guide card fill (v37).
    function [23:0] color_tab;
        input [5:0] id;
        begin
            case (id)
                6'd25: color_tab = SLA_C1;
                6'd26: color_tab = SLA_C2;
                6'd27: color_tab = SLA_C3;
                6'd28: color_tab = 24'hFF5A5A;
                6'd29: color_tab = 24'h5A3214;
                6'd30: color_tab = 24'h8C5A32;
                6'd31: color_tab = 24'hFFD200;
                6'd32: color_tab = 24'hFFFFFF;
                6'd33: color_tab = 24'h55AA55;
                6'd34: color_tab = 24'h70C266;
                6'd35: color_tab = 24'h78CD6E;
                6'd36: color_tab = 24'hF4F6FF;
                6'd37: color_tab = 24'h33445C;
                6'd38: color_tab = 24'hFF963C;
                6'd39: color_tab = 24'h34406E;
                default: color_tab = spa_pal(id[4:0]);
            endcase
        end
    endfunction
    // v37: priority chain for pixel pxn, registered into ov_bg / ov_col.
    wire [5:0] lbl_cid = 6'd24 + {4'd0, l_code};
    reg  [5:0] cid;
    reg        use_bg, use_line;
    always @(*) begin
        use_bg = 1'b0; use_line = 1'b0; cid = 6'd0;
        if (hint_hit)                                            cid = lbl_cid;
        else if (in_stage && bird_hit)                           cid = {1'b0, spr_b};
        else if (cnt_hit)                                        cid = lbl_cid;
        else if (showCard && ly_card && px_card)                 cid = (ly_cardi && px_cardi) ? 6'd39 : 6'd32;
        else if (in_stage && star_hit)                           cid = {1'b0, star_idx};
        else if (in_stage && nest_hit)                           cid = {1'b0, spr_s};
        else if (in_stage && flag_hit)                           cid = f_pole ? 6'd29 : 6'd28;
        else if (in_stage && ((ly_post && px_post) || (ly_brch && px_brch))) cid = 6'd30;
        else if (in_stage && showArw && ly_shaft && px_shaft && !pxn[3]) cid = ly_shaft_e ? 6'd1 : 6'd6;
        else if (in_stage && cloud_hit)                          cid = {1'b0, cloud_idx};
        else if (in_stage && ly_bord && (in_band || !pxn[3]))    cid = in_band ? 6'd31 : 6'd32;
        else if (in_stage && ly_grass)                           cid = ly_gdark ? 6'd33 :
                                                                       (pxn[4] ^ line_y[4]) ? 6'd34 : 6'd35;
        else if (in_stage)                                       use_line = 1'b1;   // sky or channel fill
        else if (ly_tbo && px_tbo)                               cid = !(ly_tbi && px_tbi) ? 6'd36 :
                                                                       (pxn < tb_end) ? 6'd37 : 6'd38;
        else                                                     use_bg = 1'b1;
    end
    reg        ov_bg;
    reg [23:0] ov_col;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ov_bg <= 1'b1; ov_col <= 24'd0;
        end else begin
            ov_bg  <= use_bg;
            ov_col <= use_line ? line_col : color_tab(cid);
        end
    end

    assign rgb_out = (!enable || !de || ov_bg) ? rgb_in : ov_col;

endmodule
