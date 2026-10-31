`timescale 1ns/1ps
// One transaction in flight. Payload remains stable until returned acknowledgement.
// Both domains must assert reset together; independently restarting a domain is unsupported.
module cdc_payload_mailbox #(parameter WIDTH=8)(
    input src_clk,input src_rst,input send,input [WIDTH-1:0] src_data,
    output ready, output reg sent,
    input dst_clk,input dst_rst,output reg received,output reg [WIDTH-1:0] dst_data
);
    reg req,ack;reg [WIDTH-1:0] hold;
    reg [1:0] req_sync,ack_sync;
    reg ack_seen;
    assign ready=req==ack_sync[1];
    always @(posedge src_clk or posedge src_rst)begin
        if(src_rst)begin req<=0;hold<=0;ack_sync<=0;sent<=0;ack_seen<=0;end
        else begin
            ack_sync<={ack_sync[0],ack};sent<=0;
            if(ack_seen!=ack_sync[1])begin ack_seen<=ack_sync[1];sent<=1;end
            if(send && ready)begin hold<=src_data;req<=~req;end
        end
    end
    always @(posedge dst_clk or posedge dst_rst)begin
        if(dst_rst)begin req_sync<=0;ack<=0;received<=0;dst_data<=0;end
        else begin
            req_sync<={req_sync[0],req};received<=0;
            if(req_sync[1]!=ack)begin dst_data<=hold;received<=1;ack<=req_sync[1];end
        end
    end
endmodule
