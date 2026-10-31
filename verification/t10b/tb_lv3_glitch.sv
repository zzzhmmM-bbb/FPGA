`timescale 1ns/1ps
// T10b: level-3 hold progress under link/stale glitches.
// CLKHZ (default 1000) sets clocks per ms = CLKHZ/1000; GAP is in clocks, report in ms. Target 'a' (f1=26, f2=40); input sits on target.
// +MODE=0 clean link; 1 one-clock vowel_fresh drop every GAP ms; 2 link down 1000 ms after
// 1500 ms of holding (must clear after 750 ms); 3 vowel_valid 0 for 300 ms mid-hold.
module tb_lv3_glitch #(parameter integer CLKHZ = 1000);
    localparam integer MS = CLKHZ / 1000;
    reg clk=0, rst_n=0, vsync=1, confirm=0;
    reg vowel_valid=1, link_up=1, fresh=1;
    integer mode, gap, t, t_done, max_prog, prog_at_1500, prog_after_drop;
    wire [5:0] prog; wire prog_en; wire [1:0] phase, stage;
    always #1 clk = ~clk;   // 2 ns period; time scale irrelevant, CLK_HZ sets ms
    level_flow_ctrl #(.CLK_HZ(CLKHZ), .CD_FRAMES(1)) dut(
        .clk(clk), .rst_n(rst_n), .vsync(vsync), .level_v(3'd3), .l2_enable(1'b1),
        .next_press(1'b0), .confirm_press(confirm),
        .vowel_valid(vowel_valid), .link_up(link_up), .vowel_fresh(fresh),
        .f1_bin(6'd26), .f2_bin(7'd40), .f0_valid(1'b0), .f0_code(6'd0),
        .l2_unheard(1'b0), .l2_stars(2'd0), .l2_post_done(1'b0), .l2_play_busy(1'b0),
        .slot_en(), .slot_id(), .slot_cx(), .slot_cy(), .slot_kind(), .subtitle_enable(),
        .target_en(), .target_id(), .target_blink(), .stage(stage), .stars(),
        .l2_pract(), .l2_tone(), .l2_target_blink(),
        .hold_progress(prog), .hold_progress_en(prog_en), .hold_phase(phase));
    // 16-clock frames
    integer fc=0;
    always @(posedge clk) begin fc <= (fc==15) ? 0 : fc+1; vsync <= (fc < 2) ? 1'b0 : 1'b1; end
    initial begin
        if(!$value$plusargs("MODE=%d",mode)) mode=0;
        if(!$value$plusargs("GAP=%d",gap)) gap=37;
        repeat(5) @(posedge clk); rst_n=1;
        repeat(40) @(posedge clk); @(negedge clk) confirm=1; @(negedge clk) confirm=0;
        wait(stage==2'd2);
        t=0; t_done=-1; max_prog=0; prog_at_1500=-1; prog_after_drop=-1;
        while(t < 5000*MS) begin
            @(negedge clk);
            fresh = 1; link_up = 1; vowel_valid = 1;
            if(mode==1 && (t % gap)==gap-1) fresh = 0;
            if(mode==2 && t>=1500*MS && t<2500*MS) begin fresh=0; link_up=0; end
            if(mode==3 && t>=1500*MS && t<1800*MS) vowel_valid=0;
            @(posedge clk); #0.1;
            if(prog > max_prog) max_prog = prog;
            if(t==1500*MS-1) prog_at_1500 = prog;
            if(t==2500*MS-1) prog_after_drop = prog;
            if(t_done<0 && prog==6'd63) t_done=t;
            t=t+1;
        end
        $display("LV3 clkhz=%0d mode=%0d gap=%0d max_prog=%0d prog@1500=%0d prog@2500=%0d done_at_ms=%0d stage=%0d",
                 CLKHZ, mode, gap, max_prog, prog_at_1500, prog_after_drop, (t_done<0)?-1:t_done/MS, stage);
        $finish;
    end
endmodule
