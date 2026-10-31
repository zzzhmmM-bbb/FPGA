`timescale 1ns/1ps
// Step-3 image controller (explicit test command, no board key ownership): consumes one stable request, drains accepted reads,
// clears the EXISTING video FIFO, prefetches actual data, then commits in blanking.
module thumbnail_mode_commit #(
    parameter VIDEO_WORDS=256,
    parameter RESET_CYCLES=8,
    parameter RECOVER_CYCLES=20
)(
    input clk_video,input rst_video,input clk_mem,input rst_mem,
    input frame_start, input sw3_flip, input restricted,
    input ready_video,input [2:0] valid_slots,input [1:0] focus_slot,
    input [2:0] original_cover_slot,
    output reg active_mode,output reg [2:0] active_slot,
    output busy_video,output ui_busy,output reg cover_commit,
    input [8:0] fifo_used,input fifo_full,
    output video_req,output [20:0] video_addr,
    input video_ack,input video_done,input mem_idle,
    output quiesce_gen,output reg fifo_reset,output reg prefetch_ready
);
    reg [1:0] focus_safe;
    always @*begin
        if(focus_slot<3 && valid_slots[focus_slot])focus_safe=focus_slot;
        else if(valid_slots[0])focus_safe=0;
        else if(valid_slots[1])focus_safe=1;
        else focus_safe=2;
    end
    reg pending,requested_mode;
    reg [2:0] requested_slot;
    reg req_toggle,ack_toggle;
    reg [1:0] ack_sync;
    reg ack_seen;
    reg payload_mode;reg [2:0] payload_slot;
    assign busy_video=pending || req_toggle!=ack_sync[1] || ack_seen!=ack_sync[1];
    assign ui_busy=pending || payload_mode!=active_mode;
    wire accept_flip=sw3_flip && !ui_busy && !restricted && ready_video && |valid_slots;
    wire candidate_mode=accept_flip ? ~active_mode:pending ? requested_mode:active_mode;
    wire [2:0] candidate_slot=accept_flip ? (active_mode ? focus_safe:original_cover_slot):
                              pending ? requested_slot:(active_mode ? active_slot:original_cover_slot);
    wire safe_mode=candidate_mode && ready_video && |valid_slots && !restricted;
    always @(posedge clk_video or posedge rst_video)begin
        if(rst_video)begin
            pending<=0;requested_mode<=0;requested_slot<=0;req_toggle<=0;
            payload_mode<=0;payload_slot<=0;ack_sync<=0;ack_seen<=0;
            active_mode<=0;active_slot<=0;cover_commit<=0;
        end else begin
            ack_sync<={ack_sync[0],ack_toggle};cover_commit<=0;
            if(ack_seen!=ack_sync[1])begin
                ack_seen<=ack_sync[1];active_mode<=payload_mode;active_slot<=payload_slot;
                if(active_mode && !payload_mode)cover_commit<=1;
            end
            // A flip while pending/committing is consumed upstream and never queued.
            if(accept_flip)begin
                pending<=1;requested_mode<=~active_mode;
                requested_slot<=active_mode ? focus_safe:original_cover_slot;
            end
            if(active_mode && (!ready_video || !(|valid_slots)) && !busy_video)begin
                pending<=1;requested_mode<=0;requested_slot<=original_cover_slot;
            end
            if(frame_start && req_toggle==ack_sync[1] && ack_seen==ack_sync[1])begin
                // Ready/restriction may change between the flip and frame boundary.
                // Revalidate opening; a revoked cache must never be committed.
                payload_mode<=safe_mode;
                payload_slot<=candidate_mode && !safe_mode ? original_cover_slot:candidate_slot;
                req_toggle<=~req_toggle;pending<=0;
            end
        end
    end
    reg [1:0] req_sync;
    reg req_seen;
    localparam RUN=0,DRAIN=1,CLEAR=2,RECOVER=3,PREFETCH=4;
    reg [2:0] state;
    reg [4:0] timer;
    reg [20:0] base;
    reg [11:0] batch_index,batch_limit;
    reg in_flight;
    wire new_frame=req_sync[1]!=req_seen;
    assign quiesce_gen=state!=RUN || new_frame;
    assign video_req=(state==RUN || state==PREFETCH) && !new_frame &&
                     !in_flight && !fifo_full && fifo_used<512-VIDEO_WORDS && batch_index<batch_limit;
    assign video_addr=base+batch_index*VIDEO_WORDS;
    always @(posedge clk_mem or posedge rst_mem)begin
        if(rst_mem)begin
            req_sync<=0;req_seen<=0;ack_toggle<=0;state<=DRAIN;timer<=0;
            fifo_reset<=0;prefetch_ready<=0;base<=0;batch_index<=0;
            batch_limit<=307200/VIDEO_WORDS;in_flight<=0;
        end else begin
            req_sync<={req_sync[0],req_toggle};
            if(video_ack)begin in_flight<=1;batch_index<=batch_index+1'b1;end
            if(video_done)in_flight<=0;
            case(state)
                RUN: if(new_frame)begin state<=DRAIN;prefetch_ready<=0;end
                DRAIN: if(mem_idle && !in_flight)begin
                    fifo_reset<=1;timer<=0;state<=CLEAR;
                end
                CLEAR: if(timer==RESET_CYCLES-1)begin
                    fifo_reset<=0;timer<=0;state<=RECOVER;
                end else timer<=timer+1'b1;
                RECOVER: if(timer==RECOVER_CYCLES-1)begin
                    base<=payload_mode ? 21'h1C2000:
                          payload_slot==1 ? 21'h04B000:payload_slot==2 ? 21'h096000:
                          payload_slot==3 ? 21'h0E1000:payload_slot==4 ? 21'h12C000:
                          payload_slot==5 ? 21'h177000:21'd0;
                    batch_limit<=payload_mode ? 174080/VIDEO_WORDS:307200/VIDEO_WORDS;
                    batch_index<=0;state<=PREFETCH;req_seen<=req_sync[1];
                end else timer<=timer+1'b1;
                PREFETCH: if(video_done)begin
                    prefetch_ready<=1;ack_toggle<=req_seen;state<=RUN;
                end
                default: state<=DRAIN;
            endcase
        end
    end
endmodule
