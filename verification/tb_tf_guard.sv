`timescale 1ns/1ps
module tb_tf_guard;
reg clk=0;always #4 clk=~clk;
reg rst=1,tfbusy=0,tfwe=0,vr=0;reg [20:0] ta=0;
wire va,ar,aw;wire [20:0] ra,wa;wire [31:0] wd;integer cycle=0,last_write=-100,gap=0,i;
thumbnail_mem_arbiter dut(.clk(clk),.rst(rst),.sdr_busy(1'b0),
 .tf_busy(tfbusy),.tf_wr_en(tfwe),.tf_wr_addr(ta),.tf_wr_data(32'h12345600),
 .video_req(vr),.video_addr(21'h100000),.video_ack(va),.video_we(),.video_data(),.video_done(),
 .gen_req(1'b0),.gen_write(1'b0),.gen_addr(21'd0),.gen_wdata(128'd0),.gen_abort(1'b0),
 .gen_ack(),.gen_valid(),.gen_data(),.gen_done(),.gen_aborted(),
 .app_rd_en(ar),.app_rd_addr(ra),.app_wr_en(aw),.app_wr_addr(wa),.app_wr_data(wd),
 .sdr_rd_en(1'b0),.sdr_rd_data(32'd0),.bus_reserved(),.idle(),.fault());
always @(posedge clk)if(!rst)begin
 cycle=cycle+1;if(tfwe)last_write=cycle;
 if(va)begin gap=cycle-last_write;$display("TF_TO_VIDEO_ACCEPT_GAP=%0d",gap);
  if(gap<10)$fatal(1,"TF_TAIL_GUARD_REDUCED gap=%0d required=10",gap);
  $display("PASS_TF_TAIL_GUARD");$finish;
 end
end
initial begin
 repeat(4)@(negedge clk);rst=0;tfbusy=1;
 // A full legal aligned 256-word TF transaction, with O_wr_busy dropping
 // after the final write, as in the actual frame_fifo_write contract.
 repeat(2)@(negedge clk);
 for(i=0;i<256;i=i+1)begin tfwe=1;ta=i;@(negedge clk);end
 tfwe=0;tfbusy=0;vr=1;
end
initial begin #100000;$fatal(1,"TF_GUARD_WATCHDOG");end
endmodule
