// SW1 selects parameter mode; SW2 selects threshold (1) / brightness (0).
module parameter_controls #(
    parameter integer DEBOUNCE_CYCLES = 500000,
    parameter integer LONG_CYCLES = 50000000,
    // 1 ms at the 25 MHz video clock; small simulation timings retain cycle resolution.
    parameter integer SAMPLE_CYCLES = (DEBOUNCE_CYCLES < 25000) ? 1 : 25000
)(
    input wire clk, rst_n,
    input wire sw_mode, sw_select, key_down_n, key_up_n,
    input wire [3:0] calibration_status,
    input wire interaction_locked,
    input wire selector_owned, selector_active,
    output reg mode, select_threshold,
    output reg [3:0] brightness,
    output reg threshold_down, threshold_up,
    output reg practice_start,
    output reg next_press, prev_press, confirm_press, period_press,
    output wire navigation_hold,
    output wire image_next_n, image_auto_n
);
    localparam integer DB_TICKS = (DEBOUNCE_CYCLES + SAMPLE_CYCLES - 1) / SAMPLE_CYCLES;
    localparam integer LONG_TICKS = (LONG_CYCLES + SAMPLE_CYCLES - 1) / SAMPLE_CYCLES;
    localparam integer CW = (DB_TICKS < 2) ? 1 : $clog2(DB_TICKS);
    wire sample_tick;
    generate
        if (SAMPLE_CYCLES == 1) begin : g_each_cycle
            assign sample_tick = 1'b1;
        end else begin : g_millisecond
            localparam integer TW = $clog2(SAMPLE_CYCLES);
            reg [TW-1:0] tick_count;
            assign sample_tick = (tick_count == SAMPLE_CYCLES - 1);
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) tick_count <= 0;
                else if (sample_tick) tick_count <= 0;
                else tick_count <= tick_count + 1'b1;
            end
        end
    endgenerate
    wire [3:0] raw_inputs = {key_up_n, key_down_n, sw_select, sw_mode};
    reg [3:0] input_meta, input_sync, stable_inputs;
    reg [CW-1:0] stable_count [0:3];
    reg [1:0] previous_keys;
    reg armed;
    reg previous_locked;
    reg previous_selector;
    localparam integer LW = (LONG_TICKS < 2) ? 1 : $clog2(LONG_TICKS);
    // Chords cancel both gestures, so KEY2 and KEY4 can share one timer.
    reg [LW-1:0] hold_count;
    reg gesture_pending, gesture_up, gesture_long_fired;
    wire gesture_pressed = gesture_up ? !stable_inputs[3] : !stable_inputs[2];
    integer i;
    wire switches_settled = (input_sync[1:0] == stable_inputs[1:0]) &&
                            (stable_inputs[1:0] == {select_threshold, mode});
    wire keys_settled = (input_sync[3:2] == stable_inputs[3:2]);
    wire lock_settled = (previous_locked == interaction_locked);
    wire selector_settled = previous_selector == selector_owned;
    wire effective_switches = selector_owned || switches_settled;
    wire normal_enabled = armed && effective_switches && keys_settled &&
                          ((!selector_owned && !mode && !interaction_locked && lock_settled) ||
                           (selector_owned && selector_active)) && selector_settled;
    assign image_next_n = normal_enabled && !selector_owned ? stable_inputs[2] : 1'b1;
    assign image_auto_n = normal_enabled && !selector_owned ? stable_inputs[3] : 1'b1;
    // Pause auto navigation through press/release debounce and event delivery.
    // Using the legacy key level alone leaves a gap while keys are settling.
    assign navigation_hold = !mode && (input_sync[3:2] != 2'b11 ||
                                      stable_inputs[3:2] != 2'b11 ||
                                      gesture_pending || next_press ||
                                      prev_press || confirm_press || period_press);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_meta <= 4'b1100;
            input_sync <= 4'b1100;
            stable_inputs <= 4'b1100;
            for (i = 0; i < 4; i = i + 1) stable_count[i] <= 0;
        end else begin
            input_meta <= raw_inputs;
            input_sync <= input_meta;
            for (i = 0; i < 4; i = i + 1) begin
                if (input_sync[i] == stable_inputs[i]) stable_count[i] <= 0;
                else if (sample_tick && stable_count[i] == DB_TICKS - 1) begin
                    stable_inputs[i] <= input_sync[i];
                    stable_count[i] <= 0;
                end else if (sample_tick) stable_count[i] <= stable_count[i] + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode <= 0;
            select_threshold <= 0;
            brightness <= 8;
            threshold_down <= 0;
            threshold_up <= 0;
            practice_start <= 0;
            next_press <= 0;
            prev_press <= 0;
            confirm_press <= 0;
            period_press <= 0;
            hold_count <= 0;
            gesture_pending <= 0;
            gesture_up <= 0;
            gesture_long_fired <= 0;
            previous_keys <= 2'b11;
            previous_locked <= 0;
            previous_selector <= 0;
            armed <= 0;
        end else begin
            mode <= stable_inputs[0];
            select_threshold <= stable_inputs[1];
            previous_keys <= stable_inputs[3:2];
            previous_locked <= interaction_locked;
            previous_selector <= selector_owned;
            threshold_down <= 0;
            threshold_up <= 0;
            practice_start <= 0;
            next_press <= 0;
            prev_press <= 0;
            confirm_press <= 0;
            period_press <= 0;
            // A mode/selection/lock transition cancels the current gesture. Both
            // keys must be stably released before either function can resume.
            if (!selector_settled || (selector_owned && !selector_active) ||
                (!selector_owned && (!switches_settled || !lock_settled || interaction_locked)) ||
                input_sync[3:2] == 2'b00)
                begin
                    armed <= 0;
                    gesture_pending <= 0;
                end
            else if (!armed) begin
                gesture_pending <= 0;
                if (keys_settled && stable_inputs[3:2] == 2'b11) armed <= 1;
            end else if (normal_enabled) begin
                // One gesture engine serves both keys; long actions consume release.
                if ((previous_keys[0] && !stable_inputs[2] && stable_inputs[3]) ||
                    (previous_keys[1] && !stable_inputs[3] && stable_inputs[2])) begin
                    gesture_pending <= 1;
                    gesture_up <= !stable_inputs[3];
                    hold_count <= 0;
                    gesture_long_fired <= 0;
                end else if (gesture_pending && gesture_pressed && !gesture_long_fired) begin
                    if (sample_tick && hold_count == LONG_TICKS - 1) begin
                        if (gesture_up) begin if (!selector_owned) period_press <= 1; end
                        else prev_press <= 1;
                        gesture_long_fired <= 1;
                    end else if (sample_tick) hold_count <= hold_count + 1'b1;
                end else if (gesture_pending && !gesture_pressed) begin
                    if (!gesture_long_fired) begin
                        if (gesture_up && !selector_owned) begin
                            confirm_press <= 1;
                            if (calibration_status == 4) practice_start <= 1;
                        end else if (!gesture_up) next_press <= 1;
                    end
                    gesture_pending <= 0;
                end
            end else if (!selector_owned && mode && keys_settled) begin
                gesture_pending <= 0;
                if (previous_keys[0] && !stable_inputs[2] && stable_inputs[3]) begin
                    if (select_threshold) begin
                        if (calibration_status == 4) threshold_down <= 1;
                    end else if (brightness > 4) brightness <= brightness - 1'b1;
                end
                if (previous_keys[1] && !stable_inputs[3] && stable_inputs[2]) begin
                    if (select_threshold) begin
                        if (calibration_status == 4) threshold_up <= 1;
                    end else if (brightness < 12) brightness <= brightness + 1'b1;
                end
            end
        end
    end
endmodule
