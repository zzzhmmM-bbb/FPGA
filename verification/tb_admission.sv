`timescale 1ns/1ps
module tb_admission;
    reg sc=0,mc=0;always #5 sc=~sc;always #4 mc=~mc;
    reg rst=1,done=0,ready=0,accepted=0;reg [5:0] mask=0;
    wire start;wire [2:0] source;wire [3:0] epoch;
    thumbnail_load_admission dut(.sd_clk(sc),.sd_rst(rst),.preload_done(done),.slot_valid(mask),
        .mem_clk(mc),.mem_rst(rst),.rebuild_ready(ready),.rebuild_accepted(accepted),
        .build_start(start),.source_mask(source),.source_epoch(epoch));
    integer starts=0;
    always @(posedge mc)if(start)begin starts=starts+1;if(source!=5 || epoch!=1)$fatal(1,"INCOHERENT_LOAD_SNAPSHOT");end
    task ticks(input integer n);repeat(n)@(negedge sc);endtask
    initial begin
        ticks(4);rst=0;ready=1;mask=1;ticks(12);mask=5;ticks(12);
        if(starts!=0)$fatal(1,"PARTIAL_LOAD_STARTED_BUILD");
        ready=0;done=1;ticks(20);if(starts!=0)$fatal(1,"MAILBOX_IGNORED_BUILD_BACKPRESSURE");
        ready=1;ticks(10);accepted=1;ticks(2);accepted=0;ticks(20);
        if(starts!=1)$fatal(1,"BUILD_NOT_EXACTLY_ONCE");
        // P_DONE is stable; even an invalid later payload change cannot mutate snapshot.
        mask=63;ticks(30);if(source!=5 || starts!=1)$fatal(1,"LIVE_PAYLOAD_REPLACED_SNAPSHOT");
        rst=1;ticks(4);mask=0;done=0;rst=0;ticks(10);done=1;ticks(30);
        if(starts!=1 || start)$fatal(1,"EMPTY_ASSETS_PUBLISHED_BUILD");
        $display("PASS admission coherent final mask, backpressure, once, empty, common reset");$finish;
    end
endmodule
