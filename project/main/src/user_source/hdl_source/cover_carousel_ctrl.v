`timescale 1ns/1ps
// Step-1 candidate: cover blinds; entry/back/boot keep the T3 fade.
//
// Slots: covers 0,1,2 = levels 1,2,3; level backgrounds: level 1 -> 3,
// level 2 -> 4, level 3 -> 5 (falls back to cover slot lv-1 if not loaded).
// level: 0 cover page, 1 loudness, 2 tone, 3 vowel.
//
// Transition: IDLE -> FADE_OUT -> HOLD -> FADE_IN -> IDLE.
// alpha changes only on frame_start. level / cover_idx / display_slot change
// only on a frame_start where alpha is already 0 (the commit), so the read
// side and level_v both pick up the new values at the next frame start, in a
// black frame.
// Power-up: BOOT keeps alpha = 0 until a cover slot is loaded, then commits
// the lowest loaded cover and fades straight in.
module cover_carousel_ctrl #(
    parameter integer AUTO_FRAMES = 240,   // auto carousel period, ~4 s at 60 Hz
    parameter integer FADE_STEP   = 16,    // alpha change per frame, 256/16 = 16 frames
    parameter integer HOLD_FRAMES = 2      // black frames kept after the commit
)(
    input  wire       clk, rst_n,
    input  wire       frame_start,    // single cycle: delayed vs falling edge (same as level_v latch)
    input  wire [5:0] slot_valid,     // already in video domain
    input  wire       auto_mode,      // KEY1 long-press mode, synchronized
    input wire selector_hold, selector_commit,
    input wire [1:0] selector_slot,
    input  wire       manual_hold,    // KEY2/KEY4 gesture pending: restart auto timer
    input  wire       next_press,     // KEY2 short pulse
    input  wire       prev_press,     // KEY2 long pulse (cover page only)
    input  wire       confirm_press,  // KEY4 pulse
    input  wire       period_press,   // KEY4 long pulse: 4 -> 8 -> 12 -> 4 seconds
    input  wire       back_long,      // KEY3 long-press pulse
    input  wire       back_block,     // interaction_locked
    output reg  [2:0] level,          // 0 cover page, 1..3 levels
    output reg  [2:0] display_slot,   // -> frame_read_write.read_addr_index
    output reg  [1:0] cover_idx,      // committed cover 0..2
    output reg  [8:0] alpha,          // 0..256, updated only on frame_start
    output wire       busy,           // transition in progress
    output reg        blinds_active,
    output reg  [1:0] period_index    // selected dwell: 0=4s, 1=8s, 2=12s
);
    localparam [2:0] S_BOOT     = 3'd0;
    localparam [2:0] S_IDLE     = 3'd1;
    localparam [2:0] S_FADE_OUT = 3'd2;
    localparam [2:0] S_HOLD     = 3'd3;
    localparam [2:0] S_FADE_IN  = 3'd4;

    localparam [1:0] T_NEXT  = 2'd0;
    localparam [1:0] T_ENTER = 2'd1;
    localparam [1:0] T_BACK  = 2'd2;
    localparam [1:0] T_PREV  = 2'd3;

    localparam integer ACW = (AUTO_FRAMES < 1) ? 1 : $clog2(3 * AUTO_FRAMES + 1);
    localparam integer HCW = (HOLD_FRAMES < 2) ? 1 : $clog2(HOLD_FRAMES + 1);
    localparam [9:0]   STEP     = FADE_STEP;
    localparam [ACW-1:0] AUTO_LAST_4 = AUTO_FRAMES - 1;
    localparam [ACW-1:0] AUTO_LAST_8 = 2 * AUTO_FRAMES - 1;
    localparam [ACW-1:0] AUTO_LAST_12 = 3 * AUTO_FRAMES - 1;
    localparam [HCW-1:0] HOLD_LAST = (HOLD_FRAMES == 0) ? 0 : HOLD_FRAMES - 1;

    reg [2:0]     state;
    reg [1:0]     target;
    reg [ACW-1:0] auto_cnt;
    wire [ACW-1:0] auto_last = (period_index == 2'd1) ? AUTO_LAST_8 :
                              (period_index == 2'd2) ? AUTO_LAST_12 : AUTO_LAST_4;
    reg [HCW-1:0] hold_cnt;
    reg enter_pending;

    assign busy = (state != S_IDLE);

    // Next loaded cover after cover_idx (0->1->2->0); itself if no other is loaded.
    reg [1:0] next_cover;
    always @(*) begin
        case (cover_idx)
            2'd0:    next_cover = slot_valid[1] ? 2'd1 : slot_valid[2] ? 2'd2 : 2'd0;
            2'd1:    next_cover = slot_valid[2] ? 2'd2 : slot_valid[0] ? 2'd0 : 2'd1;
            default: next_cover = slot_valid[0] ? 2'd0 : slot_valid[1] ? 2'd1 : 2'd2;
        endcase
    end
    wire can_next = (next_cover != cover_idx);
    reg [1:0] prev_cover;
    always @(*) begin
        case (cover_idx)
            2'd0: prev_cover = slot_valid[2] ? 2'd2 : slot_valid[1] ? 2'd1 : 2'd0;
            2'd1: prev_cover = slot_valid[0] ? 2'd0 : slot_valid[2] ? 2'd2 : 2'd1;
            default: prev_cover = slot_valid[1] ? 2'd1 : slot_valid[0] ? 2'd0 : 2'd2;
        endcase
    end
    wire can_prev = (prev_cover != cover_idx);

    // Lowest loaded cover (BOOT only).
    wire       any_cover   = |slot_valid[2:0];
    wire [1:0] first_cover = slot_valid[0] ? 2'd0 : slot_valid[1] ? 2'd1 : 2'd2;

    // Level background slot for the current cover, with fallback to the cover.
    wire [2:0] bg_slot    = {1'b0, cover_idx} + 3'd3;
    wire [2:0] enter_slot = slot_valid[bg_slot] ? bg_slot : {1'b0, cover_idx};

    wire [9:0] alpha_up  = {1'b0, alpha} + STEP;
    wire       on_cover  = (level == 3'd0);
    wire       auto_run  = on_cover && (state == S_IDLE) && auto_mode &&
                          !manual_hold && !period_press && !selector_hold;
    wire       auto_fire = auto_run && frame_start && (auto_cnt == auto_last);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) period_index <= 2'd0;
        else if (period_press && !selector_hold)
            period_index <= (period_index == 2'd2) ? 2'd0 : period_index + 1'b1;
    end

    // Auto carousel frame counter: cleared outside cover-page IDLE / auto mode
    // and on any key press.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            auto_cnt <= {ACW{1'b0}};
        else if (!auto_run || next_press || prev_press || confirm_press)
            auto_cnt <= {ACW{1'b0}};
        else if (frame_start)
            auto_cnt <= (auto_cnt == auto_last) ? {ACW{1'b0}} : auto_cnt + 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_BOOT;
            target       <= T_NEXT;
            level        <= 3'd0;
            display_slot <= 3'd0;
            cover_idx    <= 2'd0;
            alpha        <= 9'd0;
            hold_cnt     <= {HCW{1'b0}};
            blinds_active <= 1'b0;
            enter_pending <= 1'b0;
        end else begin
            // Latch a single confirmation; finish the selected cover first.
            if (blinds_active && state != S_IDLE && confirm_press)
                enter_pending <= 1'b1;
            if (selector_commit && state == S_IDLE && on_cover &&
                selector_slot < 3 && slot_valid[selector_slot]) begin
                cover_idx <= selector_slot;
                display_slot <= {1'b0,selector_slot};
                alpha <= 256;
                blinds_active <= 0;
                enter_pending <= 0;
            end else if (!selector_hold || state != S_IDLE) case (state)
            S_BOOT: begin
                if (frame_start && any_cover) begin
                    cover_idx    <= first_cover;
                    display_slot <= {1'b0, first_cover};
                    state        <= S_FADE_IN;
                end
            end

            S_IDLE: begin
                if (on_cover) begin
                    if (confirm_press || enter_pending) begin
                        enter_pending <= 1'b0;
                        blinds_active <= 1'b0;
                        target <= T_ENTER;
                        state  <= S_FADE_OUT;
                    end else if (prev_press && can_prev) begin
                        blinds_active <= 1'b1;
                        target <= T_PREV;
                        state <= S_FADE_OUT;
                    end else if ((next_press || auto_fire) && can_next) begin
                        blinds_active <= 1'b1;
                        target <= T_NEXT;
                        state  <= S_FADE_OUT;
                    end
                end else if (back_long && !back_block) begin
                    blinds_active <= 1'b0;
                    target <= T_BACK;
                    state  <= S_FADE_OUT;
                end
            end

            S_FADE_OUT: begin
                if (on_cover && confirm_press && !blinds_active)
                    target <= T_ENTER;   // screen still shows cover_idx
                if (frame_start) begin
                    if (alpha == 9'd0) begin
                        // Commit. A confirm in this same cycle is folded in.
                        if ((on_cover && confirm_press && !blinds_active) || target == T_ENTER) begin
                            level        <= {1'b0, cover_idx} + 3'd1;
                            display_slot <= enter_slot;
                        end else if (target == T_BACK) begin
                            level        <= 3'd0;
                            cover_idx    <= level[1:0] - 2'd1;
                            display_slot <= level - 3'd1;
                        end else if (target == T_PREV) begin
                            cover_idx <= prev_cover;
                            display_slot <= {1'b0, prev_cover};
                        end else begin
                            cover_idx    <= next_cover;
                            display_slot <= {1'b0, next_cover};
                        end
                        hold_cnt <= {HCW{1'b0}};
                        state    <= (HOLD_FRAMES == 0) ? S_FADE_IN : S_HOLD;
                    end else if (alpha > FADE_STEP) begin
                        alpha <= alpha - FADE_STEP;
                    end else begin
                        alpha <= 9'd0;
                    end
                end
            end

            S_HOLD: begin
                if (on_cover && confirm_press && !blinds_active) begin
                    // Enter the committed cover; alpha is already 0, so the
                    // next frame_start commits it.
                    target <= T_ENTER;
                    state  <= S_FADE_OUT;
                end else if (frame_start) begin
                    if (hold_cnt == HOLD_LAST)
                        state <= S_FADE_IN;
                    else
                        hold_cnt <= hold_cnt + 1'b1;
                end
            end

            S_FADE_IN: begin
                if (on_cover && confirm_press && !blinds_active) begin
                    // Fade out from the current alpha, entering the committed cover.
                    target <= T_ENTER;
                    state  <= S_FADE_OUT;
                end else if (frame_start) begin
                    if (alpha_up >= 10'd256) begin
                        alpha <= 9'd256;
                        blinds_active <= 1'b0;
                        state <= S_IDLE;
                    end else begin
                        alpha <= alpha_up[8:0];
                    end
                end
            end

            default: begin state <= S_BOOT; blinds_active <= 1'b0; enter_pending <= 1'b0; end
            endcase
        end
    end

endmodule
