`timescale 1ns/1ps
// T10 cache builder bench: builder + text_serial + shared_rom(SIMULATION) + arbiter +
// App-port SDRAM behaviour model. Dumps all 174080 cache words and compares them with
// thumb_model.py build_cache (big mode). Run with cwd = verification/assets.
// +MASK=<0..7> +SLOTS=<sdram_slots.mem> +GOLD=<cache_xxx.mem> [+LAT=<n>]
module tb_t10_cache;
reg clk=0,vc=0;always #4 clk=~clk;always #20 vc=~vc;
reg rst=1,start=0,cancel=0;reg [3:0] epoch=1;reg [2:0] mask=0;
wire req,advance,text_ready,text_ink,gr,gw,ga,gv,gd,gab,idle,gcancel,aw,ar,fault,ready,busy;
wire [1:0] text_slot;wire [2:0] ready_slots;wire [3:0] ready_epoch;
wire [9:0] x;wire [8:0] y;wire [12:0] fa;wire [3:0] fd;
wire [23:0] text_rgb;wire [20:0] addr,wa,ra;wire [127:0] wd;wire [31:0] wr,rd;
localparam CACHE=21'h1C2000, NCACHE=174080, MEMSZ=21'h1C2000+174080;
reg [31:0] mem[0:MEMSZ-1];reg [31:0] gold[0:NCACHE-1];
reg [15:0] pipe=0;reg [20:0] ap[0:15];reg rv=0;reg [31:0] rdata=0;
integer j,lat,writes=0,reads=0,valids=0,bad=0,m=0,slot1_reads=0,oob=0,first_bad=-1;
integer t0,t1;string slots_f,gold_f;
thumbnail_shared_rom rom(.video_clk(vc),.addr(15'd0),.dout(),.addrb(11'd0),.doutb(),.mem_clk(clk),.font_addr(fa),.font_data(fd));
thumbnail_text_serial text(.clk(clk),.rst(rst),.request(req),.advance(advance),.cancel(cancel||start),
 .x(x),.y(y),.ready(text_ready),.rgb(text_rgb),.ink(text_ink),.label_slot(text_slot),.font_addr(fa),.font_data(fd));
thumbnail_sample_engine builder(.clk(clk),.rst(rst),.start(start),.abort(cancel),.valid_slots(mask),.source_epoch(epoch),
 .static_rgb(text_rgb),.static_ready(text_ready),.static_request(req),.static_ink(text_ink),.static_slot(text_slot),
 .screen_x(x),.screen_y(y),
 .gen_req(gr),.gen_write(gw),.gen_addr(addr),.gen_wdata(wd),.gen_abort(gcancel),.gen_ack(ga),.gen_valid(gv),.gen_data(rd),
 .gen_done(gd),.gen_aborted(gab),.mem_idle(idle),.ready(ready),.ready_slots(ready_slots),.ready_epoch(ready_epoch),.busy(busy),.pixel_advance(advance));
thumbnail_mem_arbiter arb(.clk(clk),.rst(rst),.sdr_busy(1'b0),.tf_busy(1'b0),.tf_wr_en(1'b0),.tf_wr_addr(21'd0),.tf_wr_data(32'd0),
 .video_req(1'b0),.video_addr(21'd0),.video_ack(),.video_we(),.video_data(),.video_done(),
 .gen_req(gr),.gen_write(gw),.gen_addr(addr),.gen_wdata(wd),.gen_abort(gcancel),.gen_ack(ga),.gen_valid(gv),.gen_data(rd),
 .gen_done(gd),.gen_aborted(gab),.app_rd_en(ar),.app_rd_addr(ra),.app_wr_en(aw),.app_wr_addr(wa),.app_wr_data(wr),
 .sdr_rd_en(rv),.sdr_rd_data(rdata),.bus_reserved(),.idle(idle),.fault(fault));
// App read model: each app_rd_en word returns sdr_rd_en/sdr_rd_data LAT cycles later, in order.
always @(posedge clk)begin
 if(rst)begin pipe<=0;rv<=0;end
 else begin
  pipe<={pipe[14:0],ar};ap[0]<=ra;
  for(j=1;j<16;j=j+1)ap[j]<=ap[j-1];
  rv<=pipe[lat-1];if(pipe[lat-1])rdata<=mem[ap[lat-1]];
  if(fault)$fatal(1,"CACHE_FAULT");
  if(ar)begin
   reads=reads+1;
   if(ra>=21'd921600)oob=oob+1;
   if(ra>=21'd307200 && ra<21'd614400)slot1_reads=slot1_reads+1;
  end
  if(gv)valids=valids+1;
  if(aw)begin
   if(wa<CACHE || wa>=MEMSZ)$fatal(1,"CACHE_WRITE_OOB %h",wa);
   mem[wa]<=wr;writes=writes+1;
  end
 end
end
task launch;begin @(negedge clk);start=1;@(negedge clk);start=0;wait(busy);end endtask
initial begin
 if(!$value$plusargs("MASK=%d",m))m=7;mask=m;
 if(!$value$plusargs("LAT=%d",lat))lat=4;
 if(!$value$plusargs("SLOTS=%s",slots_f))$fatal(1,"need +SLOTS");
 if(!$value$plusargs("GOLD=%s",gold_f))$fatal(1,"need +GOLD");
 for(j=0;j<MEMSZ;j=j+1)mem[j]=32'hdeadbeef;
 $readmemh(slots_f,mem,0,921599);$readmemh(gold_f,gold);
 #41;rst=0;
 // Phase 1: start then epoch change mid-build -> cancel path must drain and return idle.
 launch();repeat(5000)@(negedge clk);epoch=2;
 wait(!busy);wait(idle);cancel=1;repeat(4)@(negedge clk);cancel=0;epoch=3;
 if(ready)$fatal(1,"READY_AFTER_CANCEL");
 for(j=CACHE;j<MEMSZ;j=j+1)mem[j]=32'hdeadbeef;
 writes=0;reads=0;valids=0;slot1_reads=0;oob=0;
 // Phase 2: full build.
 t0=$time;launch();wait(!busy);t1=$time;wait(idle);
 for(j=0;j<NCACHE;j=j+1)if(mem[CACHE+j]!==gold[j])begin
  if(bad<10)$display("MISMATCH idx=%0d x=%0d sy=%0d got=%h exp=%h",j,j%640,j/640,mem[CACHE+j],gold[j]);
  bad=bad+1;
 end
 $display("T10_CACHE mask=%0d lat=%0d mismatches=%0d writes=%0d app_reads=%0d gen_valid=%0d slot1_reads=%0d oob_reads=%0d ready=%b ready_slots=%b ready_epoch=%0d build_cycles=%0d",
  m,lat,bad,writes,reads,valids,slot1_reads,oob,ready,ready_slots,ready_epoch,(t1-t0)/8);
 $finish;
end
initial begin #400000000;$fatal(1,"CACHE_WATCHDOG");end
endmodule
