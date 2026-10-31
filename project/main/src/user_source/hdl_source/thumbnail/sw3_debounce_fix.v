`timescale 1ns/1ps
module sw3_debounce_fix #(
    parameter DEBOUNCE_CYCLES=500000,
    parameter BASELINE_SETTLE_CYCLES=500000
)(input clk,input rst_n,input sw3_raw,input busy_or_restricted,
  output reg sw3_stable,output reg sw3_baseline,output reg baseline_init,
  output reg sw3_flip_event, output sw3_accept_pending);
    localparam MAX_COUNT=DEBOUNCE_CYCLES>BASELINE_SETTLE_CYCLES ? DEBOUNCE_CYCLES:BASELINE_SETTLE_CYCLES;
    localparam W=MAX_COUNT<2 ? 1:$clog2(MAX_COUNT);
    reg [1:0] sync;
    reg [1:0] sync_valid;
    reg candidate;
    reg [W-1:0] count;
    wire [W:0] limit=baseline_init ? DEBOUNCE_CYCLES:BASELINE_SETTLE_CYCLES;
    // Reserve input ownership on the accepting edge, before the registered
    // flip pulse becomes visible. This gives SW3 priority over same-edge keys.
    assign sw3_accept_pending=sync_valid[1] && baseline_init && candidate==sync[1] &&
        candidate!=sw3_stable && count==limit-1 && candidate!=sw3_baseline && !busy_or_restricted;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            sync<=0;sync_valid<=0;candidate<=0;count<=0;
            sw3_stable<=0;sw3_baseline<=0;baseline_init<=0;sw3_flip_event<=0;
        end else begin
            sync<={sync[0],sw3_raw};sync_valid<={sync_valid[0],1'b1};sw3_flip_event<=0;
            if(!sync_valid[1])count<=0;
            else if(candidate!=sync[1])begin candidate<=sync[1];count<=0;end
            else if(!baseline_init || candidate!=sw3_stable) begin
                if(count==limit-1)begin
                    count<=0;sw3_stable<=candidate;sw3_baseline<=candidate;
                    if(!baseline_init)baseline_init<=1;
                    else if(candidate!=sw3_baseline && !busy_or_restricted)sw3_flip_event<=1;
                end else count<=count+1'b1;
            end else count<=0;
        end
    end
endmodule
