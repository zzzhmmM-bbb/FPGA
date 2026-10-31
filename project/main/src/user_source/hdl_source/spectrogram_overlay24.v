`timescale 1ns/1ps
// Spectrogram overlay (level 3): scrolling 0-4 kHz spectrogram, newest column
// on the right, low frequency at the bottom.
// Inputs (link protocol v4, from board2_link_rx): one group per pulse,
//   spec_seq = column sequence (2 bit), spec_grp = 0..15,
//   spec_mag[4k+3:4k] = level of point 4*grp+k (0 dark .. 15 bright),
//   point i = 62.5*i Hz, 64 points per column.
// Storage: 128 columns x 64 points x 4 bit in an inferred simple dual-port
// BRAM (one write port, one synchronous read port), address {column, point}.
// Column receive (written straight into the BRAM, no column buffer):
//   wp = newest committed column, the column being filled is always wp+1.
//   New seq: restart the mask with this group. Same seq: take the group only
//   if its mask bit is clear (retransmissions are ignored). Each group is
//   written by a small sequencer as 4 nibbles in 4 clocks.
//   Mask full and (no commit yet or seq != last committed seq): wp = wp+1.
//   Columns are received whether or not the overlay is enabled.
// Display: panel x 112..527, y 330..457; data columns c = (x-128)/3, c = 0..127
// from a divide-by-3 counter. Column c shows buffer column (wp-127+c) mod 128,
// so c = 127 is the newest column and c = 0 (the column being filled) is
// drawn as PAL[0]. Point pt = (457-y) >> 1.
// wp is latched at frame start (stored as wp+1 = buffer column of c = 0), so
// a commit in mid-frame scrolls the picture from the next frame on.
// The read address is issued one pixel ahead (counters run for pixel_x+1),
// so the registered BRAM output belongs to the current pixel.
// Zero clocks of pixel latency (rgb_out is a combinational mux on rgb_in).
module spectrogram_overlay24 (
    input  wire        clk, rst_n, vsync, de,
    input  wire [23:0] rgb_in,
    input  wire        enable,
    input  wire        spec_grp_valid,
    input  wire [1:0]  spec_seq,
    input  wire [3:0]  spec_grp,
    input  wire [15:0] spec_mag,
    output wire [23:0] rgb_out
);
    localparam integer PX0 = 112, PX1 = 527, PY0 = 330, PY1 = 457;
    localparam integer DX0 = 131, DX1 = 511;   // visible data: c = 1..127

    // ---------------- Coordinate generation (from vsync/de) ----------------
    reg [11:0] pixel_x, line_y;
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

    // ---------------- Column receive ----------------
    reg [6:0]  wp;            // newest committed column
    reg [1:0]  fill_seq, last_seq;
    reg [15:0] mask;          // groups already written into column wp+1
    reg        have_commit;
    reg        busy;          // write sequencer running
    reg [1:0]  wcnt;          // point within the group being written
    reg [3:0]  wgrp;
    reg [15:0] wbuf;          // remaining nibbles, wbuf[3:0] written next

    wire [6:0]  slot = wp + 1'b1;
    wire [15:0] gbit = 16'd1 << spec_grp;
    wire seq_new = (spec_seq != fill_seq);
    wire commit  = (&mask) && (!have_commit || fill_seq != last_seq);
    // Groups are >100 us apart; a pulse that meets a busy sequencer or a
    // commit cycle is dropped and taken again from the retransmission.
    wire accept  = spec_grp_valid && (seq_new || !mask[spec_grp]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= 7'd0;
            fill_seq <= 2'd0;
            last_seq <= 2'd0;
            mask <= 16'd0;
            have_commit <= 1'b0;
            busy <= 1'b0;
            wcnt <= 2'd0;
            wgrp <= 4'd0;
            wbuf <= 16'd0;
        end else if (busy) begin
            wbuf <= {4'd0, wbuf[15:4]};
            wcnt <= wcnt + 1'b1;
            if (wcnt == 2'd3) busy <= 1'b0;
        end else if (commit) begin
            wp <= slot;
            last_seq <= fill_seq;
            have_commit <= 1'b1;
        end else if (accept) begin
            fill_seq <= spec_seq;
            mask <= seq_new ? gbit : (mask | gbit);
            busy <= 1'b1;
            wcnt <= 2'd0;
            wgrp <= spec_grp;
            wbuf <= spec_mag;
        end
    end

    // ---------------- Frame-boundary latch ----------------
    reg       enable_l;
    reg [6:0] col0_l;         // buffer column of c = 0 (latched wp + 1)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_l <= 1'b0;
            col0_l <= 7'd1;
        end else if (frame_start) begin
            enable_l <= enable;
            col0_l <= slot;
        end
    end

    // ---------------- Read address, one pixel ahead ----------------
    // During the pixel at pixel_x, (bc, bp) belong to pixel_x+1:
    // bc = buffer column, bp = (x-128) % 3. Loaded for x = 128 at pixel_x = 126.
    reg [6:0] bc;
    reg [1:0] bp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bc <= 7'd0; bp <= 2'd0;
        end else if (pixel_x == 12'd126) begin
            bc <= col0_l; bp <= 2'd0;
        end else if (bp == 2'd2) begin
            bc <= bc + 1'b1; bp <= 2'd0;
        end else begin
            bp <= bp + 1'b1;
        end
    end
    wire [11:0] dy = 12'd457 - line_y;        // point = dy >> 1 inside the panel
    wire [12:0] rd_addr = {bc, dy[6:1]};

    // ---------------- Spectrogram RAM ----------------
    // TD RAM inference: write port + unreset registered read, zero-initialized.
    (*ram_style = "bram"*) reg [3:0] spec_ram [0:8191];
    reg [3:0] rd_q;
    integer i;
    initial for (i = 0; i < 8192; i = i + 1) spec_ram[i] = 4'd0;
    always @(posedge clk) begin
        if (busy) spec_ram[{slot, wgrp, wcnt}] <= wbuf[3:0];
    end
    always @(posedge clk) rd_q <= spec_ram[rd_addr];

    // ---------------- Colour ----------------
    function [23:0] pal;
        input [3:0] v;
        begin
            case (v)
                4'd0:  pal = 24'h000000;  4'd1:  pal = 24'h0B0726;
                4'd2:  pal = 24'h240B4E;  4'd3:  pal = 24'h410967;
                4'd4:  pal = 24'h5D126E;  4'd5:  pal = 24'h781C6D;
                4'd6:  pal = 24'h932567;  4'd7:  pal = 24'hAE305B;
                4'd8:  pal = 24'hC73E4C;  4'd9:  pal = 24'hDC5039;
                4'd10: pal = 24'hED6825;  4'd11: pal = 24'hF7850E;
                4'd12: pal = 24'hFBA40A;  4'd13: pal = 24'hF9C52C;
                4'd14: pal = 24'hF2E660;  default: pal = 24'hFCFEA4;
            endcase
        end
    endfunction

    wire in_panel = (pixel_x >= PX0) && (pixel_x <= PX1) && (line_y >= PY0) && (line_y <= PY1);
    wire in_data  = (pixel_x >= DX0) && (pixel_x <= DX1);
    wire [3:0] lvl = in_data ? rd_q : 4'd0;

    wire draw = enable_l && de && in_panel;
    assign rgb_out = draw ? pal(lvl) : rgb_in;

endmodule
