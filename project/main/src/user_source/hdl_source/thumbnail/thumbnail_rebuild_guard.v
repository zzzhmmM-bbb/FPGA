`timescale 1ns/1ps
// Request producer holds/retries a pulse until accepted. No busy queue.
// Source payload is already coherent in clk_mem. Reset BOTH domains together.
module thumbnail_rebuild_guard(
    input clk_mem,input rst_mem,input clk_video,input rst_video,
    input rebuild_req,input invalidate,input [2:0] source_mask,input [3:0] source_epoch,
    output request_ready,output accepted,
    input builder_busy,input builder_done,input mem_idle,input mode_quiesce,
    output reg builder_start,output builder_abort,
    output reg [2:0] build_mask,output reg [3:0] build_epoch,
    input active_video,input mode_busy_video,
    output force_close_video,output ready_video,output [2:0] valid_video,
    output reg ready_mem,output busy
);
    localparam EMPTY=0,REVOKE=1,BUILD=2,LIVE=3;
    reg [1:0] state;
    reg revoke_req,revoke_ack;
    reg [1:0] ack_m,req_v,revoked_v;
    wire revoked_mem=state!=LIVE;
    wire source_changed=state!=EMPTY &&
        (source_mask!=build_mask || source_epoch!=build_epoch);
    assign request_ready=(state==EMPTY || state==LIVE) && revoke_req==ack_m[1] && !invalidate && !source_changed;
    assign accepted=rebuild_req && request_ready;
    assign busy=state==REVOKE || state==BUILD;
    assign builder_abort=state!=BUILD || invalidate || source_changed;
    assign force_close_video=revoked_v[1] || req_v[1]!=revoke_ack;
    always @(posedge clk_video or posedge rst_video)begin
        if(rst_video)begin req_v<=0;revoked_v<=3;revoke_ack<=0;end
        else begin
            req_v<={req_v[0],revoke_req};revoked_v<={revoked_v[0],revoked_mem};
            // Ack a NEW token only after revocation was seen, cover committed,
            // and all pending mode transactions returned to the video domain.
            if(req_v[1]!=revoke_ack && revoked_v[1] && !active_video && !mode_busy_video)
                revoke_ack<=req_v[1];
        end
    end
    always @(posedge clk_mem or posedge rst_mem)begin
        if(rst_mem)begin
            state<=EMPTY;revoke_req<=0;ack_m<=0;builder_start<=0;
            ready_mem<=0;build_mask<=0;build_epoch<=0;
        end else begin
            ack_m<={ack_m[0],revoke_ack};builder_start<=0;
            if(invalidate || source_changed)begin state<=EMPTY;ready_mem<=0;end
            else if(accepted)begin
                state<=REVOKE;ready_mem<=0;revoke_req<=~revoke_req;
                build_mask<=source_mask;build_epoch<=source_epoch;
            end else case(state)
                REVOKE:if(ack_m[1]==revoke_req && !builder_busy && mem_idle && !mode_quiesce)begin
                    state<=BUILD;builder_start<=1;
                end
                BUILD:if(builder_done && !builder_busy)begin ready_mem<=|build_mask;state<=LIVE;end
                default:begin end
            endcase
        end
    end
    wire status_ready,status_sent,status_received;
    wire [7:0] desired={ready_mem,build_mask,build_epoch};
    reg [7:0] published;
    wire send=status_ready && desired!=published;
    wire [7:0] received_payload;
    always @(posedge clk_mem or posedge rst_mem)
        if(rst_mem)published<=0;else if(send)published<=desired;
    cdc_payload_mailbox #(.WIDTH(8)) status(
        .src_clk(clk_mem),.src_rst(rst_mem),.send(send),.src_data(desired),
        .ready(status_ready),.sent(status_sent),.dst_clk(clk_video),.dst_rst(rst_video),
        .received(status_received),.dst_data(received_payload));
    assign ready_video=received_payload[7] && !force_close_video;
    assign valid_video=received_payload[6:4];
endmodule
