`timescale 1ns/1ps
// The T8 loader loads once per common reset; P_DONE has no reload/retry entry.
// Publish its final validity set as ONE held mailbox payload, never per-bit CDC.
// The rebuild guard independently waits for TF/read tails to drain.
module thumbnail_load_admission(
    input sd_clk,input sd_rst,input preload_done,input [5:0] slot_valid,
    input mem_clk,input mem_rst,input rebuild_ready,input rebuild_accepted,
    output build_start,output [2:0] source_mask,output [3:0] source_epoch
);
    reg published;
    wire mailbox_ready,received;wire [5:0] loaded_mask;
    wire send=preload_done && !published && mailbox_ready;
    always @(posedge sd_clk or posedge sd_rst)
        if(sd_rst)published<=0;else if(send)published<=1;
    cdc_payload_mailbox #(.WIDTH(6)) final_load(
        .src_clk(sd_clk),.src_rst(sd_rst),.send(send),.src_data(slot_valid),
        .ready(mailbox_ready),.sent(),.dst_clk(mem_clk),.dst_rst(mem_rst),
        .received(received),.dst_data(loaded_mask));
    reg pending,submitted;
    always @(posedge mem_clk or posedge mem_rst)begin
        if(mem_rst)begin pending<=0;submitted<=0;end
        else begin
            if(received && |loaded_mask[2:0])pending<=1;
            if(build_start)begin submitted<=1;end
            if(rebuild_accepted)pending<=0;
        end
    end
    assign build_start=pending && !submitted && rebuild_ready;
    assign source_mask=loaded_mask[2:0];
    assign source_epoch=4'd1;
endmodule
