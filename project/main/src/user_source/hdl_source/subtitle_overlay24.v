`timescale 1ns/1ps
// Subtitle overlay: up to 4 pre-rendered sentences from subtitle_rom (4 bit/pixel,
// [3:2] outline alpha o, [1:0] fill alpha f) composited over rgb_in.
// Zero clocks of pixel latency: rgb_out is combinational on rgb_in and registers.
//
// Compositing (bit-exact with gen_subtitle_rom.py compose()), w(a) = 0/3/5/8,
// blend(b, c, w) = (b*(8-w) + c*w) >> 3 per channel:
//   sa  = o of the same sentence at (x-3, y-3) (0 outside it)
//   p1  = sa ? blend(bg, SH, w(sa)) : bg
//   mc  = blend(OUT, FILL(kind, r), w(f)),  FILL = sub_grad(kind, min(r>>2, 15))
//   out = o ? blend(p1, mc, w(o)) : p1
// OUT = (45,55,90), SH = (20,25,50). mc comes from a 512 x 24 ROM (sub_mc() in
// subtitle_tab.vh) addressed by {kind, seg, f}.
// The blends use the w = 0 / w = 8 cases of the same formula (blend(b,c,0) = b,
// blend(b,c,8) = c), so no select is needed and an idle pixel (o = sa = 0) gives
// rgb_out = rgb_in. Per channel, with k = 8 - w:
//   p1  = P1[21:14], P1 = (bg + SH*2^11) * (k(sa)*2^11 + w(sa))
//         (bits [21:11] of P1 = bg*k + SH*w <= 2040; bg*w <= 2040 stays below)
//   M   = mc * w(o) (registered), Mh = M >> 3, Ml = M & 7
//   q   = P2[21:14], P2 = (p1 + Ml*2^11) * (k(o)*2^11 + 1)
//         (bits [21:11] of P2 = p1*k + Ml <= 2047; p1 stays below)
//   out = Mh + q  = (p1*k + M) >> 3
//
// Shadow: o of every displayed pixel is written into a 4-line x 1024 x 2 bit line
// buffer; the pixel (x, y) reads back o of screen pixel (x-3, y-3). Under the
// caller rules below this is the o of the same sentence at (x-3, y-3).
//
// Rows: the ROM holds every sentence row as w/4 words starting at sub_base(id);
// the last pixel of a row (always a transparent column) is stored as the marker
// SUB_MARKER, which ends the row segment (drawn as o = f = 0). Per-slot row start
// addresses live in a 4-entry RAM (ra_mem): loaded with the base at frame setup,
// written with the next row's start when the marker is seen.
//
// Pipeline (pixel X is shown in clock S6, i.e. while pixel_x = X; LEAD = 6):
//   S0: pixel_x == x0[k] - LEAD && act[k] -> start; ra_mem read; seg = (y-y0)>>2
//   S1: A <= ra_mem[k], ctx <= {kind, seg}
//   S2: A = ROM word address of X, nib = column mod 4 (both free running)
//   S3: ROM word -> nibble -> marker check
//   S4: px = {o, f}; mc ROM read at {kind, seg, f}
//   S5: mc; M = mc * w(o) registered; line buffer read for X at column X - 1
//   S6: combinational blend with rgb_in
//   S8: o of X written to the line buffer at column pixel_x = X + 2, the column
//       read for pixel X + 3 three lines later.
// Line start: a start needs pixel_x = x0 - LEAD >= 10 (x0 >= 16), so all
// look-ahead stages of the first box pixel lie inside the active line; act[] for
// the next line is computed in horizontal blanking (one slot per blank clock).
//
// Frame: en/id/cx/cy/kind and enable are latched at frame_start (registered falling
// edge of vsync) and hold for the frame; enable = 0 (latched) draws nothing, i.e.
// rgb_out = rgb_in for the whole frame (a change of enable acts from the next frame).
// Setup (16 blank clocks after frame_start, 4 per slot): meta words of id from the
// ROM port B (base -> ra_mem; valid, (w>>1)+LEAD -> x0 - LEAD), x0 = cx - (w>>1),
// y0 = cy - (h>>1) with h = SUB_H for all sentences. ids without a sentence (>= 20)
// read valid = 0 and stay off. The line counter ly runs with the constant offset
// SUB_H>>1 (ly = line_y + (h>>1)), so r = ly - cy = line_y - y0.
//
// Caller rules (not checked by the module):
//   * on any screen row, the x ranges [x0, x0+w+3) of different enabled slots
//     whose y range [y0, y0+h+3) contains the row do not overlap;
//   * x0 >= 16, x0 + w + 3 <= 639, y0 >= 2, y0 + h + 3 <= 479;
//   * the inputs follow the 640x480 timing of the other *_overlay24 modules
//     (de high on 640 active pixels per line, >= 8 blank clocks between lines,
//     vsync low for >= 1 line in vertical blanking, >= 20 blank clocks between
//     the vsync falling edge and the first active line).
module subtitle_overlay24 (
    input  wire        clk, rst_n,
    input  wire        vsync, de,          // vsync active low
    input  wire [23:0] rgb_in,
    input  wire        enable,
    input  wire [3:0]  slot_en,
    input  wire [19:0] slot_id,    // slot k: [5k+4:5k]
    input  wire [39:0] slot_cx,    // slot k: [10k+9:10k], sentence centre x
    input  wire [35:0] slot_cy,    // slot k: [9k+8:9k],  sentence centre y
    input  wire [11:0] slot_kind,  // slot k: [3k+2:3k]
    output wire [14:0] shared_addr,
    output wire [10:0] shared_meta_addr,
    input wire [15:0] shared_data, shared_meta_data,
    output wire [23:0] rgb_out
);
`include "subtitle_tab.vh"
    localparam [9:0] LEAD = SUB_LEAD;
    localparam [8:0] HH = SUB_H >> 1;
    localparam [8:0] HV = SUB_H;

    // ---------------- Coordinates (pitch_line_overlay24 convention) ----------------
    // pixel_x as in pitch_line_overlay24; ly = line_y + HH (constant offset).
    // Both are re-initialised every line / frame, so they have no async reset
    // (lets the clear / preset use the register's synchronous set/reset).
    reg [9:0] pixel_x;
    reg [8:0] ly;
    reg de_q, vs_q, frame_start;
    always @(posedge clk) begin
        if (!vsync || !de) pixel_x <= 10'd0;
        else               pixel_x <= pixel_x + 1'b1;
        if (!vsync)            ly <= HH;
        else if (de_q && !de)  ly <= ly + 1'b1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_q <= 1'b0; vs_q <= 1'b1; frame_start <= 1'b0;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            frame_start <= vs_q && !vsync;
        end
    end

    // ---------------- Frame latch ----------------
    reg        enable_l;
    reg [3:0]  sen_l;
    reg [19:0] id_l;
    reg [39:0] cx_l;
    reg [35:0] cy_l;
    reg [11:0] kind_l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_l <= 1'b0; sen_l <= 4'd0; id_l <= 20'd0; cx_l <= 40'd0; cy_l <= 36'd0; kind_l <= 12'd0;
        end else if (frame_start) begin
            enable_l <= enable; sen_l <= slot_en; id_l <= slot_id;
            cx_l <= slot_cx; cy_l <= slot_cy; kind_l <= slot_kind;
        end
    end

    // ---------------- Blank-time sequencer ----------------
    // bc counts blank clocks; su = frame setup (bc 0..15 after frame_start, slot
    // bc[3:2], step bc[1:0]); otherwise slot bc[1:0] gets act[] for line ly.
    reg [3:0] bc;
    reg       su;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bc <= 4'd0; su <= 1'b0;
        end else if (frame_start) begin
            bc <= 4'd0; su <= 1'b1;
        end else if (!de) begin
            bc <= bc + 1'b1;
            if (bc == 4'd15) su <= 1'b0;
        end
    end

    // ---------------- Slot select and parameter mux ----------------
    reg  [9:0] x0_0, x0_1, x0_2, x0_3;
    reg  [3:0] act, ok;
    wire [3:0] hit   = act & {pixel_x == x0_3, pixel_x == x0_2, pixel_x == x0_1, pixel_x == x0_0};
    wire       start = |hit;
    wire [1:0] ssel  = {hit[3] | hit[2], hit[3] | hit[1]};
    wire [1:0] msel  = de ? ssel : (su ? bc[3:2] : bc[1:0]);

    reg [4:0] id_s;
    reg [9:0] cx_s;
    reg [8:0] cy_s;
    reg [2:0] kind_s;
    reg       sen_s, ok_s;
    always @* begin
        case (msel)
            2'd0: begin id_s = id_l[4:0];   cx_s = cx_l[9:0];   cy_s = cy_l[8:0];   kind_s = kind_l[2:0];  end
            2'd1: begin id_s = id_l[9:5];   cx_s = cx_l[19:10]; cy_s = cy_l[17:9];  kind_s = kind_l[5:3];  end
            2'd2: begin id_s = id_l[14:10]; cx_s = cx_l[29:20]; cy_s = cy_l[26:18]; kind_s = kind_l[8:6];  end
            default: begin id_s = id_l[19:15]; cx_s = cx_l[39:30]; cy_s = cy_l[35:27]; kind_s = kind_l[11:9]; end
        endcase
        sen_s = sen_l[msel];
        ok_s  = ok[msel];
    end
    wire [8:0] r_s = ly - cy_s;              // row of line_y in slot msel

    // ---------------- ROM ----------------
    reg  [14:0] A;
    wire [15:0] rd, dob;
    assign shared_addr=A;
    assign shared_meta_addr={5'b11111, id_s, bc[0]};
    assign rd=shared_data;
    assign dob=shared_meta_data;

    // ---------------- Frame setup and per-line flags ----------------
    // step 0: meta word 0 address; 1: dob = base -> ra_mem; 2: dob = {valid, (w>>1)+LEAD}.
    // x0_k holds x0 - LEAD (the pixel_x of the start clock).
    wire       set_ra = su && (bc[1:0] == 2'd1);
    wire       set_x0 = su && (bc[1:0] == 2'd2);
    wire [9:0] x0_new = cx_s - {2'b00, dob[7:0]};
    always @(posedge clk) begin
        if (set_x0 && bc[3:2] == 2'd0) x0_0 <= x0_new;
        if (set_x0 && bc[3:2] == 2'd1) x0_1 <= x0_new;
        if (set_x0 && bc[3:2] == 2'd2) x0_2 <= x0_new;
        if (set_x0 && bc[3:2] == 2'd3) x0_3 <= x0_new;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ok <= 4'd0; act <= 4'd0;
        end else begin
            if (set_x0) ok[bc[3:2]] <= dob[15] && sen_s && enable_l;
            if (!de && !su) act[bc[1:0]] <= ok_s && (r_s < HV);
        end
    end

    // ---------------- Row engine ----------------
    reg        st1, inb, inb1;
    reg [1:0]  cur1, cur, nib, nib1;
    reg [6:0]  ctx1, ctx, ctx2, ctx3;
    reg [3:0]  nibv;
    always @* case (nib1)
        2'd0: nibv = rd[3:0]; 2'd1: nibv = rd[7:4]; 2'd2: nibv = rd[11:8]; default: nibv = rd[15:12];
    endcase
    wire wb = inb1 && (nibv == SUB_MARKER);  // row end: A = start of the next row

    (*ram_style = "bram"*) reg [14:0] ra_mem [0:3];
    reg [14:0] ra_q;
    always @(posedge clk) begin
        if (set_ra || wb) ra_mem[su ? bc[3:2] : cur] <= su ? dob[14:0] : A;
        ra_q <= ra_mem[msel];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st1 <= 1'b0; cur1 <= 2'd0; ctx1 <= 7'd0; A <= 15'd0; inb <= 1'b0; nib <= 2'd0;
            cur <= 2'd0; ctx <= 7'd0; inb1 <= 1'b0; nib1 <= 2'd0; ctx2 <= 7'd0;
        end else begin
            st1 <= start; cur1 <= ssel; ctx1 <= {kind_s, r_s[5:2]};
            if (st1) begin
                A <= ra_q; inb <= 1'b1; nib <= 2'd0; cur <= cur1; ctx <= ctx1;
            end else begin
                nib <= nib + 1'b1;
                if (nib == 2'd3) A <= A + 1'b1;
                if (wb) inb <= 1'b0;
            end
            inb1 <= inb && !wb; nib1 <= nib; ctx2 <= ctx;
        end
    end

    // ---------------- Pixel pipeline ----------------
    reg [3:0]  px;
    reg [1:0]  o5, o6, o7, o8;
    reg [23:0] mc5;
    reg [10:0] mr6, mg6, mb6;
    reg [3:0]  k6;
    (*rom_style = "bram"*) reg [23:0] mc_rom [0:511];
    integer i;
    initial for (i = 0; i < 512; i = i + 1) mc_rom[i] = sub_mc(i[8:0]);
    always @(posedge clk) mc5 <= mc_rom[{ctx3, px[1:0]}];

    function [3:0] wgt;    // w(a)
        input [1:0] a;
        begin
            case (a) 2'd0: wgt = 4'd0; 2'd1: wgt = 4'd3; 2'd2: wgt = 4'd5; default: wgt = 4'd8; endcase
        end
    endfunction
    wire [3:0] w5 = wgt(o5);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            px <= 4'd0; ctx3 <= 7'd0; o5 <= 2'd0; o6 <= 2'd0; o7 <= 2'd0; o8 <= 2'd0;
            mr6 <= 11'd0; mg6 <= 11'd0; mb6 <= 11'd0; k6 <= 4'd8;
        end else begin
            px   <= (inb1 && !wb) ? nibv : 4'd0;
            ctx3 <= ctx2;
            o5   <= px[3:2];
            mr6  <= mc5[23:16] * w5;
            mg6  <= mc5[15:8]  * w5;
            mb6  <= mc5[7:0]   * w5;
            k6   <= 4'd8 - w5;
            o6 <= o5; o7 <= o6; o8 <= o7;
        end
    end

    // ---------------- Shadow line buffer ----------------
    (*ram_style = "bram"*) reg [1:0] lb [0:4095];
    reg [1:0] sa;
`ifdef SIMULATION
    integer j;
    initial for (j = 0; j < 4096; j = j + 1) lb[j] = 2'd0;
`endif
    always @(posedge clk) begin
        if (de) lb[{ly[1:0], pixel_x}] <= o8;
        sa <= lb[{ly[1:0] + 2'd1, pixel_x}];
    end

    // ---------------- Blend (combinational with rgb_in) ----------------
    wire [3:0]  ws  = wgt(sa);
    wire [14:0] b1  = {4'd8 - ws, 7'd0, ws};
    wire [14:0] b2  = {k6, 10'd0, 1'b1};
    wire [16:0] a1r = {6'd20, 3'd0, rgb_in[23:16]};
    wire [16:0] a1g = {6'd25, 3'd0, rgb_in[15:8]};
    wire [16:0] a1b = {6'd50, 3'd0, rgb_in[7:0]};
    wire [31:0] p1r = a1r * b1, p1g = a1g * b1, p1b = a1b * b1;
    wire [13:0] a2r = {mr6[2:0], 3'd0, p1r[21:14]};
    wire [13:0] a2g = {mg6[2:0], 3'd0, p1g[21:14]};
    wire [13:0] a2b = {mb6[2:0], 3'd0, p1b[21:14]};
    wire [28:0] p2r = a2r * b2, p2g = a2g * b2, p2b = a2b * b2;
    assign rgb_out = {mr6[10:3] + p2r[21:14], mg6[10:3] + p2g[21:14], mb6[10:3] + p2b[21:14]};

endmodule
