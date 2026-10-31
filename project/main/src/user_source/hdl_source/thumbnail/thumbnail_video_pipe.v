`timescale 1ns/1ps
// T8 staging: consume at DE[18], latch RGB using DE[19], output sync DE[20].
// T10 thumbnail mode (bit-exact to doc/mockup/thumb_model.py render_after): the cache
// word low byte carries the flags (bit2:1 slot, bit3 focus band, bit4 card, bit5 label
// ink); no coordinate comparators. Outside the strip the sky gradient of the current
// line is output. Non-thumbnail output is unchanged (fifo_data[31:8]).
module thumbnail_video_pipe(
    input clk,input rst,input mode_thumb,input frame_start,
    input [1:0] focus,input [2:0] valid_slots,input fault,
    input hs,input vs,input de,input [9:0] x,input [9:0] y,
    input [31:0] fifo_data,
    output read_en,output hs_out,output vs_out,output de_out,output reg [23:0] rgb
);
    reg [20:0] hp,vp,dp,bp;
    reg [1:0] focus_frame;
    reg [23:0] sky_line;
    always @(posedge clk or posedge rst)
        if(rst)focus_frame<=0;else if(frame_start)focus_frame<=focus;

    // When the first pixel of a line enters stage 19, the raw input is still on that line.
    always @(posedge clk or posedge rst)
        if(rst)sky_line<=0;
        else if(dp[18] && !dp[19])sky_line<={8'h50+y[9:2],8'ha0+{1'b0,y[9:3]},8'he0+{3'b0,y[9:5]}};

    wire [23:0] c=fifo_data[31:8];
    wire [7:0] f=fifo_data[7:0];
    wire [1:0] slot=f[2:1];
    wire [3:0] valid4={1'b0,valid_slots};
    wire slot_valid=valid4[slot];
    wire slot_focus=(slot==focus_frame);
    wire [23:0] dim={{1'b0,c[23:17]}+{3'b0,c[23:19]},{1'b0,c[15:9]}+{3'b0,c[15:11]},{1'b0,c[7:1]}+{3'b0,c[7:3]}};

    assign read_en=dp[18] && (!mode_thumb || bp[18]) && !fault;
    assign hs_out=hp[20];assign vs_out=vp[20];assign de_out=dp[20];
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            hp<=0;vp<=0;dp<=0;bp<=0;rgb<=0;
        end else begin
            hp<={hp[19:0],hs};vp<={vp[19:0],vs};dp<={dp[19:0],de};
            bp<={bp[19:0],(y>=10'd64 && y<=10'd335)};
            if(fault || !dp[19])rgb<=0;
            else if(!mode_thumb)rgb<=c;
            else if(!bp[19])rgb<=sky_line;
            else if(f[4])rgb<=slot_focus ? ((f[3] && slot_valid) ? 24'hfacc15 : c) : dim;
            else if(f[5])rgb<=!slot_valid ? 24'h94a3b8 : slot_focus ? 24'hb45309 : c;
            else rgb<=c;
        end
    end
endmodule
