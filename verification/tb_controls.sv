`timescale 1ns/1ps
module tb_controls;
    reg vc=0,mc=0;always #20 vc=~vc;always #4 mc=~mc;
    reg rst=1,sw3=0,k2=1,k4=1,sw1=0,sw2=0;
    reg ready=1,auto_mode=0;reg [5:0] slots=63;
    reg [6:0] fc=0;
    wire frame=fc==99;
    always @(posedge vc)if(rst)fc<=0;else fc<=frame?0:fc+1;
    wire active,ui_busy,mem_busy,commit,flip,owned;
    wire [1:0] focus,cover_tb,period;
    wire [2:0] slot,level,display_slot;
    wire carousel_busy,blinds;wire [8:0] alpha;
    wire next_key,prev_key,confirm_key,period_key,hold,mode,select_threshold;
    wire [3:0] brightness;wire td,tu,practice;
    parameter_controls #(.DEBOUNCE_CYCLES(3),.LONG_CYCLES(20)) keys(
        .clk(vc),.rst_n(!rst),.sw_mode(sw1),.sw_select(sw2),.key_down_n(k2),.key_up_n(k4),
        .calibration_status(4'd4),.interaction_locked(1'b0),.selector_owned(owned),
        .selector_active(active && !ui_busy && !flip),.mode(mode),.select_threshold(select_threshold),
        .brightness(brightness),.threshold_down(td),.threshold_up(tu),.practice_start(practice),
        .next_press(next_key),.prev_press(prev_key),.confirm_press(confirm_key),.period_press(period_key),
        .navigation_hold(hold),.image_next_n(),.image_auto_n());
    thumbnail_controls #(.DEBOUNCE_CYCLES(3)) controls(
        .clk(vc),.rst(rst),.sw3(sw3),.active(active),.ui_busy(ui_busy),.cover_commit(commit),
        .ready(ready),.valid_slots(slots[2:0]),.current_cover(cover_tb),.level(level),
        .carousel_busy(carousel_busy),.fault(1'b0),.key_next(next_key),.key_prev(prev_key),
        .flip(flip),.owned(owned),.focus(focus));
    cover_carousel_ctrl #(.AUTO_FRAMES(8),.FADE_STEP(256),.HOLD_FRAMES(0)) carousel(
        .clk(vc),.rst_n(!rst),.frame_start(frame),.slot_valid(slots),.auto_mode(auto_mode),
        .manual_hold(hold),.selector_hold(owned),.selector_commit(commit),.selector_slot(slot[1:0]),
        .next_press(next_key && !owned),.prev_press(prev_key && !owned),
        .confirm_press(confirm_key && !owned),.period_press(period_key && !owned),
        .back_long(1'b0),.back_block(1'b0),.level(level),.display_slot(display_slot),
        .cover_idx(cover_tb),.alpha(alpha),.busy(carousel_busy),.blinds_active(blinds),.period_index(period));
    wire req,done;wire [20:0] addr;reg [8:0] latency=0;
    wire ack=req && latency==0;assign done=latency==1;
    always @(posedge mc)if(rst)latency<=0;else if(ack)latency<=280;else if(latency!=0)latency<=latency-1;
    thumbnail_mode_commit mode_ctl(
        .clk_video(vc),.rst_video(rst),.clk_mem(mc),.rst_mem(rst),.frame_start(frame),
        .sw3_flip(flip),.restricted(level!=0 || carousel_busy),.ready_video(ready),
        .valid_slots(slots[2:0]),.focus_slot(focus),.original_cover_slot(display_slot),
        .active_mode(active),.active_slot(slot),.busy_video(mem_busy),.ui_busy(ui_busy),.cover_commit(commit),
        .fifo_used(9'd0),.fifo_full(1'b0),.video_req(req),.video_addr(addr),
        .video_ack(ack),.video_done(done),.mem_idle(latency==0),
        .quiesce_gen(),.fifo_reset(),.prefetch_ready());
    integer flips=0,commits=0,nexts=0,prevs=0,thresholds=0;
    always @(negedge vc)if(!rst)begin
        if(flip)flips=flips+1;
        if(commit)commits=commits+1;
        if(next_key)nexts=nexts+1;
        if(prev_key)prevs=prevs+1;
        if(td)thresholds=thresholds+1;
        if(owned && (td || tu || practice || confirm_key || period_key))$fatal(1,"SELECTOR_KEY_LEAK");
        if(active && (level!=0 || alpha!=256 || blinds))$fatal(1,"SELECTOR_SCENE_CHANGED");
    end
    task ticks(input integer n);repeat(n)@(negedge vc);endtask
    task frames(input integer n);repeat(n)begin @(posedge frame);@(negedge vc);end endtask
    task toggle;begin @(negedge vc);sw3=~sw3;ticks(12);end endtask
    task opened;begin wait(active && !ui_busy);ticks(12);end endtask
    task closed;begin wait(!active && !ui_busy);ticks(15);end endtask
    task short2;begin k2=0;ticks(12);k2=1;ticks(12);end endtask
    integer n,p,f,c;
    initial begin
        ticks(5);rst=0;ticks(15);
        if(flips!=0)$fatal(1,"LOW_START_FALSE_FLIP");
        wait(!carousel_busy);ticks(10);
        sw3=1;ticks(1);sw3=0;ticks(12);
        if(flips!=0)$fatal(1,"BOUNCE_ACCEPTED");
        ready=0;toggle();f=flips;ready=1;frames(2);
        if(active || flips!=f)$fatal(1,"UNREADY_FLIP_QUEUED");
        // SW1 remains in parameter mode; selector KEY2 still navigates.
        sw1=1;ticks(12);toggle();opened();
        if(focus!=cover_tb)$fatal(1,"OPEN_FOCUS_NOT_CURRENT");
        short2();if(focus!=1 || cover_tb!=0 || brightness!=8)$fatal(1,"FOCUS_OR_PARAMETER_LEAK");
        n=nexts;p=prevs;k2=0;ticks(45);k2=1;ticks(15);
        if(focus!=0 || prevs!=p+1 || nexts!=n)$fatal(1,"LONG_RELEASE_APPENDED_SHORT");
        // KEY4 / SW2 cannot change confirmation, period, or threshold.
        k4=0;sw2=1;ticks(40);k4=1;ticks(12);
        if(period!=0 || level!=0 || brightness!=8)$fatal(1,"KEY4_OR_SWITCH_LEAK");
        short2();if(focus!=1)$fatal(1,"SW2_INTERRUPTED_SELECTOR");
        // A KEY2 press held across exit must not change the parameter on release.
        k2=0;ticks(10);c=commits;toggle();closed();k2=1;ticks(15);
        if(commits!=c+1 || cover_tb!=1 || display_slot!=1 || brightness!=8 || level!=0 || blinds)
            $fatal(1,"EXIT_NOT_SINGLE_DIRECT_COMMIT");
        frames(2);if(commits!=c+1)$fatal(1,"DUPLICATE_COMMIT");
        n=thresholds;short2();if(thresholds!=n+1)$fatal(1,"PARAMETER_NOT_REARMED_AFTER_RELEASE");
        // Missing slot skipped in both directions; singleton stays selected.
        slots=6'b111101;sw1=0;sw2=0;ticks(12);toggle();opened();
        if(focus!=0)$fatal(1,"INVALID_CURRENT_FOCUS");
        short2();if(focus!=2)$fatal(1,"MISSING_NOT_SKIPPED");
        slots=6'b000100;short2();if(focus!=2)$fatal(1,"SINGLETON_CHANGED");
        toggle();closed();if(cover_tb!=2)$fatal(1,"EXIT_WRONG_SLOT");
        slots=63;
        // Open on last auto dwell frame: ownership must beat auto_fire.
        auto_mode=1;wait(carousel.auto_cnt==7);toggle();opened();
        if(cover_tb!=2 || focus!=2)$fatal(1,"AUTO_RACE");
        frames(10);if(cover_tb!=2)$fatal(1,"CAROUSEL_NOT_PAUSED");
        toggle();closed();auto_mode=0;
        if(carousel.auto_cnt!=0)$fatal(1,"EXIT_TIMER_NOT_RESET");
        // Training and animation consume SW3 changes without queuing.
        k4=0;ticks(12);k4=1;ticks(12);wait(carousel_busy);toggle();wait(!carousel_busy);
        if(level!=3 || active)$fatal(1,"TRAINING_CONFIRM_REGRESSION");
        f=flips;toggle();frames(3);if(flips!=f || active)$fatal(1,"TRAINING_SW3_ACCEPTED");
        // Both starting switch polarities establish baseline without opening.
        rst=1;ticks(5);sw3=1;rst=0;ticks(15);
        f=flips;frames(3);if(active || flips!=f)$fatal(1,"HIGH_START_FALSE_FLIP");
        wait(!carousel_busy);sw1=1;ticks(12);
        // Debounced SW3 and parameter KEY2 arrive on the same clock.
        k2=0;sw3=~sw3;ticks(12);opened();k2=1;ticks(12);
        if(brightness!=8)$fatal(1,"SIMULTANEOUS_OPEN_CHANGED_PARAMETER");
        // Rapid repeat during the UI transaction is consumed, never queued.
        frames(1);ticks(10);toggle();toggle();closed();frames(3);
        if(active)$fatal(1,"BUSY_FLIP_QUEUED");
        // Revoking ready before frame submission cancels an already pending open.
        frames(1);ticks(10);toggle();ready=0;frames(3);
        if(active)$fatal(1,"REVOKED_OPEN_COMMITTED");
        ready=1;
        // Ordinary per-frame memory prefetch is not a UI-busy restriction.
        wait(mode_ctl.state==4);f=flips;toggle();opened();
        if(flips!=f+1)$fatal(1,"FRAME_PREFETCH_CONSUMED_LEGAL_FLIP");
        $display("PASS controls flips=%0d commits=%0d next=%0d prev=%0d",flips,commits,nexts,prevs);$finish;
    end
    initial begin #3000000;$fatal(1,"WATCHDOG controls");end
endmodule
