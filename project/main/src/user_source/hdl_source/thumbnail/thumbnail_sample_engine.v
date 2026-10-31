`timescale 1ns/1ps
// T10 cache generator (bit-exact to doc/mockup/thumb_model.py build_cache, big mode).
// Card pixels: 4x4 box average, one aligned four-word read per source row (4 reads,
// all 16 returned words used). Other pixels: sky gradient / shadow / rounded card
// border / missing-card cross mark, then text override. Low 8 bits of every cache word
// carry the flags consumed by thumbnail_video_pipe:
//   bit0 ink, bit2:1 card/label slot (3=none), bit3 focus band, bit4 card, bit5 label ink.
// Geometry is evaluated in registered stages GEO1..GEO4 so no x/y register reaches the
// pixel registers through subtract+compare+color select in a single cycle.
// Four output pixels are accumulated before one BL4 write. No added FIFO/BRAM.
module thumbnail_sample_engine(
    input clk, input rst, input start, input abort,
    input [2:0] valid_slots, input [3:0] source_epoch,
    input [23:0] static_rgb, input static_ready, output static_request,
    input static_ink, input [1:0] static_slot,
    output [9:0] screen_x, output [8:0] screen_y,
    output gen_req, output gen_write, output [20:0] gen_addr,
    output [127:0] gen_wdata, output gen_abort,
    input gen_ack, input gen_valid, input [31:0] gen_data,
    input gen_done, input gen_aborted, input mem_idle,
    output reg ready, output reg [2:0] ready_slots, output reg [3:0] ready_epoch,
    output busy, output pixel_advance
);
    localparam IDLE=0, GEO1=1, RREQ=2, RDATA=3, GEO2=4, WREQ=5, WDONE=6, CANCEL=7, PACK=8,
               GEO3=9, GEO4=10, TEXT=11, DECIDE=12, AVG=13, STORE=14;
    reg [3:0] state;
    reg [9:0] x;
    reg [8:0] y;                 // strip row 0..271 (screen y = y + 64)
    reg [17:0] index;
    reg [127:0] pixels;          // four {RGB, flags} cache words
    reg [20:0] source_addr;
    reg [2:0] mask;
    reg [3:0] epoch;

    // ---- GEO1 registers (from x / y) ----
    reg [9:0] dx0, dx1, dx2;
    reg r0, r1, r2;
    reg [8:0] lyc, lys;          // card / shadow local row
    reg crow, srow;
    reg [9:0] diag;              // missing-card diagonal = strip row - 96
    reg [23:0] sky;
    // ---- GEO2 registers ----
    reg [1:0] k;
    reg [7:0] dx;
    reg [7:0] lo_c, hi_c, lo_2, hi_2, lo_4, hi_4, lo_s, hi_s;
    reg crow2, crow4;
    reg [23:0] shade;
    reg [20:0] row_addr;
    reg [9:0] diag2;
    // ---- GEO3 / GEO4 registers ----
    reg in_card, in_b2, in_b4, in_sh, xmark_a, xmark;
    reg [9:0] dsum;
    // ---- text / decision / average ----
    reg t_ink; reg [1:0] t_slot; reg [23:0] t_rgb;
    reg [31:0] px;
    reg [1:0] rrow;
    reg [11:0] sum_r, sum_g, sum_b;

    // inset(ly) for the 6-row rounded-corner table (6,4,2,1,1,0), mirrored at the bottom.
    function [2:0] inset;
        input [8:0] l;
        case(l)
            9'd0, 9'd119: inset = 3'd6;
            9'd1, 9'd118: inset = 3'd4;
            9'd2, 9'd117: inset = 3'd2;
            9'd3, 9'd116, 9'd4, 9'd115: inset = 3'd1;
            default: inset = 3'd0;
        endcase
    endfunction
    function [7:0] dark75;
        input [7:0] v;
        dark75 = {1'b0, v[7:1]} + {2'b0, v[7:2]};
    endfunction

    wire [2:0] ins_c = inset(lyc);
    wire [2:0] ins_s = inset(lys);
    wire [20:0] slot_base = (k == 2'd1) ? 21'h04b000 : (k == 2'd2) ? 21'h096000 : 21'd0;
    wire cancel = abort || (state != IDLE && source_epoch != epoch);

    assign screen_x = x;
    assign screen_y = y + 9'd64;
    assign busy = (state != IDLE);
    wire advance = (state == PACK && index[1:0] != 2'd3) || (state == WDONE && gen_done);
    assign pixel_advance = advance && !cancel;
    assign static_request = (state == TEXT) && !cancel;
    assign gen_req = (state == RREQ || state == WREQ) && !cancel;
    assign gen_write = (state == WREQ);
    assign gen_addr = (state == RREQ) ? source_addr : 21'h1C2000 + {index[17:2], 2'b00};
    assign gen_wdata = pixels;
    assign gen_abort = cancel || (state == CANCEL);

    // DECIDE: everything below comes from registers.
    wire [7:0] card_flags = {3'b000, 1'b1, !in_b4, k, 1'b0};
    wire [7:0] base_flags = in_card ? card_flags : 8'b0000_0110;
    wire [23:0] base_rgb = in_card ? (!in_b2 ? 24'hffffff : xmark ? 24'h475569 : 24'h111827)
                                   : (in_sh ? shade : sky);
    wire [7:0] text_flags = (t_slot != 2'd3) ? {5'b00100, t_slot, 1'b1} : (base_flags | 8'h07);
    wire need_read = in_card && in_b2 && mask[k] && !t_ink;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state <= IDLE; x <= 0; y <= 0; index <= 0; pixels <= 0; source_addr <= 0; mask <= 0; epoch <= 0;
            ready <= 0; ready_slots <= 0; ready_epoch <= 0;
            dx0 <= 0; dx1 <= 0; dx2 <= 0; r0 <= 0; r1 <= 0; r2 <= 0; lyc <= 0; lys <= 0;
            crow <= 0; srow <= 0; diag <= 0; sky <= 0;
            k <= 2'd3; dx <= 0; lo_c <= 0; hi_c <= 0; lo_2 <= 0; hi_2 <= 0; lo_4 <= 0; hi_4 <= 0;
            lo_s <= 0; hi_s <= 0; crow2 <= 0; crow4 <= 0; shade <= 0; row_addr <= 0; diag2 <= 0;
            in_card <= 0; in_b2 <= 0; in_b4 <= 0; in_sh <= 0; xmark_a <= 0; xmark <= 0; dsum <= 0;
            t_ink <= 0; t_slot <= 2'd3; t_rgb <= 0; px <= 0; rrow <= 0; sum_r <= 0; sum_g <= 0; sum_b <= 0;
        end else begin
            if(ready && (abort || source_epoch != ready_epoch)) ready <= 0;
            if(cancel && state != IDLE && state != CANCEL) begin state <= CANCEL; ready <= 0; end
            else case(state)
                IDLE: if(start && !abort) begin
                    ready <= 0; mask <= valid_slots; epoch <= source_epoch;
                    x <= 0; y <= 0; index <= 0; state <= GEO1;
                end
                GEO1: begin
                    dx0 <= x - 10'd56; dx1 <= x - 10'd240; dx2 <= x - 10'd424;
                    r0 <= (x >= 10'd56 && x < 10'd220);
                    r1 <= (x >= 10'd240 && x < 10'd404);
                    r2 <= (x >= 10'd424 && x < 10'd588);
                    lyc <= y - 9'd116; crow <= (y >= 9'd116 && y <= 9'd235);
                    lys <= y - 9'd120; srow <= (y >= 9'd120 && y <= 9'd239);
                    diag <= {1'b0, y} - 10'd96;
                    // sky(Y) with Y = y + 64: (0x50+(Y>>2), 0xA0+(Y>>3), 0xE0+(Y>>5))
                    sky <= {8'h60 + {1'b0, y[8:2]}, 8'ha8 + {2'b0, y[8:3]}, 8'he2 + {4'b0, y[8:5]}};
                    state <= GEO2;
                end
                GEO2: begin
                    k <= r0 ? 2'd0 : r1 ? 2'd1 : r2 ? 2'd2 : 2'd3;
                    dx <= r0 ? dx0[7:0] : r1 ? dx1[7:0] : r2 ? dx2[7:0] : 8'd0;
                    lo_c <= {5'd0, ins_c};          hi_c <= 8'd159 - ins_c;
                    lo_2 <= 8'd2 + ins_c;           hi_2 <= 8'd157 - ins_c;
                    lo_4 <= 8'd4 + ins_c;           hi_4 <= 8'd155 - ins_c;
                    lo_s <= 8'd4 + ins_s;           hi_s <= 8'd163 - ins_s;
                    crow2 <= crow && lyc >= 9'd2 && lyc <= 9'd117;
                    crow4 <= crow && lyc >= 9'd4 && lyc <= 9'd115;
                    shade <= {dark75(sky[23:16]), dark75(sky[15:8]), dark75(sky[7:0])};
                    row_addr <= ({14'd0, lyc[6:0]} << 11) + ({14'd0, lyc[6:0]} << 9);
                    diag2 <= diag + 10'd2;
                    state <= GEO3;
                end
                GEO3: begin
                    in_card <= crow  && k != 2'd3 && dx >= lo_c && dx <= hi_c;
                    in_b2   <= crow2 && k != 2'd3 && dx >= lo_2 && dx <= hi_2;
                    in_b4   <= crow4 && k != 2'd3 && dx >= lo_4 && dx <= hi_4;
                    in_sh   <= srow  && k != 2'd3 && dx >= lo_s && dx <= hi_s;
                    xmark_a <= ({2'b0, dx} >= diag) && ({2'b0, dx} < diag2);
                    dsum <= {2'b0, dx} + diag;
                    source_addr <= row_addr + (slot_base | {11'd0, dx, 2'b00});
                    state <= GEO4;
                end
                GEO4: begin
                    xmark <= xmark_a || dsum == 10'd158 || dsum == 10'd159;
                    state <= TEXT;
                end
                TEXT: if(static_ready) begin
                    t_ink <= static_ink; t_slot <= static_slot; t_rgb <= static_rgb;
                    state <= DECIDE;
                end
                DECIDE: begin
                    px <= t_ink ? {t_rgb, text_flags} : {base_rgb, base_flags};
                    rrow <= 0; sum_r <= 0; sum_g <= 0; sum_b <= 0;
                    state <= need_read ? RREQ : STORE;
                end
                RREQ: if(gen_ack) state <= RDATA;
                RDATA: begin
                    if(gen_valid) begin
                        sum_r <= sum_r + gen_data[31:24];
                        sum_g <= sum_g + gen_data[23:16];
                        sum_b <= sum_b + gen_data[15:8];
                    end
                    if(gen_done) begin
                        if(rrow == 2'd3) state <= AVG;
                        else begin
                            rrow <= rrow + 1'b1;
                            source_addr <= source_addr + 21'd640;
                            state <= RREQ;
                        end
                    end
                end
                AVG: begin
                    px[31:8] <= {sum_r[11:4], sum_g[11:4], sum_b[11:4]};
                    state <= STORE;
                end
                STORE: begin
                    pixels[index[1:0]*32+:32] <= px;
                    state <= PACK;
                end
                PACK: begin
                    if(index[1:0] == 2'd3) state <= WREQ;
                    else begin
                        index <= index + 1'b1;
                        if(x == 10'd639) begin x <= 0; y <= y + 1'b1; end else x <= x + 1'b1;
                        state <= GEO1;
                    end
                end
                WREQ: if(gen_ack) state <= WDONE;
                WDONE: if(gen_done) begin
                    if(index == 18'd174079) begin
                        ready <= |mask; ready_slots <= mask; ready_epoch <= epoch; state <= IDLE;
                    end else begin
                        index <= index + 1'b1;
                        if(x == 10'd639) begin x <= 0; y <= y + 1'b1; end else x <= x + 1'b1;
                        state <= GEO1;
                    end
                end
                CANCEL: if(mem_idle) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
