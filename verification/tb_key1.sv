`timescale 1ns/1ps
module tb_key1;
    reg c=0;always #10 c=~c;
    reg key=1,inhibit=0;wire reset_n,auto_mode;
    key1_mode_control #(.DEBOUNCE_CYCLES(3),.LONG_CYCLES(20),.RESET_CYCLES(4)) dut(
        .clk(c),.key_n(key),.inhibit_long(inhibit),.system_reset_n(reset_n),.auto_mode(auto_mode));
    task ticks(input integer n);repeat(n)@(negedge c);endtask
    initial begin
        ticks(25);if(!reset_n || auto_mode)$fatal(1,"BOOT");
        key=0;ticks(40);key=1;ticks(12);if(!auto_mode)$fatal(1,"LEGACY_LONG_BROKEN");
        inhibit=1;ticks(10);key=0;ticks(12);inhibit=0;ticks(40);key=1;ticks(14);
        if(!auto_mode)$fatal(1,"LONG_FROM_SELECTOR_LEAKED_AFTER_EXIT");
        key=0;ticks(12);inhibit=1;ticks(30);key=1;ticks(15);
        if(!auto_mode)$fatal(1,"LONG_HELD_ACROSS_OPEN_LEAKED");
        // A short press still resets while inhibited.
        key=0;ticks(10);key=1;
        wait(!reset_n);if(auto_mode)$fatal(1,"SHORT_RESET_NOT_RETAINED");
        ticks(10);if(!reset_n)$fatal(1,"RESET_DID_NOT_RELEASE");
        inhibit=0;ticks(14);key=0;ticks(40);key=1;ticks(12);
        if(!auto_mode)$fatal(1,"POST_SELECTOR_LONG_NOT_REARMED");
        $display("PASS key1 independent long suppression and short reset");$finish;
    end
    initial begin #20000;$fatal(1,"WATCHDOG key1");end
endmodule
