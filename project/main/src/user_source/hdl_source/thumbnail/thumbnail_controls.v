`timescale 1ns/1ps
// Video-domain UI ownership. The carousel remains the sole real cover writer.
module thumbnail_controls #(
    parameter DEBOUNCE_CYCLES=500000
)(
    input clk,input rst,input sw3,input active,input ui_busy,input cover_commit,
    input ready,input [2:0] valid_slots,input [1:0] current_cover,
    input [2:0] level,input carousel_busy,input fault,
    input key_next,input key_prev,
    output flip,output owned,output reg [1:0] focus
);
    wire sw_event,sw_accept_pending;
    wire allowed=active || (ready && |valid_slots && level==0 && !carousel_busy && !fault);
    sw3_debounce_fix #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES),
        .BASELINE_SETTLE_CYCLES(DEBOUNCE_CYCLES)) sw(
        .clk(clk),.rst_n(!rst),.sw3_raw(sw3),.busy_or_restricted(ui_busy || !allowed),
        .sw3_stable(),.sw3_baseline(),.baseline_init(),.sw3_flip_event(sw_event),
        .sw3_accept_pending(sw_accept_pending));
    assign flip=sw_event && allowed && !ui_busy;
    assign owned=active || ui_busy || flip || cover_commit || sw_accept_pending;
    function [1:0] next_slot;
        input [1:0] old; input backwards;
        begin
            case(old)
                0: next_slot=backwards ? (valid_slots[2]?2:valid_slots[1]?1:0):
                                          (valid_slots[1]?1:valid_slots[2]?2:0);
                1: next_slot=backwards ? (valid_slots[0]?0:valid_slots[2]?2:1):
                                          (valid_slots[2]?2:valid_slots[0]?0:1);
                default: next_slot=backwards ? (valid_slots[1]?1:valid_slots[0]?0:2):
                                                (valid_slots[0]?0:valid_slots[1]?1:2);
            endcase
        end
    endfunction
    always @(posedge clk or posedge rst)begin
        if(rst)focus<=0;
        else if(flip && !active)
            focus<=current_cover<3 && valid_slots[current_cover] ? current_cover:
                   valid_slots[0]?0:valid_slots[1]?1:2;
        else if(active && !ui_busy && !flip)begin
            if(key_prev)focus<=next_slot(focus,1'b1);
            else if(key_next)focus<=next_slot(focus,1'b0);
        end
    end
endmodule
