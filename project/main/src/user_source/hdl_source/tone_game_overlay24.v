`timescale 1ns/1ps
// v33 level 2 "bird eats stars" overlay.
// rgb_in -> rgb_out: 0 clocks (combinational mux). Every BRAM is read with
// the next pixel's coordinate (pxn = pixel_x + 1), so its output lines up with
// the current pixel.
// (v33 LUT fix: the "高了/低了" label at the red ring was removed; the ring stays.)
// Priority (high -> low): play line > red ring > bird > labels > stars >
// student curve / trail > template band > gold card frame > rgb_in.
// Everything except the gold frame is clipped to the stage x 120..519, y 122..381.
// All inputs except trail_we/idx/y and curve_y are latched at frame start; the
// derived values (decimal digits, label layout, ring centre) are
// computed serially in the first ~20 clocks of vertical blanking.
// Stars: one column cursor walks the sorted star table (star windows are
// disjoint in x), so only one star is tested per pixel.
// BRAM9K: sprite ROM 1024x4 (2 read ports), label ROM 2484x8, band ROM 2048x9,
// star table ROM 128x18, decimal ROM 128x8, trail RAM 64x9.
module tone_game_overlay24 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire        enable,        // osd_valid && level_v == 2
    input  wire [1:0]  stage,         // 0 TARGET, 1 COUNT, 2 PRACT, 3 RESULT
    input  wire [1:0]  tone,
    input  wire        target_blink,
    input  wire        play_busy,
    // tone_game_core outputs
    input  wire [8:0]  bird_x,
    input  wire [8:0]  bird_y,
    input  wire [15:0] rt_mask,
    input  wire [7:0]  nv,
    input  wire        trail_we,
    input  wire [5:0]  trail_idx,
    input  wire [8:0]  trail_y,
    input  wire        post_done,
    input  wire        unheard,
    input  wire [7:0]  seg_start,     // unused
    input  wire [7:0]  L,             // unused
    input  wire [9:0]  s0,            // unused
    input  wire [15:0] hit_mask,
    input  wire [4:0]  hits,          // unused (score / kmax_valid carry it)
    input  wire [1:0]  stars,         // unused
    input  wire [6:0]  score,
    input  wire [3:0]  kmax,
    input  wire        sign,
    input  wire        kmax_valid,
    output reg  [8:0]  curve_raddr,   // core curve RAM, synchronous read, 1 clock
    input  wire [8:0]  curve_y,
    input  wire [8:0]  play_x,
    input  wire        play_on,
    output wire [23:0] rgb_out
);
`include "tone_tables.vh"
`include "tone_sprite.vh"
`include "tone_label.vh"

    localparam [23:0] C_GOLD  = 24'hFFD200;
    localparam [23:0] C_RED   = 24'hE02020;
    localparam [23:0] C_CURVE = 24'h1E64D7;
    localparam [23:0] C_TRAIL = 24'hFFFFFF;

    function [23:0] tone_color;
        input [1:0] t;
        begin
            case (t)
                2'd0: tone_color = 24'h4A90E2;
                2'd1: tone_color = 24'h7ED321;
                2'd2: tone_color = 24'hF5A623;
                default: tone_color = 24'hD0021B;
            endcase
        end
    endfunction

    // ---------------- Coordinates ----------------
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
    // Range flags of the current pixel / line, updated with pixel_x / line_y:
    // h_st: pixel_x in 120..519, h_cl: 140..499, v_st: line_y in 122..381.
    reg h_st, h_cl, v_st;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_st <= 1'b0; h_cl <= 1'b0; v_st <= 1'b0;
        end else begin
            if (blank) begin h_st <= 1'b0; h_cl <= 1'b0; end
            else begin
                if (pixel_x == 10'd119) h_st <= 1'b1; else if (pixel_x == 10'd519) h_st <= 1'b0;
                if (pixel_x == 10'd139) h_cl <= 1'b1; else if (pixel_x == 10'd499) h_cl <= 1'b0;
            end
            if (!vsync) v_st <= 1'b0;
            else if (de_q && !de) begin
                if (line_y == 10'd121) v_st <= 1'b1; else if (line_y == 10'd381) v_st <= 1'b0;
            end
        end
    end
    // Cursor starts compare pixel_x with (target - 2), i.e. pixel_x + 2 == target.

    // ---------------- Frame latch ----------------
    reg [1:0]  st_l, tone_l;
    reg        blink_l, pd_l, unh_l, kv_l, pl_l;
    reg [8:0]  bx_l, by_l, pxl_l;     // bx_l = bird_x - 18, by_l = bird_y - 15
    reg [15:0] rtm_l, hm_l;
    reg [5:0]  ntr_l;
    reg [6:0]  score_l;
    reg [3:0]  kmax_l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_l <= 2'd0; tone_l <= 2'd0; blink_l <= 1'b0; pd_l <= 1'b0; unh_l <= 1'b1;
            kv_l <= 1'b0; pl_l <= 1'b0; bx_l <= 9'd122; by_l <= 9'd127;
            pxl_l <= 9'd0; rtm_l <= 16'd0; hm_l <= 16'd0; ntr_l <= 6'd0; score_l <= 7'd0;
            kmax_l <= 4'd0;
        end else if (frame_start) begin
            st_l <= stage; tone_l <= tone; blink_l <= target_blink; pd_l <= post_done;
            unh_l <= unheard; kv_l <= kmax_valid; pl_l <= play_busy && play_on;
            bx_l <= bird_x - 9'd18; by_l <= bird_y - 9'd15; pxl_l <= play_x; rtm_l <= rt_mask; hm_l <= hit_mask;
            ntr_l <= (nv > 8'd40) ? 6'd40 : nv[5:0];
            score_l <= score; kmax_l <= kmax;
        end
    end
    wire m_pr  = (st_l == 2'd2);
    wire m_res = (st_l == 2'd3) && pd_l;
    wire show_curve = m_res && !unh_l;
    wire show_ring  = m_res && kv_l;
    wire show_play  = m_res && pl_l;
    wire [15:0] star_mask = m_pr ? rtm_l : m_res ? hm_l : 16'd0;

    // ---------------- Blanking-time calculation ----------------
    reg [4:0]  cc;            // 0 idle, 1..26 running
    reg        sc_h;
    // Decimal ROM {tens, ones} of 0..99, read at cc 17 (score), used at cc 18.
    // (v33 LUT fix: the practice label "吃到 n/16" was removed; the stars show it.)
    (* rom_style = "bram" *) reg [7:0] dec_rom [0:127];
    integer di;
    initial for (di = 0; di < 128; di = di + 1)
        dec_rom[di] = (di < 100) ? {di[7:0] / 8'd10, 4'd0} | (di[7:0] % 8'd10) : 8'd0;
    reg  [7:0] dec_q;
    always @(posedge clk) dec_q <= dec_rom[score_l];
    wire [3:0] d_t = dec_q[7:4], d_o = dec_q[3:0];
    reg [8:0]  sy_c, sx_c;
    reg [3:0]  slot_id [0:7];
    reg [2:0]  lastA;
    reg [9:0]  ax;            // run start x
    reg [8:0]  ay;            // run top row - 1
    reg        showA;
    wire calc = (cc != 5'd0);

    // Star table ROM (BRAM, synchronous read), word = {x field, y field}:
    //   {0, tone, k}: {star_x - 10, star_y - 8}  star cursor (window start - 2, window top)
    //   {1, tone, k}: {star_x - 15, star_y}      blanking calc (kmax neighbourhood)
    // Address: calc ? {1, tone_l, kmax} : {0, tone_l, s_kn};
    // s_kn only changes at a star start (>= 16 clocks apart) or in blanking, so st_q
    // always holds the entry of the current s_kn when the cursor compares it.
    (* rom_style = "bram" *) reg [17:0] st_rom [0:127];
    integer sti;
    initial for (sti = 0; sti < 128; sti = sti + 1)
        st_rom[sti] = sti[6] ? {tone_star_x(sti[3:0]) - 9'd15, tone_star_y(sti[5:4], sti[3:0])}
                             : {tone_star_x(sti[3:0]) - 9'd10, tone_star_y(sti[5:4], sti[3:0]) - 9'd8};
    reg  [4:0]  s_kn;         // next star to start (0..16)
    reg  [3:0]  s_k;          // star under the cursor
    reg  [8:0]  s_y8;         // star_y - 8 of s_k
    reg  [17:0] st_q;
    wire [3:0]  st_k = !calc ? s_kn[3:0] : kmax_l;
    always @(posedge clk) st_q <= st_rom[{calc, tone_l, st_k}];
    wire [8:0] sy_tab = st_q[8:0];                      // calc: star_y of the entry read at cc - 1
    wire [8:0] sx_tab = st_q[17:9];                     // calc: star_x - 15 (star x >= 140)
    wire [9:0] sx_m10 = {1'b0, st_q[17:9]};             // cursor: star_x - 10 of s_kn


    integer si;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cc <= 5'd0; sc_h <= 1'b0;
            sy_c <= 9'd0; sx_c <= 9'd0;
            lastA <= 3'd0; ax <= 10'd0; ay <= 9'd0; showA <= 1'b0;
            for (si = 0; si < 8; si = si + 1) slot_id[si] <= 4'd0;
        end else if (frame_start) begin
            cc <= 5'd1;
            sc_h <= (score >= 7'd100);
        end else if (calc) begin
            cc <= (cc == 5'd26) ? 5'd0 : cc + 1'b1;
            if (cc == 5'd3) begin sy_c <= sy_tab; sx_c <= sx_tab; end
            if (cc == 5'd18) begin
                // run A: result "贴合度 NN 分" only
                showA <= m_res && !unh_l;
                ax <= 10'd124;
                ay <= (tone_l == 2'd1 || tone_l == 2'd2) ? 9'd125 : 9'd355;
                slot_id[0] <= 4'd12;
                if (sc_h) begin
                    lastA <= 3'd4;
                    slot_id[1] <= 4'd1; slot_id[2] <= 4'd0; slot_id[3] <= 4'd0; slot_id[4] <= 4'd11;
                end else if (d_t != 4'd0) begin
                    lastA <= 3'd3;
                    slot_id[1] <= d_t; slot_id[2] <= d_o; slot_id[3] <= 4'd11;
                end else begin
                    lastA <= 3'd2;
                    slot_id[1] <= d_o; slot_id[2] <= 4'd11;
                end
            end
        end
    end

    // ---------------- Sprite ROM (stars + bird) ----------------
    (* rom_style = "bram" *) reg [3:0] spr_rom [0:1023];
    integer ri;
    initial for (ri = 0; ri < 1024; ri = ri + 1) spr_rom[ri] = spr_px(ri[9:8], ri[7:4], ri[3:0]);

    // Star cursor: state describes pixel pixel_x + 1.
    reg       s_act;
    reg [3:0] s_col;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_act <= 1'b0; s_kn <= 5'd0; s_k <= 4'd0; s_col <= 4'd0; s_y8 <= 9'd0;
        end else if (blank) begin
            s_act <= 1'b0; s_kn <= 5'd0;
        end else if (!s_kn[4] && pixel_x == sx_m10) begin
            s_act <= 1'b1; s_k <= s_kn[3:0]; s_col <= 4'd0; s_kn <= s_kn + 1'b1; s_y8 <= st_q[8:0];
        end else if (s_act) begin
            if (s_col == 4'd15) s_act <= 1'b0;
            s_col <= s_col + 1'b1;
        end
    end
    wire [9:0] s_row = line_y - {1'b0, s_y8};
    wire       s_in  = s_act && (s_row < 10'd16);
    wire [9:0] s_addr = {star_mask[s_k] ? 2'd1 : 2'd2, s_row[3:0], s_col};

    // Bird: 32x28 window around (bird_x, bird_y), 2x upscale.
    // b_h / b_dx = pxn - (bird_x - 16) while it is 0..31 (counter: starts when the next
    // clock's pxn is bird_x - 16, i.e. pixel_x == bird_x - 18); b_v / b_dy = line_y -
    // (bird_y - 14) while it is 0..27 (updated with line_y: starts when the new line is
    // bird_y - 14, i.e. the old line_y == bird_y - 15). bird_x >= 140, bird_y >= 124.
    reg       b_h, b_v;
    reg [4:0] b_dx, b_dy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_h <= 1'b0; b_v <= 1'b0; b_dx <= 5'd0; b_dy <= 5'd0;
        end else begin
            if (blank) b_h <= 1'b0;
            else if (pixel_x == {1'b0, bx_l}) begin b_h <= 1'b1; b_dx <= 5'd0; end
            else if (b_h) begin
                b_dx <= b_dx + 1'b1;
                if (b_dx == 5'd31) b_h <= 1'b0;
            end
            if (!vsync) b_v <= 1'b0;
            else if (de_q && !de) begin
                if (line_y == {1'b0, by_l}) begin b_v <= 1'b1; b_dy <= 5'd0; end
                else if (b_v) begin
                    b_dy <= b_dy + 1'b1;
                    if (b_dy == 5'd27) b_v <= 1'b0;
                end
            end
        end
    end
    wire       b_in = m_pr && b_h && b_v;
    wire [9:0] b_addr = {2'd0, b_dy[4:1], b_dx[4:1]};

    reg [3:0] spr_s, spr_b;
    reg       s_in_d, b_in_d;
    always @(posedge clk) begin
        spr_s <= spr_rom[s_addr];
        spr_b <= spr_rom[b_addr];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin s_in_d <= 1'b0; b_in_d <= 1'b0; end
        else begin s_in_d <= s_in; b_in_d <= b_in; end
    end
    wire star_hit = s_in_d && (spr_s != 4'd0);
    wire bird_hit = b_in_d && (spr_b != 4'd0);

    // ---------------- Label ROM (3 x 1024 x 8) ----------------
    // Each slot keeps a pointer p_mem[s] to the start of its current glyph row:
    // set to lbl_base(id) in blanking, advanced by write-back (last word + 1)
    // after the glyph has been scanned on a line. No row * wq multiplication.
    (* rom_style = "bram" *) reg [7:0] lbl_m0 [0:1023];
    (* rom_style = "bram" *) reg [7:0] lbl_m1 [0:1023];
    (* rom_style = "bram" *) reg [7:0] lbl_m2 [0:1023];   // words 2048..2483 used
    integer li;
    initial begin
        for (li = 0; li < 1024; li = li + 1) begin
            lbl_m0[li] = lbl_rom(li);
            lbl_m1[li] = lbl_rom(li + 1024);
            lbl_m2[li] = lbl_rom(li + 2048);
        end
    end

    // fA: line_y - top row in 0..22 (LBL_H rows), updated with line_y (top >= 103).
    reg       fA;
    reg [4:0] rA;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fA <= 1'b0; rA <= 5'd0;
        end else if (!vsync) begin
            fA <= 1'b0;
        end else if (de_q && !de) begin
            if (line_y == {1'b0, ay}) begin fA <= 1'b1; rA <= 5'd0; end
            else if (fA) begin rA <= rA + 1'b1; if (rA == 5'd22) fA <= 1'b0; end
        end
    end
    wire inA = showA && fA;

    reg        l_act;
    reg [2:0]  l_s;
    reg [6:0]  l_col;
    reg [11:0] l_addr;
    reg [11:0] p_mem [0:7];
    wire [3:0]  l_id   = slot_id[l_s];
    wire [6:0]  l_wm1  = lbl_w(l_id) - 1'b1;
    wire        startA = inA && (pixel_x == ax);
    wire        l_end  = l_act && (l_col == l_wm1);
    wire        l_last = (l_s == lastA);
    wire [2:0]  p_ri   = startA ? 3'd0 : l_s + 1'b1;
    wire [11:0] p_rd   = p_mem[p_ri];
    wire [11:0] l_inc  = l_addr + 1'b1;
    wire        p_init = (cc >= 5'd19);                 // cc 19..26 -> slot 0..7
    wire [2:0]  p_wi   = p_init ? cc[2:0] - 3'd3 : l_s;
    always @(posedge clk) begin
        if (p_init) p_mem[p_wi] <= lbl_base(slot_id[p_wi]);
        else if (!blank && !startA && l_end) p_mem[p_wi] <= l_inc;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l_act <= 1'b0; l_s <= 3'd0; l_col <= 7'd0; l_addr <= 12'd0;
        end else if (blank) begin
            l_act <= 1'b0;
        end else if (startA) begin
            l_act <= 1'b1; l_s <= p_ri; l_col <= 7'd0; l_addr <= p_rd;
        end else if (l_act) begin
            if (l_end) begin
                l_col <= 7'd0;
                if (l_last) l_act <= 1'b0;
                else begin l_s <= p_ri; l_addr <= p_rd; end
            end else begin
                l_col <= l_col + 1'b1;
                if (l_col[1:0] == 2'd3) l_addr <= l_inc;
            end
        end
    end
    reg  [7:0] lq0, lq1, lq2;
    reg  [1:0] l_bank_d;
    reg        l_act_d;
    reg  [1:0] l_sub_d;
    always @(posedge clk) begin
        lq0 <= lbl_m0[l_addr[9:0]];
        lq1 <= lbl_m1[l_addr[9:0]];
        lq2 <= lbl_m2[l_addr[9:0]];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin l_act_d <= 1'b0; l_sub_d <= 2'd0; l_bank_d <= 2'd0; end
        else begin l_act_d <= l_act; l_sub_d <= l_col[1:0]; l_bank_d <= l_addr[11:10]; end
    end
    wire [7:0] lbl_q = (l_bank_d == 2'd0) ? lq0 : (l_bank_d == 2'd1) ? lq1 : lq2;
    wire [1:0] l_code = lbl_q >> {l_sub_d, 1'b0};
    wire lbl_hit = l_act_d && (l_code != 2'd0);

    // ---------------- Template band ROM (stores template y - 46) ----------------
    (* rom_style = "bram" *) reg [8:0] band_rom [0:2047];
    integer bi;
    initial for (bi = 0; bi < 2048; bi = bi + 1)
        band_rom[bi] = (bi[8:0] < 9'd360) ? tone_tpl_y(bi[10:0]) - 9'd46 : 9'd0;
    wire [9:0] col_n = pxn - 10'd140;
    reg  [8:0] band_lo;
    always @(posedge clk) band_lo <= band_rom[{tone_l, col_n[8:0]}];
    wire [9:0] band_d = line_y - {1'b0, band_lo};
    wire in_cols = h_cl;
    wire band_hit = m_res && in_cols && !band_d[9] && (band_d <= 10'd92);

    // ---------------- Student curve (core RAM, read 2 columns ahead) ----------------
    // = clamp(pxn - 137, 0, 359) (column of pixel pxn + 2, one clock early):
    // 0 in blanking, +1 per pixel while pixel_x is 137..495 (flag h_cr).
    reg h_cr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curve_raddr <= 9'd0; h_cr <= 1'b0;
        end else if (blank) begin
            curve_raddr <= 9'd0; h_cr <= 1'b0;
        end else begin
            if (h_cr) curve_raddr <= curve_raddr + 1'b1;
            if (pixel_x == 10'd136) h_cr <= 1'b1; else if (pixel_x == 10'd495) h_cr <= 1'b0;
        end
    end
    // [min - 1, max + 1] of the 3 columns: some value <= y + 1 and some value >= y - 1
    // (values are 124..379, so the -1 / +1 never wrap). Each column value is compared
    // once when it arrives; the two older columns use the delayed compare bits. line_y
    // only changes in horizontal blanking, and every column used on pixels 140..499
    // arrives at pixel_x >= 137 of the same line, so the delayed bits are exact.
    reg       c_le1, c_le2, c_ge1, c_ge2;
    reg       c_lo_ok, c_hi_ok;
    wire [9:0] y_p1 = line_y + 1'b1;
    wire [9:0] y_m1 = line_y - 1'b1;
    wire       c_le0 = ({1'b0, curve_y} <= y_p1);
    wire       c_ge0 = ({1'b0, curve_y} >= y_m1);
    always @(posedge clk) begin
        c_le1 <= c_le0; c_le2 <= c_le1;
        c_ge1 <= c_ge0; c_ge2 <= c_ge1;
        c_lo_ok <= c_le0 || c_le1 || c_le2;
        c_hi_ok <= c_ge0 || c_ge1 || c_ge2;
    end
    wire curve_hit = show_curve && in_cols && c_lo_ok && c_hi_ok;

    // ---------------- Trail (40 x 9, written by core) ----------------
    // BRAM, read with the index of the next clock (t_idx_n), so t_y = trail_mem[t_idx].
    (* ram_style = "bram" *) reg [8:0] trail_mem [0:63];
    reg       t_run;
    reg [5:0] t_idx;
    reg [3:0] t_ph;
    reg [8:0] t_y;
    wire [5:0] t_idx_n = blank ? t_idx : (pixel_x == 10'd146) ? 6'd0 :
                         (t_run && t_ph == 4'd8) ? t_idx + 1'b1 : t_idx;
    always @(posedge clk) begin
        if (trail_we) trail_mem[trail_idx] <= trail_y;
        t_y <= trail_mem[t_idx_n];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            t_run <= 1'b0; t_idx <= 6'd0; t_ph <= 4'd0;
        end else if (blank) begin
            t_run <= 1'b0;
        end else if (pixel_x == 10'd146) begin
            t_run <= 1'b1; t_idx <= 6'd0; t_ph <= 4'd0;
        end else if (t_run) begin
            if (t_ph == 4'd8) begin t_ph <= 4'd0; t_idx <= t_idx + 1'b1; end
            else t_ph <= t_ph + 1'b1;
        end
    end
    wire [9:0] t_dy = line_y + 10'd1 - {1'b0, t_y};
    reg        t_hit_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) t_hit_d <= 1'b0;
        else t_hit_d <= m_pr && t_run && (t_ph <= 4'd2) && (t_idx < ntr_l) && (t_dy <= 10'd2);
    end

    // ---------------- Red ring around star kmax ----------------
    reg [9:0] r_dy;
    always @(posedge clk) r_dy <= line_y - {1'b0, sy_c};
    wire [9:0] r_ady = r_dy[9] ? -r_dy : r_dy;
    // |pixel_x - star_x| for |dx| <= 14: r_m counts 14 .. 0 .. 14 from pixel_x = star_x - 14
    reg       r_on, r_dn;
    reg [3:0] r_m;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_on <= 1'b0; r_dn <= 1'b0; r_m <= 4'd0;
        end else if (blank) begin
            r_on <= 1'b0;
        end else if (pixel_x == {1'b0, sx_c}) begin
            r_on <= 1'b1; r_dn <= 1'b1; r_m <= 4'd14;
        end else if (r_on) begin
            if (r_dn) begin
                r_m <= r_m - 1'b1;
                if (r_m == 4'd1) r_dn <= 1'b0;
            end else begin
                r_m <= r_m + 1'b1;
                if (r_m == 4'd14) r_on <= 1'b0;
            end
        end
    end
    reg [3:0] r_lo, r_hi;
    always @(*) begin
        case (r_ady[3:0])
            4'd0, 4'd1, 4'd2, 4'd3, 4'd4: begin r_lo = 4'd13; r_hi = 4'd14; end
            4'd5:  begin r_lo = 4'd12; r_hi = 4'd14; end
            4'd6:  begin r_lo = 4'd12; r_hi = 4'd13; end
            4'd7:  begin r_lo = 4'd11; r_hi = 4'd13; end
            4'd8:  begin r_lo = 4'd11; r_hi = 4'd12; end
            4'd9:  begin r_lo = 4'd10; r_hi = 4'd11; end
            4'd10: begin r_lo = 4'd9;  r_hi = 4'd11; end
            4'd11: begin r_lo = 4'd7;  r_hi = 4'd10; end
            4'd12: begin r_lo = 4'd5;  r_hi = 4'd8;  end
            4'd13: begin r_lo = 4'd0;  r_hi = 4'd7;  end
            default: begin r_lo = 4'd0; r_hi = 4'd5; end   // 14 (15 excluded below)
        endcase
    end
    wire ring_hit = show_ring && (r_ady < 10'd15) && r_on &&
                    (r_m >= r_lo) && (r_m <= r_hi);

    // ---------------- Play line, gold frame, stage ----------------
    wire p_eq = (pixel_x == {1'b0, pxl_l});
    reg  p_eq_q;                                  // pixel_x - 1 == play_x (same line)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) p_eq_q <= 1'b0;
        else        p_eq_q <= p_eq && !blank;
    end
    wire play_hit = show_play && (p_eq || p_eq_q);

    // Gold frame x0..x0+99 (x0 = 117 + 102 * tone) by y 51..114, minus the inner
    // x0+3..x0+96 by y 54..111. Range flags as h_st / v_st above.
    reg [9:0] g_os, g_oc, g_is, g_ic;     // pixel_x where the outer / inner range starts - 1 / ends
    always @(*) begin
        case (tone_l)
            2'd0:    begin g_os = 10'd116; g_oc = 10'd216; g_is = 10'd119; g_ic = 10'd213; end
            2'd1:    begin g_os = 10'd218; g_oc = 10'd318; g_is = 10'd221; g_ic = 10'd315; end
            2'd2:    begin g_os = 10'd320; g_oc = 10'd420; g_is = 10'd323; g_ic = 10'd417; end
            default: begin g_os = 10'd422; g_oc = 10'd522; g_is = 10'd425; g_ic = 10'd519; end
        endcase
    end
    reg g_ho, g_hi, g_vo, g_vi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_ho <= 1'b0; g_hi <= 1'b0; g_vo <= 1'b0; g_vi <= 1'b0;
        end else begin
            if (blank) begin g_ho <= 1'b0; g_hi <= 1'b0; end
            else begin
                if (pixel_x == g_os) g_ho <= 1'b1; else if (pixel_x == g_oc) g_ho <= 1'b0;
                if (pixel_x == g_is) g_hi <= 1'b1; else if (pixel_x == g_ic) g_hi <= 1'b0;
            end
            if (!vsync) begin g_vo <= 1'b0; g_vi <= 1'b0; end
            else if (de_q && !de) begin
                if (line_y == 10'd50) g_vo <= 1'b1; else if (line_y == 10'd114) g_vo <= 1'b0;
                if (line_y == 10'd53) g_vi <= 1'b1; else if (line_y == 10'd111) g_vi <= 1'b0;
            end
        end
    end
    wire gold_hit = blink_l && g_ho && g_vo && !(g_hi && g_vi);

    wire in_stage = h_st && v_st;

    // ---------------- Output mux ----------------
    // Constant colours share one 32-entry table: 0..15 sprite palette,
    // 16 red, 17..19 label codes 1..3, 20 curve, 21 trail, 22 gold.
    function [23:0] color_tab;
        input [4:0] id;
        begin
            if (!id[4]) color_tab = spr_pal(id[3:0]);
            else case (id[3:0])
                4'd0: color_tab = C_RED;
                4'd1: color_tab = LBL_C1;
                4'd2: color_tab = LBL_C2;
                4'd3: color_tab = LBL_C3;
                4'd4: color_tab = C_CURVE;
                4'd5: color_tab = C_TRAIL;
                default: color_tab = C_GOLD;
            endcase
        end
    endfunction
    reg [4:0] cid;
    reg       use_bg, use_band;
    always @(*) begin
        use_bg = 1'b0; use_band = 1'b0; cid = 5'd22;
        if (!enable || !de)                       use_bg = 1'b1;
        else if (in_stage && (play_hit || ring_hit)) cid = 5'd16;
        else if (in_stage && bird_hit)            cid = {1'b0, spr_b};
        else if (in_stage && lbl_hit)             cid = {3'b100, l_code};
        else if (in_stage && star_hit)            cid = {1'b0, spr_s};
        else if (in_stage && curve_hit)           cid = 5'd20;
        else if (in_stage && t_hit_d)             cid = 5'd21;
        else if (in_stage && band_hit)            use_band = 1'b1;
        else if (!gold_hit)                       use_bg = 1'b1;
    end
    wire [23:0] tcol = tone_color(tone_l);
    wire [8:0] bl_r = {1'b0, rgb_in[23:16]} + {1'b0, tcol[23:16]};
    wire [8:0] bl_g = {1'b0, rgb_in[15:8]}  + {1'b0, tcol[15:8]};
    wire [8:0] bl_b = {1'b0, rgb_in[7:0]}   + {1'b0, tcol[7:0]};
    wire [23:0] band_color = {bl_r[8:1], bl_g[8:1], bl_b[8:1]};

    assign rgb_out = use_bg ? rgb_in : use_band ? band_color : color_tab(cid);

endmodule
