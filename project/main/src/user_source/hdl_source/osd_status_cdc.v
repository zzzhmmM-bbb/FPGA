`timescale 1ns/1ps

// Transfer a coherent {display_valid, auto_enabled, image_index} snapshot.
// The source holds the entire bus until the destination acknowledges it.
module osd_status_cdc (
    input  wire       src_clk,
    input  wire       dst_clk,
    input  wire       rst,
    input  wire [3:0] src_status,
    output reg  [3:0] dst_status
);
    wire src_reset, dst_reset;
    reset_sync src_reset_sync (.clk(src_clk), .async_reset(rst), .reset(src_reset));
    reset_sync dst_reset_sync (.clk(dst_clk), .async_reset(rst), .reset(dst_reset));

    reg [3:0] status_hold;
    reg request_toggle;
    reg ack_toggle;
    reg ack_sync1, ack_sync2;
    reg request_sync1, request_sync2;

    always @(posedge src_clk or posedge src_reset) begin
        if (src_reset) begin
            status_hold <= 4'd0;
            request_toggle <= 1'b0;
            ack_sync1 <= 1'b0;
            ack_sync2 <= 1'b0;
        end else begin
            ack_sync1 <= ack_toggle;
            ack_sync2 <= ack_sync1;
            if (request_toggle == ack_sync2 && src_status != status_hold) begin
                status_hold <= src_status;
                request_toggle <= ~request_toggle;
            end
        end
    end

    always @(posedge dst_clk or posedge dst_reset) begin
        if (dst_reset) begin
            request_sync1 <= 1'b0;
            request_sync2 <= 1'b0;
            ack_toggle <= 1'b0;
            dst_status <= 4'd0;
        end else begin
            request_sync1 <= request_toggle;
            request_sync2 <= request_sync1;
            if (request_sync2 != ack_toggle) begin
                dst_status <= status_hold;
                ack_toggle <= request_sync2;
            end
        end
    end
endmodule
