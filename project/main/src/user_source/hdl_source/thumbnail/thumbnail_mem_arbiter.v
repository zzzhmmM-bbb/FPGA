`timescale 1ns/1ps
// One App enable cycle describes one stream word. The original SDRAM controller
// emits column commands only for complete aligned four-word (BL4) groups.
// Existing TF frame_fifo_write must gate new batches with bus_reserved.
module thumbnail_mem_arbiter #(
    parameter VIDEO_WORDS = 256,
    parameter GEN_WORDS = 4,
    parameter DRAIN_CYCLES = 10,
    parameter READ_TIMEOUT = 65536
)(
    input clk, input rst,
    input sdr_busy,
    input tf_busy, input tf_wr_en, input [20:0] tf_wr_addr,
    input [31:0] tf_wr_data,
    input video_req, input [20:0] video_addr, output video_ack,
    output video_we, output [31:0] video_data, output reg video_done,
    input gen_req, input gen_write, input [20:0] gen_addr,
    input [127:0] gen_wdata, input gen_abort,
    output gen_ack, output gen_valid, output [31:0] gen_data,
    output reg gen_done, output reg gen_aborted,
    output app_rd_en, output [20:0] app_rd_addr,
    output app_wr_en, output [20:0] app_wr_addr, output [31:0] app_wr_data,
    input sdr_rd_en, input [31:0] sdr_rd_data,
    output bus_reserved, output idle, output reg fault
);
    localparam FREE=0, VIDEO=1, GEN_READ=2, GEN_WRITE=3, GUARD=4;
    reg [2:0] owner;
    reg [31:0] wait_cycles;
    reg [20:0] base;
    reg [127:0] write_data;
    reg [8:0] issued, returned;
    reg discard;
    reg write_tail;
    reg [3:0] guard_count;
    wire available = !fault && owner==FREE && !sdr_busy && !tf_busy && !tf_wr_en;
    assign video_ack = available && video_req;
    assign gen_ack = available && !video_req && gen_req && !gen_abort;
    assign bus_reserved = owner!=FREE;
    assign idle = !fault && owner==FREE && !tf_busy && !tf_wr_en;
    wire reading = owner==VIDEO || owner==GEN_READ;
    wire [8:0] total_words = owner==VIDEO ? VIDEO_WORDS : GEN_WORDS;
    // A granted batch owns the interface until ALL commands and responses drain.
    // Refresh / TF batches cannot start mid-transaction, same admission rule as T8.
    assign app_rd_en = !fault && reading && issued<total_words;
    assign app_rd_addr = (owner==VIDEO) ? {base[20:8], issued[7:0]} : {base[20:2], issued[1:0]};
    assign app_wr_en = !fault && (tf_wr_en || (owner==GEN_WRITE && issued<4));
    assign app_wr_addr = (owner==GEN_WRITE) ? {base[20:2], issued[1:0]} : tf_wr_addr;
    assign app_wr_data = (owner==GEN_WRITE) ? write_data[issued[1:0]*32+:32] : tf_wr_data;
    assign video_we = !fault && owner==VIDEO && sdr_rd_en;
    assign video_data = sdr_rd_data;
    // Fixed 1/4 sampling uses the first pixel of each aligned four-word read.
    // Drain all four responses before completion or reassigning the interface.
    assign gen_valid = !fault && owner==GEN_READ && sdr_rd_en && !discard && !gen_abort;
    assign gen_data = sdr_rd_data;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            fault<=0;wait_cycles<=0;owner<=FREE; base<=0; write_data<=0; issued<=0; returned<=0;
            discard<=0; write_tail<=0; guard_count<=0; video_done<=0; gen_done<=0; gen_aborted<=0;
        end else begin
            video_done<=0; gen_done<=0; gen_aborted<=0;
            if(reading && !sdr_rd_en)begin
                if(wait_cycles==READ_TIMEOUT-1)fault<=1;
                else wait_cycles<=wait_cycles+1'b1;
            end else wait_cycles<=0;

            // Decouple write_data CE from tf_busy combinatorial chain
            if(owner==FREE && gen_req && gen_write) write_data <= gen_wdata;

            // Sticky fail-closed state: late responses cannot be reassigned. Common reset recovers.
            if(!fault)case(owner)
                FREE: begin
                    issued<=0; returned<=0; discard<=0;write_tail<=0;
                    if(tf_wr_en)begin owner<=GUARD;guard_count<=0;end
                    else if(video_ack) begin owner<=VIDEO; base<=video_addr; end
                    else if(gen_ack) begin
                        owner<=gen_write ? GEN_WRITE : GEN_READ;
                        write_tail<=gen_write;
                        base<=gen_addr;
                    end
                end
                VIDEO,GEN_READ: begin
                    if(app_rd_en) issued<=issued+1'b1;
                    if(owner==GEN_READ && gen_abort) discard<=1;
                    if(sdr_rd_en) begin
                        returned<=returned+1'b1;
                        if(returned==total_words-1) begin
                            if(owner==VIDEO) video_done<=1;
                            else if(discard || gen_abort) gen_aborted<=1;
                            else gen_done<=1;
                            owner<=GUARD; guard_count<=0;
                        end
                    end
                end
                GEN_WRITE: begin
                    // Accepted writes commit; an abort cannot retract an App command.
                    // Keep the bus reserved for the T8 tail guard before completion.
                    // Once accepted, finish the entire BL4 write even on abort.
                    issued<=issued+1'b1;
                    if(gen_abort)discard<=1;
                    if(issued==3)begin owner<=GUARD;guard_count<=0;end
                end
                GUARD: begin
                    if(gen_abort) discard<=1;
                    // R2 restoration: retain full legal 10-cycle guard after TF write
                    if(tf_wr_en || tf_busy)guard_count<=0;
                    else if(guard_count==DRAIN_CYCLES-1) begin
                        owner<=FREE;
                        if(write_tail) begin
                            if(discard || gen_abort) gen_aborted<=1;
                            else gen_done<=1;
                        end
                    end else guard_count<=guard_count+1'b1;
                end
                default: owner<=FREE;
            endcase
        end
    end
endmodule
