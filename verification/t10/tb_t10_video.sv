`timescale 1ns/1ps
// T10 video_pipe bench. Raw timing + coordinate counters exactly as top_tf_hdmi_audio.v,
// FIFO model: data appears the cycle after read_en. Two DUTs share all inputs:
//   new  = thumbnail_video_pipe (T10)
//   t9   = thumbnail_video_pipe_t9 (T9 original, renamed copy)
// Thumbnail mode: frame 2 output compared pixel by pixel with render_after (+GOLD).
// Always compared against T9: read_en/hs_out/vs_out/de_out every cycle; rgb every cycle
// while mode_thumb=0.  +THUMB=<0|1> +CACHE=<cache.mem> +GOLD=<frame.mem> +FOCUS=<n> +VALID=<n>
module tb_t10_video;
reg clk=0;always #20 clk=~clk;
reg rst=1,mode=0,fault=0;reg [1:0] focus=0;reg [2:0] valid=7;
localparam HT=700,VT=500,VA0=10;
integer h=0,v=0;
wire de_raw=(h<640)&&(v>=VA0)&&(v<VA0+480);
wire hs_raw=!(h>=660 && h<680);
wire vs_raw=!(v<2);
reg [9:0] tx=0,ty=0;reg vsq=0;
always @(posedge clk)begin
 if(rst)begin vsq<=0;tx<=0;ty<=0;end
 else begin
  vsq<=vs_raw;
  if(!vs_raw)begin tx<=0;ty<=0;end
  else if(de_raw)begin if(tx==639)begin tx<=0;ty<=ty+1'b1;end else tx<=tx+1'b1;end
 end
end
wire frame_start=vsq && !vs_raw;
reg [31:0] fifo=0;integer ptr=0;
reg [31:0] cache[0:174079];reg [23:0] gold[0:307199];
wire re_n,hs_n,vs_n,de_n,re_o,hs_o,vs_o,de_o;wire [23:0] rgb_n,rgb_o;
thumbnail_video_pipe dut(.clk(clk),.rst(rst),.mode_thumb(mode),.frame_start(frame_start),.focus(focus),
 .valid_slots(valid),.fault(fault),.hs(hs_raw),.vs(vs_raw),.de(de_raw),.x(tx),.y(ty),.fifo_data(fifo),
 .read_en(re_n),.hs_out(hs_n),.vs_out(vs_n),.de_out(de_n),.rgb(rgb_n));
thumbnail_video_pipe_t9 ref9(.clk(clk),.rst(rst),.mode_thumb(mode),.frame_start(frame_start),.focus(focus),
 .valid_slots(valid),.fault(fault),.hs(hs_raw),.vs(vs_raw),.de(de_raw),.x(tx),.y(ty),.fifo_data(fifo),
 .read_en(re_o),.hs_out(hs_o),.vs_out(vs_o),.de_out(de_o),.rgb(rgb_o));
integer frame=0,outpix=0,bad=0,ctl_bad=0,rgb9_bad=0,cmp9=0,checked=0,thumb=1,fv,ff,reads=0,seed=1;
string cache_f,gold_f;
always @(posedge clk)begin
 if(!rst)begin
  if(h==HT-1)begin h<=0;if(v==VT-1)begin v<=0;frame<=frame+1;end else v<=v+1;end else h<=h+1;
  if(!vs_raw)ptr<=0;
  if(re_n)begin
   reads=reads+1;
   if(thumb)begin fifo<=cache[ptr];ptr<=ptr+1;end else fifo<=$random(seed);
  end else if(!thumb)fifo<=$random(seed); // non-thumb: data changes freely between reads too
 end
end
always @(negedge clk)if(!rst)begin
 if({re_n,hs_n,vs_n,de_n}!=={re_o,hs_o,vs_o,de_o})ctl_bad=ctl_bad+1;
 if(!mode)begin cmp9=cmp9+1;if(rgb_n!==rgb_o)rgb9_bad=rgb9_bad+1;end
 if(!vs_n)outpix=0;
 else if(de_n)begin
  if(thumb && frame==2)begin
   if(rgb_n!==gold[outpix])begin
    if(bad<10)$display("MISMATCH pix=%0d x=%0d y=%0d got=%h exp=%h",outpix,outpix%640,outpix/640,rgb_n,gold[outpix]);
    bad=bad+1;
   end
   checked=checked+1;
  end
  outpix=outpix+1;
 end
end
initial begin
 if(!$value$plusargs("THUMB=%d",thumb))thumb=1;
 if(!$value$plusargs("FOCUS=%d",ff))ff=0;
 if(!$value$plusargs("VALID=%d",fv))fv=7;
 focus=ff;valid=fv;mode=thumb;
 if(thumb)begin
  if(!$value$plusargs("CACHE=%s",cache_f))$fatal(1,"need +CACHE");
  if(!$value$plusargs("GOLD=%s",gold_f))$fatal(1,"need +GOLD");
  $readmemh(cache_f,cache);$readmemh(gold_f,gold);
 end
 #101;rst=0;
 if(thumb)begin
  wait(frame==3);
  $display("T10_VIDEO thumb=1 focus=%0d valid=%b checked_pixels=%0d mismatches=%0d ctl_vs_t9_mismatch_cycles=%0d",
   focus,valid,checked,bad,ctl_bad);
 end else begin
  // non-thumb: random focus/valid, fault pulses, frames 0..3 compared cycle by cycle against T9
  fork
   begin while(frame<4)begin repeat(997)@(negedge clk);focus=$random(seed);valid=$random(seed);end end
   begin while(frame<4)begin repeat(30011)@(negedge clk);fault=1;repeat(53)@(negedge clk);fault=0;end end
  join
  $display("T10_VIDEO thumb=0 compared_cycles=%0d rgb_vs_t9_mismatch_cycles=%0d ctl_vs_t9_mismatch_cycles=%0d reads=%0d",
   cmp9,rgb9_bad,ctl_bad,reads);
 end
 $finish;
end
initial begin #200000000;$fatal(1,"VIDEO_WATCHDOG");end
endmodule
