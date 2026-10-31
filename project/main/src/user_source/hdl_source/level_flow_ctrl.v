`timescale 1ns/1ps
// T5 level-2 frame flow retained; level 3 implements fault-tolerant
// cumulative hold with hysteresis, grace pause, 1:1 decay, and invalid timeout.
// New-round keys override success; ordinary loss cannot erase latched success.
module level_flow_ctrl #(
    parameter integer CLK_HZ           = 25_000_000, // 25 MHz video_clk
    parameter integer ENTER_RADIUS     = 2,          // enter inner zone radius
    parameter integer KEEP_RADIUS      = 3,          // keep outer zone radius
    parameter integer GRACE_MS         = 200,        // grace pause duration in ms
    parameter integer DECAY_MS_PER_MS  = 1,          // decay rate: 1 ms per 1 ms deviation
    parameter integer INVALID_CLEAR_MS = 750,        // continuous invalid clear in ms
    parameter integer HOLD_MS          = 3000,       // target hold duration in ms
    parameter integer HIT_DIST     = 32,  // 8*|df1| + 6*|df2| (bins) <= HIT_DIST counts as a hit (未用真人数据校准)
    parameter integer CD_FRAMES    = 60,  // frames per countdown digit "3" / "2" / "1" (未用真人数据校准)
    parameter integer PR_FRAMES    = 180, // practice length in frames (未用真人数据校准)
    parameter integer PR_FRAMES_L2 = 240, // level-2 practice length in frames (v34: 4 s; cnt[8:0] holds 0..239) (未用真人数据校准)
    parameter integer START_FRAMES = 45,  // "开始说！" shown for the first START_FRAMES practice frames (未用真人数据校准)
    parameter integer SILENT_FRAMES= 60,  // >= this many frames without a valid frame -> "请发声" (未用真人数据校准)
    parameter integer HOLD_FRAMES  = 15,  // a new hint must be the same for this many frames (未用真人数据校准)
    parameter integer MIN_VALID    = 20,  // valid_cnt < MIN_VALID -> "没听清，再说一遍" (未用真人数据校准)
    parameter integer STAR3_MUL    = 2,   // hit*STAR3_MUL >= valid -> 3 stars (未用真人数据校准)
    parameter integer STAR2_MUL    = 4,   // hit*STAR2_MUL >= valid -> 2 stars (未用真人数据校准)
    parameter integer BLINK_HALF   = 16   // TARGET: target_blink toggles every BLINK_HALF frames (未用真人数据校准)
) (
    input  wire        clk, rst_n, vsync,
    input  wire [2:0]  level_v,
    input  wire        l2_enable,
    input  wire        next_press,     // KEY2, one-clock pulse
    input  wire        confirm_press,  // KEY4, one-clock pulse
    input  wire        vowel_valid,
    input  wire        link_up, vowel_fresh,
    input  wire [5:0]  f1_bin,
    input  wire [6:0]  f2_bin,
    input  wire        f0_valid,       // level 2: silence detection only
    input  wire [5:0]  f0_code,
    input  wire        l2_unheard,     // from tone_game_core (valid when l2_post_done)
    input  wire [1:0]  l2_stars,
    input  wire        l2_post_done,
    input  wire        l2_play_busy,   // tone_audio_rec playback in progress
    output reg  [3:0]  slot_en,
    output reg  [19:0] slot_id,
    output reg  [39:0] slot_cx,
    output reg  [35:0] slot_cy,
    output reg  [11:0] slot_kind,
    output wire        subtitle_enable,
    output reg         target_en,
    output reg  [2:0]  target_id,
    output reg         target_blink,
    output reg  [1:0]  stage,
    output reg  [1:0]  stars,
    output reg         l2_pract,       // level 2 && stage == PRACTICE
    output reg  [1:0]  l2_tone,        // level-2 target tone 0..3
    output reg         l2_target_blink,
    output wire [5:0]  hold_progress,
    output wire        hold_progress_en,
    output wire [1:0]  hold_phase
);
    localparam [1:0] S_TARGET = 2'd0, S_COUNT = 2'd1, S_PRACT = 2'd2, S_RESULT = 2'd3;
    localparam [2:0] K_GO = 3'd0, K_OK = 3'd1, K_UP = 3'd2, K_WIN = 3'd4, K_GREY = 3'd5;
    localparam [4:0] H_NONE = 5'd31;
    localparam [8:0] CY_TOP = 9'd25;

    // ---------------- Frame start (registered) ----------------
    reg vs_q, frame_start;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_q <= 1'b1;
            frame_start <= 1'b0;
        end else begin
            vs_q <= vsync;
            frame_start <= vs_q && !vsync;
        end
    end

    wire lv3     = (level_v == 3'd3);
    wire lv2     = (level_v == 3'd2) && l2_enable;
    wire flow_on = lv3 || lv2;
    assign subtitle_enable = flow_on;

    // ---------------- Targets ----------------
    function [2:0] pos2id;   // KEY2 order position -> vowel id
        input [2:0] p;
        case (p)
            3'd0: pos2id = 3'd0;  // a
            3'd1: pos2id = 3'd2;  // o
            3'd2: pos2id = 3'd1;  // e
            3'd3: pos2id = 3'd4;  // i
            3'd4: pos2id = 3'd3;  // u
            3'd5: pos2id = 3'd5; // yu
            default: pos2id = 3'd7; // illegal target
        endcase
    endfunction
    function [5:0] tgt_f1;   // same bins as vowel_chart_overlay24 lines 36-41
        input [2:0] id;
        case (id)
            3'd0: tgt_f1 = 6'd26; 3'd1: tgt_f1 = 6'd17; 3'd2: tgt_f1 = 6'd20;
            3'd3: tgt_f1 = 6'd12; 3'd4: tgt_f1 = 6'd10; default: tgt_f1 = 6'd10;
        endcase
    endfunction
    function [6:0] tgt_f2;
        input [2:0] id;
        case (id)
            3'd0: tgt_f2 = 7'd40; 3'd1: tgt_f2 = 7'd37; 3'd2: tgt_f2 = 7'd30;
            3'd3: tgt_f2 = 7'd23; 3'd4: tgt_f2 = 7'd76; default: tgt_f2 = 7'd69;
        endcase
    endfunction

    reg  [2:0] tgt_pos;
    wire [2:0] tid = pos2id(tgt_pos);
    wire [5:0] t1  = tgt_f1(tid);
    wire [6:0] t2  = tgt_f2(tid);
    wire [2:0] tgt_pos_next = (tgt_pos == 3'd5) ? 3'd0 : tgt_pos + 1'b1;
    reg  [1:0] tgt2;           // level-2 target tone (KEY2: 0 -> 1 -> 2 -> 3 -> 0)

    // ---------------- Practice state ----------------
    reg [8:0]  cnt;            // frames in COUNTDOWN / PRACTICE
    reg [5:0]  blink_cnt;      // frames in TARGET
    reg [7:0]  silent_cnt;     // consecutive frames without a valid frame (saturating)
    reg [7:0]  sil2;           // level 2: consecutive unvoiced frames (saturating)
    reg [5:0]  w1 [0:7];       // last 8 valid f1 / f2
    reg [6:0]  w2 [0:7];
    reg [3:0]  win_n;          // 0..8 valid entries in the window
    reg [8:0]  sum1;           // sum of w1
    reg [9:0]  sum2;           // sum of w2
    reg        sampled;        // one clock after a practice sample
    reg [4:0]  last_cand;
    reg [4:0]  stab_cnt;
    reg [4:0]  cur_hint;
    reg        next_pend, conf_pend;
    reg [2:0]  lv_q;
    integer    i;

    // Live-hint candidate from the 8-frame window. Using the sums directly:
    // 8*dF = sum - 8*T, so all comparisons are scaled by 8 (no truncation).
    // One signed subtraction per axis, then conditional two's complement.
    // sum1<=504, sum2<=1016; these widths also cover every legal target.
    wire signed [9:0] diff1 = $signed({1'b0, sum1}) - $signed({1'b0, t1, 3'b000});
    wire signed [10:0] diff2 = $signed({1'b0, sum2}) - $signed({1'b0, t2, 3'b000});
    wire d1_neg = diff1[9];
    wire d2_pos = !diff2[10] && |diff2;
    wire [8:0] a1 = diff1[9] ? -diff1 : diff1;
    wire [9:0] a2 = diff2[10] ? -diff2 : diff2;
    // 8*a1 >= 6*a2 iff 4*a1 >= 3*a2: no truncation or division.
    wire [11:0] a1x4 = {1'b0, a1, 2'b00};
    wire [11:0] a2x3 = {1'b0, a2, 1'b0} + {2'b00, a2};
    reg  [4:0]  cand;
    always @(*) begin
        if (win_n < 4'd8)                      cand = H_NONE;  // direction only
        else if (a1x4 >= a2x3)                 cand = d1_neg ? 5'd15 : 5'd16; // 张大 / 收小
        else                                   cand = d2_pos ? 5'd18 : 5'd17; // 往后 / 往前
    end

    wire key_next = next_pend || next_press;
    wire key_conf = conf_pend || confirm_press;
    wire lv_change = (level_v != lv_q);
    wire f0_voiced = f0_valid && (f0_code >= 6'd2) && (f0_code <= 6'd62);

    reg [2:0] tid_q;
    // Existing pending bits also serve as the practice abort barrier.
    wire abort_pending = next_pend || conf_pend;
    wire field_valid = vowel_valid && link_up && vowel_fresh;
    wire new_round_key = lv3 && stage != S_COUNT && (key_next || key_conf);
    wire round_clear = !lv3 || lv_change || tid != tid_q || new_round_key;

    // Coordinate differences and rectangular hysteresis detection
    wire [5:0] diff_f1 = (f1_bin >= t1) ? (f1_bin - t1) : (t1 - f1_bin);
    wire [6:0] diff_f2 = (f2_bin >= t2) ? (f2_bin - t2) : (t2 - f2_bin);
    wire in_enter = (tid < 3'd6) && (diff_f1 <= ENTER_RADIUS) && (diff_f2 <= ENTER_RADIUS);
    wire in_keep  = (tid < 3'd6) && (diff_f1 <= KEEP_RADIUS)  && (diff_f2 <= KEEP_RADIUS);

    // Timing parameters and bit widths
    localparam integer CPMS     = CLK_HZ / 1000;
    localparam integer SUBMS_W  = (CPMS < 2) ? 1 : $clog2(CPMS);
    localparam integer ACCUM_W  = (HOLD_MS < 2) ? 1 : $clog2(HOLD_MS + 1);
    localparam integer GRACE_W  = (GRACE_MS < 2) ? 1 : $clog2(GRACE_MS + 1);
    localparam integer INV_W    = (INVALID_CLEAR_MS < 2) ? 1 : $clog2(INVALID_CLEAR_MS + 1);

    // synthesis translate_off
    initial begin
        if (CLK_HZ <= 0 || (CLK_HZ % 1000) != 0 || (CLK_HZ / 1000) < 1)
            $fatal(1, "CLK_HZ must be positive, divisible by 1000, and CPMS >= 1");
        if (ENTER_RADIUS < 0 || ENTER_RADIUS > KEEP_RADIUS || KEEP_RADIUS > 63)
            $fatal(1, "Radii must satisfy 0 <= ENTER_RADIUS <= KEEP_RADIUS <= 63");
        if (HOLD_MS < 1 || HOLD_MS > 100_000_000 || INVALID_CLEAR_MS < 1)
            $fatal(1, "HOLD_MS must be between 1 and 100000000; INVALID_CLEAR_MS must be >= 1");
        if (GRACE_MS < 0 || DECAY_MS_PER_MS < 0)
            $fatal(1, "GRACE_MS and DECAY_MS_PER_MS must be non-negative");
        if (START_FRAMES < 0 || START_FRAMES > 511)
            $fatal(1, "Invalid START_FRAMES parameter");
    end
    // synthesis translate_on

    reg [ACCUM_W-1:0] accum_ms;
    reg [SUBMS_W-1:0] add_subms;
    reg [GRACE_W-1:0] pos_grace_ms;
    reg [SUBMS_W-1:0] pos_subms;
    reg [INV_W-1:0]   inv_ms;
    reg [SUBMS_W-1:0] inv_subms;
    reg captured;
    wire armed = captured;
    reg done;
    reg add_running;
    reg pos_running;
    reg inv_running;

    // Level-3 Hold & Fault-Tolerance State Machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum_ms     <= {ACCUM_W{1'b0}};
            add_subms    <= {SUBMS_W{1'b0}};
            pos_grace_ms <= {GRACE_W{1'b0}};
            pos_subms    <= {SUBMS_W{1'b0}};
            inv_ms       <= {INV_W{1'b0}};
            inv_subms    <= {SUBMS_W{1'b0}};
            captured     <= 1'b0;
            done         <= 1'b0;
            add_running  <= 1'b0;
            pos_running  <= 1'b0;
            inv_running  <= 1'b0;
        end else if (round_clear) begin
            // Priority 1: Lifecycle clear (reset / level change / target change / retry / next / pending barrier)
            accum_ms     <= {ACCUM_W{1'b0}};
            add_subms    <= {SUBMS_W{1'b0}};
            pos_grace_ms <= {GRACE_W{1'b0}};
            pos_subms    <= {SUBMS_W{1'b0}};
            inv_ms       <= {INV_W{1'b0}};
            inv_subms    <= {SUBMS_W{1'b0}};
            captured     <= 1'b0;
            done         <= 1'b0;
            add_running  <= 1'b0;
            pos_running  <= 1'b0;
            inv_running  <= 1'b0;
        end else if (done) begin
            // Priority 2: Already done -> latched success
            add_running <= 1'b0;
            add_subms   <= {SUBMS_W{1'b0}};
            pos_running <= 1'b0;
            inv_running <= 1'b0;
        end else if (stage != S_PRACT) begin
            // Priority 3: Not in practice -> clear uncompleted practice history
            accum_ms     <= {ACCUM_W{1'b0}};
            add_subms    <= {SUBMS_W{1'b0}};
            pos_grace_ms <= {GRACE_W{1'b0}};
            pos_subms    <= {SUBMS_W{1'b0}};
            inv_ms       <= {INV_W{1'b0}};
            inv_subms    <= {SUBMS_W{1'b0}};
            captured     <= 1'b0;
            add_running  <= 1'b0;
            pos_running  <= 1'b0;
            inv_running  <= 1'b0;
        end else if (!link_up || !vowel_fresh || !vowel_valid) begin
            // Priority 4/5 (T10b): link loss, stale field packet or gated vowel invalid ->
            // freeze A, captured and the adding fraction, freeze pos, run invalid timer;
            // A clears only after INVALID_CLEAR_MS. Brief dropouts (even < 1 ms) therefore
            // pause the hold count instead of clearing or stalling it.
            pos_running <= 1'b0; // Freeze position deviation timer (keeps pos_grace_ms and pos_subms)
            if (!inv_running) begin
                inv_running <= 1'b1;
                inv_subms   <= {SUBMS_W{1'b0}};
            end else begin
                if (inv_subms == CPMS - 1) begin
                    inv_subms <= {SUBMS_W{1'b0}};
                    if (inv_ms < INVALID_CLEAR_MS) begin
                        if (inv_ms + 1'b1 >= INVALID_CLEAR_MS) begin
                            inv_ms       <= INVALID_CLEAR_MS[INV_W-1:0];
                            accum_ms     <= {ACCUM_W{1'b0}};
                            pos_grace_ms <= {GRACE_W{1'b0}};
                            pos_subms    <= {SUBMS_W{1'b0}};
                        end else begin
                            inv_ms <= inv_ms + 1'b1;
                        end
                    end
                end else begin
                    inv_subms <= inv_subms + 1'b1;
                end
            end
        end else if (in_enter || (captured && in_keep)) begin
            // Priority 6: Fresh valid and (in inner zone OR (captured && in keep zone))
            captured    <= 1'b1;
            inv_running <= 1'b0;
            inv_ms      <= {INV_W{1'b0}};
            inv_subms   <= {SUBMS_W{1'b0}};
            pos_running <= 1'b0;
            pos_grace_ms<= {GRACE_W{1'b0}};
            pos_subms   <= {SUBMS_W{1'b0}};
            if (!add_running) begin
                add_running <= 1'b1;
                add_subms   <= {SUBMS_W{1'b0}};
            end else begin
                if (add_subms == CPMS - 1) begin
                    add_subms <= {SUBMS_W{1'b0}};
                    if (accum_ms + 1'b1 >= HOLD_MS) begin
                        accum_ms <= HOLD_MS[ACCUM_W-1:0];
                        done     <= 1'b1;
                    end else begin
                        accum_ms <= accum_ms + 1'b1;
                    end
                end else begin
                    add_subms <= add_subms + 1'b1;
                end
            end
        end else begin
            // Priority 7: Fresh valid but not captured (outer ring alone or outside keep zone)
            captured    <= 1'b0;
            add_running <= 1'b0;
            add_subms   <= {SUBMS_W{1'b0}};
            inv_running <= 1'b0;
            inv_ms      <= {INV_W{1'b0}};
            inv_subms   <= {SUBMS_W{1'b0}};
            if (!pos_running) begin
                pos_running <= 1'b1;
            end else begin
                if (pos_subms == CPMS - 1) begin
                    pos_subms <= {SUBMS_W{1'b0}};
                    if (pos_grace_ms < GRACE_MS) begin
                        pos_grace_ms <= pos_grace_ms + 1'b1;
                    end else begin
                        // Grace expired: decay A by DECAY_MS_PER_MS (0 saturated)
                        if (accum_ms <= DECAY_MS_PER_MS) begin
                            accum_ms <= {ACCUM_W{1'b0}};
                        end else begin
                            accum_ms <= accum_ms - DECAY_MS_PER_MS[ACCUM_W-1:0];
                        end
                    end
                end else begin
                    pos_subms <= pos_subms + 1'b1;
                end
            end
        end
    end

    // Real-time adding qualification (for subtitles and hold_phase)
    wire add_qual = lv3 && (stage == S_PRACT) && !abort_pending && !round_clear &&
                    field_valid && (in_enter || (captured && in_keep));

    // Progress calculation: floor(63 * A / HOLD_MS), max 62 when not done, 63 when done.
    localparam integer SCALED_W = ACCUM_W + 6;
    // Extend before shifting: a narrow shift would truncate large HOLD_MS.
    // 63*A = (A<<6)-A keeps this constant scale in carry/LUT logic.
    wire [SCALED_W-1:0] accum_extended = {{6{1'b0}}, accum_ms};
    wire [SCALED_W-1:0] scaled_prog = (accum_extended << 6) - accum_extended;
    wire [SCALED_W-1:0] div_prog    = scaled_prog / HOLD_MS;
    wire [5:0]  raw_prog    = (div_prog > 62) ? 6'd62 : div_prog[5:0];
    assign hold_progress    = round_clear ? 6'd0 : (done ? 6'd63 : raw_prog);
    assign hold_progress_en = lv3 && !round_clear &&
                              (stage == S_PRACT || (stage == S_RESULT && done));

    // Hold phase output:
    // 00: not practicing
    // 01: active eligible (adding)
    // 10: paused / decaying / invalid / communication error
    // 11: done
    assign hold_phase = (!lv3 || round_clear || (stage != S_PRACT && !(stage == S_RESULT && done))) ? 2'b00
                      : done ? 2'b11
                      : add_qual ? 2'b01
                      : 2'b10;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tid_q <= 3'd0;
        else tid_q <= tid;
    end

    task clear_practice;
        begin
            silent_cnt <= 8'd0;
            win_n <= 4'd0; sum1 <= 9'd0; sum2 <= 10'd0;
            last_cand <= H_NONE; stab_cnt <= 5'd0; cur_hint <= 5'd4;
            for (i = 0; i < 8; i = i + 1) begin w1[i] <= 6'd0; w2[i] <= 7'd0; end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage <= S_TARGET; tgt_pos <= 3'd0; cnt <= 9'd0; blink_cnt <= 6'd0;
            next_pend <= 1'b0; conf_pend <= 1'b0; lv_q <= 3'd0; sampled <= 1'b0;
            clear_practice();
            tgt2 <= 2'd0; sil2 <= 8'd0;
        end else begin
            lv_q <= level_v;
            sampled <= 1'b0;
            if (!flow_on || lv_change) begin
                stage <= S_TARGET; cnt <= 9'd0; blink_cnt <= 6'd0;
                next_pend <= 1'b0; conf_pend <= 1'b0;
            end else if (frame_start) begin
                next_pend <= 1'b0; conf_pend <= 1'b0;
                case (stage)
                    S_TARGET: begin
                        if (key_conf) begin
                            stage <= S_COUNT; cnt <= 9'd0;
                        end else if (key_next) begin
                            if (lv2) tgt2 <= tgt2 + 1'b1;
                            else     tgt_pos <= tgt_pos_next;
                            blink_cnt <= 6'd0;
                        end else begin
                            blink_cnt <= (blink_cnt == 2 * BLINK_HALF - 1) ? 6'd0 : blink_cnt + 1'b1;
                        end
                    end
                    S_COUNT: begin
                        if (cnt == 3 * CD_FRAMES - 1) begin
                            stage <= S_PRACT; cnt <= 9'd0;
                            clear_practice();
                            sil2 <= 8'd0;
                        end else
                            cnt <= cnt + 1'b1;
                    end
                    S_PRACT: begin
                        // Sample the inputs present at this frame start.
                        sampled <= 1'b1;
                        if (lv3 && field_valid) begin
                            silent_cnt <= 8'd0;
                            for (i = 7; i > 0; i = i - 1) begin w1[i] <= w1[i-1]; w2[i] <= w2[i-1]; end
                            w1[0] <= f1_bin; w2[0] <= f2_bin;
                            sum1 <= sum1 + f1_bin - (win_n == 4'd8 ? w1[7] : 6'd0);
                            sum2 <= sum2 + f2_bin - (win_n == 4'd8 ? w2[7] : 7'd0);
                            if (win_n != 4'd8) win_n <= win_n + 1'b1;
                        end else if (silent_cnt != 8'hFF)
                            silent_cnt <= silent_cnt + 1'b1;
                        if (f0_voiced)
                            sil2 <= 8'd0;
                        else if (sil2 != 8'hFF)
                            sil2 <= sil2 + 1'b1;
                        if (lv2) begin
                            if (cnt == PR_FRAMES_L2 - 1) begin
                                stage <= S_RESULT; cnt <= 9'd0;
                            end else cnt <= cnt + 1'b1;
                        end else if (key_conf) begin
                            stage <= S_COUNT; cnt <= 9'd0; clear_practice();
                        end else if (key_next) begin
                            stage <= S_TARGET; cnt <= 9'd0; blink_cnt <= 6'd0;
                            tgt_pos <= tgt_pos_next; clear_practice();
                        end else if (done) begin
                            stage <= S_RESULT; cnt <= 9'd0;
                        end else if (cnt < START_FRAMES) cnt <= cnt + 1'b1;
                    end
                    default: begin // S_RESULT
                        if (key_conf) begin
                            stage <= S_COUNT; cnt <= 9'd0;
                        end else if (key_next) begin
                            stage <= S_TARGET; blink_cnt <= 6'd0;
                            if (lv2) tgt2 <= tgt2 + 1'b1;
                            else     tgt_pos <= tgt_pos_next;
                        end
                    end
                endcase
            end else begin
                // Level-3 practice keys abort immediately, commit at frame start.
                if (stage == S_TARGET || stage == S_RESULT || (lv3 && stage == S_PRACT)) begin
                    if (next_press)    next_pend <= 1'b1;
                    if (confirm_press) conf_pend <= 1'b1;
                end
            end

            // Clear directional history on the first explicit round action.
            if (lv3 && (new_round_key || lv_change || tid != tid_q)) clear_practice();

            // Hint debounce, one clock after each practice sample.
            if (sampled && flow_on && !lv_change && !new_round_key) begin
                if (cand == last_cand) begin
                    if (stab_cnt != 5'd31) stab_cnt <= stab_cnt + 1'b1;
                    if (cand != H_NONE && stab_cnt + 1'b1 >= HOLD_FRAMES) cur_hint <= cand;
                end else begin
                    last_cand <= cand;
                    stab_cnt <= 5'd1;
                    if (cand != H_NONE && HOLD_FRAMES <= 1) cur_hint <= cand;
                end
            end
        end
    end

    // ---------------- Outputs (registered) ----------------
    reg [3:0]  n_en;
    reg [19:0] n_id;
    reg [39:0] n_cx;
    reg [11:0] n_kind;
    reg [4:0]  h;
    // On the clock of a level change the registers still hold the old level's stage.
    // v33: when that old state belongs to level 2 (or the new level is a flow level),
    // show the reset state (TARGET, blink_cnt 0) on that clock. With level 2 disabled
    // (v32) the state seen there was always this reset state, so level 3 and the
    // 3 -> 0/1/4.. transition stay clock-for-clock identical to v32.
    wire       stale_l2   = lv_change && (flow_on || lv_q == 3'd2);
    wire [1:0] stage_o    = stale_l2 ? S_TARGET : stage;
    wire [5:0] blink_o    = stale_l2 ? 6'd0 : blink_cnt;
    always @(*) begin
        n_en = 4'd0; n_id = 20'd0; n_cx = 40'd0; n_kind = 12'd0;
        h = 5'd0;
        if (flow_on) begin
            n_en[0] = 1'b1;
            n_cx[9:0] = 10'd366;
            n_kind[2:0] = K_GO;
            case (stage_o)
                S_TARGET: n_id[4:0] = 5'd0;
                S_COUNT:  n_id[4:0] = (cnt < CD_FRAMES) ? 5'd1 : (cnt < 2 * CD_FRAMES) ? 5'd2 : 5'd3;
                S_PRACT: begin
                    if (lv2) begin
                        // Level 2: "开始说！" / "请发声" only, otherwise slot 0 off.
                        if (cnt < START_FRAMES)           n_id[4:0] = 5'd4;
                        else if (sil2 >= SILENT_FRAMES)   n_id[4:0] = 5'd5;
                        else                              n_en = 4'd0;
                    end else begin
                        if (cnt < START_FRAMES) h = 5'd4;
                        else if (!field_valid) h = 5'd5;
                        else if (add_qual) h = 5'd19;
                        else if (!abort_pending && !round_clear && cur_hint >= 5'd15 && cur_hint <= 5'd18)
                            h = cur_hint;
                        else h = H_NONE;
                        if (h == H_NONE) n_en = 4'd0;
                        n_id[4:0] = h;
                        n_kind[2:0] = (h == 5'd19) ? K_OK : (h >= 5'd15) ? K_UP : K_GO;
                    end
                end
                default: begin
                    if (lv2) begin
                        // Level 2 RESULT: gold frame only until tone_game_core is done.
                        if (!l2_post_done) begin
                            n_en = 4'd0;
                        end else if (l2_play_busy) begin
                            n_id[4:0] = 5'd10;                    // 回放中…
                        end else if (l2_unheard) begin
                            n_id[4:0] = 5'd8; n_kind[2:0] = K_UP;
                        end else begin
                            n_en = 4'b1111;
                            n_id[4:0]   = (l2_stars >= 2'd2) ? 5'd6 : 5'd7;
                            n_kind[2:0] = (l2_stars >= 2'd2) ? K_WIN : K_UP;
                            n_cx[9:0]   = 10'd430;
                            n_id[9:5] = 5'd9; n_id[14:10] = 5'd9; n_id[19:15] = 5'd9;
                            n_cx[19:10] = 10'd250; n_cx[29:20] = 10'd286; n_cx[39:30] = 10'd322;
                            n_kind[5:3]  = (l2_stars >= 2'd1) ? K_WIN : K_GREY;
                            n_kind[8:6]  = (l2_stars >= 2'd2) ? K_WIN : K_GREY;
                            n_kind[11:9] = (l2_stars >= 2'd3) ? K_WIN : K_GREY;
                        end
                    end else begin
                        n_en = 4'b1111;
                        n_id[4:0]   = 5'd6;
                        n_kind[2:0] = K_WIN;
                        n_cx[9:0]   = 10'd430;
                        n_id[9:5] = 5'd9; n_id[14:10] = 5'd9; n_id[19:15] = 5'd9;
                        n_cx[19:10] = 10'd250; n_cx[29:20] = 10'd286; n_cx[39:30] = 10'd322;
                        n_kind[5:3]  = K_WIN;
                        n_kind[8:6]  = K_WIN;
                        n_kind[11:9] = K_WIN;
                    end
                end
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slot_en <= 4'd0; slot_id <= 20'd0; slot_cx <= 40'd0; slot_cy <= 36'd0; slot_kind <= 12'd0;
            target_en <= 1'b0; target_id <= 3'd0; target_blink <= 1'b1; stars <= 2'd0;
            l2_pract <= 1'b0; l2_tone <= 2'd0; l2_target_blink <= 1'b1;
        end else begin
            slot_en <= n_en; slot_id <= n_id; slot_cx <= n_cx; slot_kind <= n_kind;
            slot_cy <= flow_on ? {4{CY_TOP}} : 36'd0;
            target_en <= lv3 && flow_on;
            target_id <= tid;
            target_blink <= (stage_o == S_TARGET) ? (blink_o < BLINK_HALF) : 1'b1;
            stars <= (stage_o == S_RESULT && flow_on)
                   ? (lv2 ? ((l2_post_done && !l2_unheard) ? l2_stars : 2'd0) : (done ? 2'd3 : 2'd0)) : 2'd0;
            l2_pract <= lv2 && (stage_o == S_PRACT);
            l2_tone <= tgt2;
            l2_target_blink <= (stage_o == S_TARGET) ? (blink_o < BLINK_HALF) : 1'b1;
        end
    end
endmodule
