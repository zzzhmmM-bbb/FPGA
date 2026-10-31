`timescale 1ns/1ps
// Functional step-3 image boundary with shared subtitle/font storage.
// Reuses the external T8 video FIFO; no board input/TF loader ownership in this module.
// All clocks and data of those FIFOs remain fixed. No second video FIFO is instantiated.
module thumbnail_datapath #(parameter READ_TIMEOUT=65536)(
    input video_clk,input video_rst,input mem_clk,input mem_rst,
    input mode_flip,input restricted,input frame_start,
    input [1:0] focus,input [2:0] original_slot,
    input build_start,input build_abort,input [2:0] source_valid,input [3:0] source_epoch,
    input [14:0] subtitle_addr,input [10:0] subtitle_meta_addr,
    output [15:0] subtitle_data,output [15:0] subtitle_meta_data,
    output static_request,output text_cancel,
    output [9:0] build_x,output [8:0] build_y,output build_advance,
    input sdr_busy,input sdr_rd_valid,input [31:0] sdr_rd_data,
    input tf_busy,input tf_wr_en,input [20:0] tf_wr_addr,input [31:0] tf_wr_data,
    input [8:0] fifo_used,input fifo_full,
    input hs,input vs,input de,input [9:0] screen_x,input [9:0] screen_y,input [31:0] fifo_dout,
    output fifo_read,output hs_out,output vs_out,output de_out,output [23:0] rgb,
    output fifo_reset,output fifo_we,output [31:0] fifo_data,
    output app_rd_en,output [20:0] app_rd_addr,
    output app_wr_en,output [20:0] app_wr_addr,output [31:0] app_wr_data,
    output active_mode,output [2:0] active_slot,output cover_commit,
    output bus_reserved,output ready_video,output mode_busy,output build_busy,
    output ui_busy,output [2:0] cache_valid_video,
    output prefetch_ready,output fault,output rebuild_ready,output rebuild_accepted
);
    reg [1:0] fault_video;
    wire static_ready;wire [23:0] static_rgb;
    wire static_ink;wire [1:0] static_slot;
    wire [2:0] valid_video;
    assign cache_valid_video=valid_video;
    wire [12:0] font_addr;wire [3:0] font_data;
    thumbnail_shared_rom rom(.video_clk(video_clk),.addr(subtitle_addr),.dout(subtitle_data),
        .addrb(subtitle_meta_addr),.doutb(subtitle_meta_data),.mem_clk(mem_clk),
        .font_addr(font_addr),.font_data(font_data));
    thumbnail_text_serial text(.clk(mem_clk),.rst(mem_rst),.request(static_request),
        .advance(build_advance),.cancel(text_cancel),.x(build_x),.y(build_y),.ready(static_ready),
        .rgb(static_rgb),.ink(static_ink),.label_slot(static_slot),.font_addr(font_addr),.font_data(font_data));
    thumbnail_video_pipe pixels(.clk(video_clk),.rst(video_rst),.mode_thumb(active_mode),
        .frame_start(frame_start),.focus(focus),.valid_slots(valid_video),.fault(fault_video[1]),
        .hs(hs),.vs(vs),.de(de),.x(screen_x),.y(screen_y),.fifo_data(fifo_dout),.read_en(fifo_read),
        .hs_out(hs_out),.vs_out(vs_out),.de_out(de_out),.rgb(rgb));
    always @(posedge video_clk or posedge video_rst)
        if(video_rst)fault_video<=0;else fault_video<={fault_video[0],fault};
    wire ready_mem;wire [2:0] ready_mask;wire [3:0] ready_epoch;
    wire guarded_start,guarded_abort,force_close;wire [2:0] build_mask;
    wire [3:0] build_epoch;
    wire vr,va,vd;wire [20:0] vaddr;
    wire gr,gw,ga,gv,gd,gab,gcancel;
    wire [20:0] gaddr;wire [127:0] gwdata;wire [31:0] grdata;
    wire idle,quiesce;
    assign text_cancel=guarded_abort || guarded_start;
    thumbnail_rebuild_guard guard(.clk_mem(mem_clk),.rst_mem(mem_rst),.clk_video(video_clk),.rst_video(video_rst),
        .rebuild_req(build_start),.invalidate(build_abort || fault),.source_mask(source_valid),.source_epoch(source_epoch),
        .request_ready(rebuild_ready),.accepted(rebuild_accepted),.builder_busy(build_busy),.builder_done(ready_mem),
        .mem_idle(idle),.mode_quiesce(quiesce),.builder_start(guarded_start),.builder_abort(guarded_abort),
        .build_mask(build_mask),.build_epoch(build_epoch),.active_video(active_mode),.mode_busy_video(mode_busy),
        .force_close_video(force_close),.ready_video(ready_video),.valid_video(valid_video),.ready_mem(),.busy());
    thumbnail_mode_commit mode(.clk_video(video_clk),.rst_video(video_rst),.clk_mem(mem_clk),.rst_mem(mem_rst),
        .frame_start(frame_start),.sw3_flip(mode_flip),.restricted(restricted || force_close || fault_video[1]),
        .ready_video(ready_video),.valid_slots(valid_video),.focus_slot(focus),
        .original_cover_slot(original_slot),.active_mode(active_mode),.active_slot(active_slot),
        .busy_video(mode_busy),.ui_busy(ui_busy),.cover_commit(cover_commit),.fifo_used(fifo_used),.fifo_full(fifo_full),
        .video_req(vr),.video_addr(vaddr),.video_ack(va),.video_done(vd),.mem_idle(idle),
        .quiesce_gen(quiesce),.fifo_reset(fifo_reset),.prefetch_ready(prefetch_ready));
    thumbnail_sample_engine builder(.clk(mem_clk),.rst(mem_rst),.start(guarded_start),.abort(guarded_abort),
        .valid_slots(build_mask),.source_epoch(build_epoch),.static_rgb(static_rgb),.static_ready(static_ready),.static_request(static_request),
        .static_ink(static_ink),.static_slot(static_slot),
        .screen_x(build_x),.screen_y(build_y),.gen_req(gr),.gen_write(gw),.gen_addr(gaddr),
        .gen_wdata(gwdata),.gen_abort(gcancel),.gen_ack(ga),.gen_valid(gv),.gen_data(grdata),
        .gen_done(gd),.gen_aborted(gab),.mem_idle(idle),
        .ready(ready_mem),.ready_slots(ready_mask),.ready_epoch(ready_epoch),.busy(build_busy),.pixel_advance(build_advance));
    thumbnail_mem_arbiter #(.READ_TIMEOUT(READ_TIMEOUT)) arb(.clk(mem_clk),.rst(mem_rst),.sdr_busy(sdr_busy),
        .tf_busy(tf_busy),.tf_wr_en(tf_wr_en),.tf_wr_addr(tf_wr_addr),.tf_wr_data(tf_wr_data),
        .video_req(vr),.video_addr(vaddr),.video_ack(va),.video_we(fifo_we),.video_data(fifo_data),.video_done(vd),
        .gen_req(gr && !quiesce),.gen_write(gw),.gen_addr(gaddr),.gen_wdata(gwdata),.gen_abort(gcancel),
        .gen_ack(ga),.gen_valid(gv),.gen_data(grdata),.gen_done(gd),.gen_aborted(gab),
        .app_rd_en(app_rd_en),.app_rd_addr(app_rd_addr),.app_wr_en(app_wr_en),.app_wr_addr(app_wr_addr),.app_wr_data(app_wr_data),
        .sdr_rd_en(sdr_rd_valid),.sdr_rd_data(sdr_rd_data),.bus_reserved(bus_reserved),.idle(idle),.fault(fault));
endmodule
