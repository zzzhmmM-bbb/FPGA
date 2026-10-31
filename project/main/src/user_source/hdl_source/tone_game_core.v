`timescale 1ns/1ps
// tone_game_core: v34 level-2 ("bird eats stars") tone judge. Bit-exact to
// the Python golden model (constants from tone_tables.vh).
// All signals in the video_clk domain, rst_n asynchronous active low, all outputs registered.
//
// pract rising edge: clears the real-time state, post_done and the post FSM (the other
//   post outputs are only defined while post_done=1 and are rewritten by every post run).
//   A frame_start in the same clock as the pract rising edge is not sampled.
// v34: window N_FRAMES = 240; rec_f0 = first good sampled frame (0 if none), rec_go = 1
//   from that sample on (set in the sampling clock), cleared at the pract falling edge.
//   Play line (ALGO 6.8): practice frame f = rec_f0 + play_f, n = f - seg_start.
// Real time (ALGO 5): each sampled frame_start starts a 6-clock step (R_MED..R_S).
//   The 3-point median is taken in the code domain (h2,h1,c); the step also writes
//   sm[e] = {good, P(smc)} (11 bit) into the 256 x 11 buffer, i.e. the buffer holds the
//   ALGO 6.1 median output directly (identical: P is strictly increasing on 2..62).
//   After the 240th sample one extra step writes sm[239] = {good, P(code[239])} and the
//   post-processing starts.
// Post (ALGO 6, one serial FSM, ~1.4k clocks): segmentation with gap/backtrack ->
//   longest run -> rescan (x[] written back in place, x2..x4 captured) -> s0 ->
//   16 stars (L*c_k by repeated addition of L) -> kmax -> curve DDA into the 360 x 9 RAM.
//   Every buffer read takes 2 clocks (address register -> wait -> registered data).
// play_x (ALGO 6.8): after post_done the FSM waits for play_f changes and reruns the curve
//   DDA (acc += L, acc >= 360 -> fi++) from column 0: floor(n*360/L) = the largest column
//   count c with c*L <= n*360, i.e. step while (fi < n) or (fi == n and acc == 0)
//   (<= 360 clocks; fi is kept as ra = seg_start + fi, compared with f held in `start`).
// No multipliers / dividers. Storage: 2 inferred BRAM9K (buffer 256x11, curve 512x9)
//   + table ROMs (P, T_k).
module tone_game_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_start,
    input  wire        pract,
    input  wire [1:0]  tone,
    input  wire        f0_valid,
    input  wire [5:0]  f0_code,
    output reg  [8:0]  bird_x,
    output reg  [8:0]  bird_y,
    output reg  [15:0] rt_mask,
    output reg  [7:0]  nv,
    output reg         trail_we,
    output reg  [5:0]  trail_idx,
    output wire [8:0]  trail_y,          // = bird_y register (identical by ALGO 5)
    output reg         post_done,
    output reg         unheard,
    output reg  [7:0]  seg_start,
    output reg  [7:0]  L,
    output reg  [9:0]  s0,
    output reg  [15:0] hit_mask,
    output reg  [4:0]  hits,
    output reg  [1:0]  stars,
    output reg  [6:0]  score,
    output reg  [3:0]  kmax,
    output reg         sign,
    output reg         kmax_valid,
    input  wire [8:0]  curve_raddr,
    output reg  [8:0]  curve_y,
    input  wire [6:0]  play_f,
    output reg  [8:0]  play_x,
    output reg         play_on,
    output reg         rec_go
);
`include "tone_tables.vh"

    function good6;
        input [5:0] c;
        good6 = (c[5:1] != 5'd0) && (c != 6'd63);
    endfunction

    // med3 = max(min(a,b), min(max(a,b),c)), written as 3 parallel compares + 3:1 select
    function [5:0] med3_6;
        input [5:0] a, b, c;
        reg ab, bc, ac;
        begin
            ab = (a < b); bc = (b < c); ac = (a < c);
            if (ab ? (bc) : (!ac && !bc)) med3_6 = b;
            else if (ab ? (!bc && !ac) : ac) med3_6 = a;
            else med3_6 = c;
        end
    endfunction

    function [9:0] med3_10;
        input [9:0] a, b, c;
        reg ab, bc, ac;
        begin
            ab = (a < b); bc = (b < c); ac = (a < c);
            if (ab ? (bc) : (!ac && !bc)) med3_10 = b;
            else if (ab ? (!bc && !ac) : ac) med3_10 = a;
            else med3_10 = c;
        end
    endfunction

    // ------------------------------------------------------------------ state
    localparam [2:0] R_IDLE = 3'd0, R_MED = 3'd1, R_P = 3'd2, R_W = 3'd3, R_Y = 3'd4, R_S = 3'd5;
    localparam [3:0] P_IDLE = 4'd0, P_SEEK = 4'd1, P_IN = 4'd2, P_RSI = 4'd3, P_RS = 4'd4,
                     P_S0 = 4'd5, P_ST = 4'd6, P_SE = 4'd7, P_DDAI = 4'd8, P_DDA = 4'd9,
                     P_DONE = 4'd10, P_PW = 4'd11, P_PL = 4'd12;

    reg        pract_q;
    wire       rise = pract && !pract_q;
    wire       fall = !pract && pract_q;
    reg [7:0]  rec_f0;                   // first good sampled frame (ALGO 6.8)
    reg [1:0]  tn;                       // tone latched at the pract rising edge
    wire [8:0] y0 = tone_y0(tn);

    reg [2:0]  rs;
    reg [3:0]  ps;
    reg        wt;                       // post: read wait flag
    reg [7:0]  ns;                       // samples taken 0..240
    reg [5:0]  h1, h2, cin, smc;
    reg        gh1, fl;
    reg [9:0]  psm;                      // = tone_p(smc), BRAM ROM read every clock
    reg [9:0]  xa, xb, xc;               // RT: P of good frames 3..5; post: x capture for s0
    reg        st_ok;
    reg [10:0] y_raw;
    reg [4:0]  k;                        // RT: next star not yet passed (0..16); post: star k

    reg [7:0]  j, start, len, fr;        // j: rescan counter; start = play target f in P_PL
    reg [1:0]  gap;
    reg        frnone;
    reg [9:0]  last;
    reg [14:0] acc;                      // m * L
    reg [5:0]  dcnt;
    reg [9:0]  best;
    reg [8:0]  col, dacc;
    reg        pv;                       // play: pf_q valid
    reg [6:0]  pf_q;
    wire       pbusy = (ps == P_PL);

    assign trail_y = bird_y;

    // ------------------------------------------------------------------ buffer 256 x 11
    (* ram_style = "bram" *) reg [10:0] bmem [0:255];
    reg  [7:0]  ra;
    reg         bwe;
    reg  [7:0]  bwa;
    reg  [10:0] bwd;
    reg  [10:0] brd;
    always @(posedge clk) begin
        if (bwe) bmem[bwa] <= bwd;
        brd <= bmem[ra];
    end

    // ------------------------------------------------------------------ curve RAM 360 x 9
    (* ram_style = "bram" *) reg [8:0] cmem [0:511];
    reg         cwe;
    reg  [8:0]  cwa, cwd;
    always @(posedge clk) begin
        if (cwe) cmem[cwa] <= cwd;
        curve_y <= cmem[curve_raddr];
    end

    // ------------------------------------------------------------------ table ROMs (BRAM)
    // P(code): smc changes only in R_MED; psm is used in R_W / R_Y / R_S of the same step.
    // T_k: {tn, k} changes in R_S (RT, used again in the next frame's R_S), at the pract
    // rising edge, in P_S0 / P_SE (used in P_SE after >= 7 P_ST clocks).
    (* rom_style = "bram" *) reg [9:0]  p_rom  [0:63];
    (* rom_style = "bram" *) reg [10:0] tk_rom [0:63];
    reg [10:0] tk; // Declared before its sequential ROM assignment (portable SV).
    integer ti;
    initial for (ti = 0; ti < 64; ti = ti + 1) begin
        p_rom[ti]  = tone_p(ti[5:0]);
        tk_rom[ti] = tone_tk(ti[5:4], ti[3:0]);
    end
    always @(posedge clk) begin
        psm <= p_rom[smc];
        tk  <= tk_rom[{tn, k[3:0]}];
    end

    // ------------------------------------------------------------------ shared datapath
    wire        post_act = (ps != P_IDLE);
    // yc = Y0 + s0 - B : RT y_raw (B = P(smc) once the start exists, else 0; s0 = P(sc) or 0)
    //                    post Y0 - r = Y0 - (x - s0) (B = x from the buffer)
    wire [9:0]  yb  = post_act ? brd[9:0] : (st_ok ? psm : 10'd0);
    wire [10:0] z   = {1'b0, s0} - {1'b0, yb};                 // 11 bit signed
    wire [11:0] yc  = {3'b000, y0} + {z[10], z};
    wire [8:0]  ycl = yc[11] ? TONE_Y_MIN : (yc[10:0] < {2'b00, TONE_Y_MIN}) ? TONE_Y_MIN :
                      (yc[10:0] > {2'b00, TONE_Y_MAX}) ? TONE_Y_MAX : yc[8:0];
    // star compare dd = z + T_k:
    //   RT   y_raw - STAR_Y = (Y0 + z) - (Y0 - T_k)        (STAR_Y = Y0 - T_k for all 64
    //        entries: Y0 - T_k is 142..359, never clamped, checked against the golden model)
    //   post (s0 - x) + T_k = -(r - T_k) = -d
    wire [11:0] dd  = {z[10], z} + {tk[10], tk};
    wire [10:0] dda = dd[11] ? (~dd[10:0] + 11'd1) : dd[10:0];
    wire        dhit = (dda <= 11'd46);
    wire        hg   = dhit && !unheard;
    // segmentation accept: good and |sm - last| <= 91
    wire [10:0] sd  = {1'b0, brd[9:0]} - {1'b0, last};
    wire [10:0] sda = sd[10] ? (~sd + 11'd1) : sd;
    wire        acc_ok = brd[10] && (sda <= 11'd91);
    wire [8:0]  xn9 = bird_x + 9'd9;
    wire        xcross = !k[4] && (tone_star_x(k[3:0]) <= xn9);
    wire [7:0]  ni  = frnone ? ra : fr;              // restart after a break
    wire [7:0]  xi  = j - ((L >= 8'd5) ? 8'd2 : 8'd0);  // rescan capture index
    wire [9:0]  xnew = ((j == 8'd0) || acc_ok) ? brd[9:0] : last;
    wire [7:0]  ra1 = ra + 8'd1;
    // DDA step (curve and play): acc += L ; acc >= 360 -> acc -= 360, fi++ (ra++)
    wire [9:0]  dacc_n = dacc + {2'b00, L};
    wire        dge    = (dacc_n >= 10'd360);
    wire [8:0]  dacc_s = dge ? (dacc_n[8:0] - 9'd360) : dacc_n[8:0];
    wire [7:0]  ra_s   = dge ? ra1 : ra;
    wire        pl_go  = (ra_s < start) || ((ra_s == start) && (dacc_s == 9'd0));
    // f = rec_f0 + play_f (9 bit), n = f - seg_start; shown if 0 <= n < L.
    // Here only f < 256 and f >= seg_start are checked; n >= L is found in P_PL: the DDA
    // would still step after column 359 (col = 499) exactly when n >= L.
    wire [8:0]  pf9    = {1'b0, rec_f0} + {2'b00, play_f};
    wire        pn_on  = !unheard && !pf9[8] && (pf9[7:0] >= seg_start);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pract_q <= 1'b0; tn <= 2'd0; rs <= R_IDLE; ps <= P_IDLE; wt <= 1'b0;
            ns <= 8'd0; h1 <= 6'd0; h2 <= 6'd0; cin <= 6'd0; smc <= 6'd0; gh1 <= 1'b0; fl <= 1'b0;
            xa <= 10'd0; xb <= 10'd0; xc <= 10'd0; st_ok <= 1'b0; y_raw <= 11'd0; k <= 5'd0;
            j <= 8'd0; start <= 8'd0; len <= 8'd0; fr <= 8'd0; gap <= 2'd0; frnone <= 1'b1;
            last <= 10'd0; acc <= 15'd0; dcnt <= 6'd0; best <= 10'd0; col <= 9'd0; dacc <= 9'd0;
            pv <= 1'b0; pf_q <= 7'd0;
            ra <= 8'd0; bwe <= 1'b0; bwa <= 8'd0; bwd <= 11'd0; cwe <= 1'b0; cwa <= 9'd0; cwd <= 9'd0;
            bird_x <= TONE_X0; bird_y <= 9'd0; rt_mask <= 16'd0; nv <= 8'd0;
            trail_we <= 1'b0; trail_idx <= 6'd0;
            post_done <= 1'b0; unheard <= 1'b0; seg_start <= 8'd0; L <= 8'd0; s0 <= 10'd0;
            hit_mask <= 16'd0; hits <= 5'd0; stars <= 2'd0; score <= 7'd0; kmax <= 4'd0;
            sign <= 1'b0; kmax_valid <= 1'b0; play_x <= 9'd0; play_on <= 1'b0;
            rec_f0 <= 8'd0; rec_go <= 1'b0;
        end else begin
            pract_q  <= pract;
            bwe      <= 1'b0;
            cwe      <= 1'b0;
            trail_we <= 1'b0;
            // -------------------------------------------------------------- real time
            case (rs)
            R_IDLE:
                if (frame_start && pract && ns != 8'd240) begin
                    cin <= f0_valid ? f0_code : 6'd0;
                    ns  <= ns + 8'd1;
                    if (!rec_go && f0_valid && good6(f0_code)) begin
                        rec_go <= 1'b1; rec_f0 <= ns;
                    end
                    fl  <= 1'b0;
                    rs  <= R_MED;
                end
            R_MED: begin
                smc <= (!fl && good6(h2) && good6(cin)) ? med3_6(h2, h1, cin) : h1;
                gh1 <= good6(h1);
                rs  <= R_P;
            end
            R_P: rs <= R_W;                  // psm <= tone_p(smc) (ROM below)
            R_W: begin
                bwe <= fl || (ns != 8'd1);
                bwa <= fl ? 8'd239 : ns - 8'd2;
                bwd <= {gh1, psm};
                // x capture shift register (newest in xa): after the 3 captures
                // (nv = 2, 3, 4) {xa, xb, xc} holds the 3rd, 2nd, 1st value.
                if (gh1 && !fl && (nv == 8'd2 || nv == 8'd3 || nv == 8'd4)) begin
                    xa <= psm; xb <= xa; xc <= xb;
                end
                if (fl) begin
                    rs <= R_IDLE;
                    ps <= P_SEEK; ra <= 8'd0; wt <= 1'b0;
                end else
                    rs <= R_Y;
            end
            R_Y: begin
                if (gh1 && nv == 8'd4) begin
                    s0 <= med3_10(xa, xb, xc);      // P(sc)
                    st_ok <= 1'b1;
                end
                rs <= R_S;
            end
            R_S: begin
                trail_idx <= 6'd0;
                if (gh1) begin
                    y_raw   <= yc[10:0];
                    bird_y  <= ycl;
                    nv      <= nv + 8'd1;
                    if (nv < {1'b0, TONE_RT_NMAX}) begin
                        bird_x    <= xn9;
                        trail_we  <= 1'b1;
                        trail_idx <= nv[5:0];
                        if (xcross) begin
                            k <= k + 5'd1;
                            if (dhit) rt_mask[k[3:0]] <= 1'b1;
                        end
                    end
                end
                h2 <= h1;
                h1 <= cin;
                if (ns == 8'd240) begin
                    fl <= 1'b1;
                    rs <= R_MED;
                end else
                    rs <= R_IDLE;
            end
            default: rs <= R_IDLE;
            endcase

            // -------------------------------------------------------------- post
            case (ps)
            P_IDLE: ;                    // started by the RT flush step (R_W)
            // segmentation: ra is the scan pointer (i in SEEK, j in IN)
            P_SEEK:
                if (ra == 8'd240)
                    ps <= P_RSI;
                else if (!wt)
                    wt <= 1'b1;
                else begin
                    wt <= 1'b0;
                    ra <= ra1;
                    if (brd[10]) begin
                        start <= ra; last <= brd[9:0]; len <= 8'd1; gap <= 2'd0; frnone <= 1'b1;
                        ps <= P_IN;
                    end
                end
            P_IN:
                if (ra == 8'd240) begin
                    if (len > L) begin L <= len; seg_start <= start; end
                    ps <= P_RSI;
                end else if (!wt)
                    wt <= 1'b1;
                else begin
                    wt <= 1'b0;
                    if (acc_ok) begin
                        len <= len + {6'd0, gap} + 8'd1; last <= brd[9:0]; gap <= 2'd0; frnone <= 1'b1;
                        ra <= ra1;
                    end else if (gap == 2'd2) begin
                        if (len > L) begin L <= len; seg_start <= start; end
                        ra <= ni; ps <= P_SEEK;
                    end else begin
                        gap <= gap + 2'd1;
                        if (brd[10] && frnone) begin fr <= ra; frnone <= 1'b0; end
                        ra <= ra1;
                    end
                end
            P_RSI: begin
                unheard <= (L < {1'b0, TONE_L_MIN});
                j <= 8'd0; ra <= seg_start; wt <= 1'b0;
                ps <= (L == 8'd0) ? P_S0 : P_RS;
            end
            P_RS:
                if (!wt)
                    wt <= 1'b1;
                else begin
                    wt <= 1'b0;
                    last <= xnew;
                    bwe <= 1'b1; bwa <= ra; bwd <= {1'b1, xnew};
                    // same shift: captures x[xi = 0..2]; L = 1: x0 in xa, L = 2: x0 in xb
                    if (xi == 8'd0 || xi == 8'd1 || xi == 8'd2) begin
                        xa <= xnew; xb <= xa; xc <= xb;
                    end
                    j <= j + 8'd1; ra <= ra1;
                    if (j + 8'd1 == L) ps <= P_S0;
                end
            P_S0: begin
                s0 <= (L == 8'd0) ? 10'd0 : (L == 8'd1) ? xa : (L == 8'd2) ? xb : med3_10(xa, xb, xc);
                acc <= 15'd0; dcnt <= 6'd35; k <= 5'd0; hits <= 5'd0;
                ps <= P_ST;
            end
            // stars: run for every L (unheard: hits/hit_mask/kmax/sign forced to 0)
            P_ST:
                if (dcnt == 6'd0) begin
                    ra <= seg_start + acc[14:7]; wt <= 1'b0; ps <= P_SE;
                end else begin
                    acc <= acc + {7'd0, L}; dcnt <= dcnt - 6'd1;
                end
            P_SE:
                if (!wt)
                    wt <= 1'b1;
                else begin
                    wt <= 1'b0;
                    hit_mask[k[3:0]] <= hg;
                    hits <= hits + {4'd0, hg};
                    if (k == 5'd0 || (!unheard && dda[9:0] > best)) begin
                        best <= dda[9:0]; kmax <= k[3:0]; sign <= dd[11] && !unheard;
                    end
                    if (k == 5'd15)
                        ps <= P_DDAI;
                    else begin
                        k <= k + 5'd1; dcnt <= 6'd6; ps <= P_ST;
                    end
                end
            P_DDAI: begin
                stars <= (hits >= 5'd15) ? 2'd3 : (hits >= 5'd12) ? 2'd2 : (hits >= 5'd8) ? 2'd1 : 2'd0;
                score <= tone_score(hits);
                kmax_valid <= !unheard && !hits[4];
                col <= 9'd0; dacc <= 9'd0; ra <= seg_start; wt <= 1'b0;
                ps <= P_DDA;
            end
            P_DDA:
                if (!wt)
                    wt <= 1'b1;
                else begin
                    wt <= 1'b0;
                    cwe <= 1'b1; cwa <= col; cwd <= unheard ? 9'd0 : ycl;
                    dacc <= dacc_s; ra <= ra_s;
                    col <= col + 9'd1;
                    if (col == 9'd359) ps <= P_DONE;
                end
            P_DONE: begin
                post_done <= 1'b1; pv <= 1'b0;
                ps <= P_PW;
            end
            // play_x: recompute whenever play_f changes
            P_PW:
                if (!pv || play_f != pf_q) begin
                    pf_q <= play_f; pv <= 1'b1;
                    if (pn_on) begin
                        dacc <= 9'd0; ra <= seg_start; col <= TONE_X0; start <= pf9[7:0]; ps <= P_PL;
                    end else begin
                        play_x <= 9'd0; play_on <= 1'b0;
                    end
                end
            P_PL:
                if (pl_go && col == 9'd499) begin      // n >= L: not shown
                    play_x <= 9'd0; play_on <= 1'b0; ps <= P_PW;
                end else if (pl_go) begin
                    dacc <= dacc_s; ra <= ra_s; col <= col + 9'd1;
                end else begin
                    play_x <= col; play_on <= 1'b1; ps <= P_PW;
                end
            default: ps <= P_IDLE;
            endcase

            // -------------------------------------------------------------- pract rising edge
            if (rise) begin
                tn <= tone; rs <= R_IDLE; ps <= P_IDLE;
                ns <= 8'd0; h1 <= 6'd0; h2 <= 6'd0; st_ok <= 1'b0; k <= 5'd0; s0 <= 10'd0;
                y_raw <= {2'b00, tone_y0(tone)};
                bird_x <= TONE_X0; bird_y <= tone_y0(tone); rt_mask <= 16'd0; nv <= 8'd0;
                post_done <= 1'b0; seg_start <= 8'd0; L <= 8'd0; play_on <= 1'b0; rec_f0 <= 8'd0;
            end
            if (fall) rec_go <= 1'b0;
        end
    end

endmodule
