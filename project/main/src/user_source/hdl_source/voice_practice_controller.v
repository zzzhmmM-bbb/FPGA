// Volume-only practice. Thresholds are captured when a round starts.
module voice_practice_controller #(
    parameter integer CLK_HZ = 25000000,
    parameter integer DEMO_MS = 2000,
    parameter integer COUNTDOWN_MS = 3000,
    parameter integer SESSION_MS = 8000,
    parameter integer GOAL_MS = 5000,
    parameter integer AUDIO_TIMEOUT_MS = 50
)(
    input wire clk, rst_n,
    input wire calibration_ready, parameter_mode, start_press, audio_valid,
    input wire [15:0] energy, reference_level, low_threshold, high_threshold,
    output reg [2:0] state,
    output wire busy,
    output reg [1:0] countdown_digit,
    output reg [12:0] current_ms, best_ms, progress_ms,
    output reg in_target, result_success,
    output reg [15:0] target_low, target_high, target_reference,
    output reg [12:0] elapsed_ms, in_range_ms,
    output reg trace_tick,
    output reg [15:0] trace_energy,
    output reg [1:0] trace_class
);
    localparam integer CYCLES_PER_MS = CLK_HZ / 1000;
    localparam integer MS_CW = (CYCLES_PER_MS < 2) ? 1 : $clog2(CYCLES_PER_MS);
    localparam integer TIMEOUT_CYCLES = CYCLES_PER_MS * AUDIO_TIMEOUT_MS;
    localparam integer AGE_CW = (TIMEOUT_CYCLES < 2) ? 1 : $clog2(TIMEOUT_CYCLES + 1);
    localparam [2:0] UNCALIBRATED = 0, IDLE = 1, DEMO = 2,
                     COUNTDOWN = 3, PRACTICE = 4, RESULT = 5;
    reg [MS_CW-1:0] ms_divider;
    reg [12:0] phase_ms;
    reg [AGE_CW-1:0] audio_age;
    reg audio_seen;
    reg [15:0] latest_energy;
    wire ms_tick = (ms_divider == CYCLES_PER_MS - 1);
    wire new_in_target = (energy >= target_low) && (energy < target_high);
    // At a tick, a new sample overrides the old sample and timeout. Without
    // an update, the sample expires exactly TIMEOUT_CYCLES clocks after it.
    wire sample_fresh = audio_valid || (audio_seen && audio_age < TIMEOUT_CYCLES - 1);
    wire sample_in_target = audio_valid ? new_in_target : in_target;
    wire counting = sample_fresh && sample_in_target;
    wire [15:0] sampled_energy = audio_valid ? energy : latest_energy;
    assign busy = (state == DEMO) || (state == COUNTDOWN) || (state == PRACTICE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= UNCALIBRATED;
            countdown_digit <= 0;
            current_ms <= 0;
            best_ms <= 0;
            progress_ms <= 0;
            in_target <= 0;
            result_success <= 0;
            target_low <= 0;
            target_high <= 0;
            target_reference <= 0;
            ms_divider <= 0;
            phase_ms <= 0;
            audio_age <= 0;
            audio_seen <= 0;
            latest_energy <= 0;
            elapsed_ms <= 0;
            in_range_ms <= 0;
            trace_tick <= 0;
            trace_energy <= 0;
            trace_class <= 3;
        end else begin
            trace_tick <= 0;
            if (busy) begin
                if (ms_tick) ms_divider <= 0;
                else ms_divider <= ms_divider + 1'b1;
            end else ms_divider <= 0;

            if (state == UNCALIBRATED || state == IDLE) begin
                target_low <= low_threshold;
                target_high <= high_threshold;
                target_reference <= reference_level;
            end

            if (!calibration_ready || (parameter_mode && busy) ||
                (state == RESULT && (low_threshold != target_low ||
                 high_threshold != target_high || reference_level != target_reference))) begin
                state <= calibration_ready ? IDLE : UNCALIBRATED;
                countdown_digit <= 0;
                current_ms <= 0;
                best_ms <= 0;
                progress_ms <= 0;
                in_target <= 0;
                result_success <= 0;
                ms_divider <= 0;
                phase_ms <= 0;
                audio_age <= 0;
                audio_seen <= 0;
                latest_energy <= 0;
                elapsed_ms <= 0;
                in_range_ms <= 0;
                trace_energy <= 0;
                trace_class <= 3;
            end else begin
                case (state)
                    UNCALIBRATED: state <= IDLE;
                    IDLE, RESULT: begin
                        if (start_press && !parameter_mode) begin
                            state <= DEMO;
                            target_low <= low_threshold;
                            target_high <= high_threshold;
                            target_reference <= reference_level;
                            countdown_digit <= 0;
                            current_ms <= 0;
                            best_ms <= 0;
                            progress_ms <= 0;
                            in_target <= 0;
                            result_success <= 0;
                            ms_divider <= 0;
                            phase_ms <= 0;
                            audio_age <= 0;
                            audio_seen <= 0;
                            latest_energy <= 0;
                            elapsed_ms <= 0;
                            in_range_ms <= 0;
                            trace_energy <= 0;
                            trace_class <= 3;
                        end
                    end
                    DEMO: begin
                        if (ms_tick) begin
                            if (phase_ms + 1 >= DEMO_MS) begin
                                state <= COUNTDOWN;
                                phase_ms <= 0;
                                progress_ms <= 0;
                                countdown_digit <= (COUNTDOWN_MS + 999) / 1000;
                            end else begin
                                phase_ms <= phase_ms + 1'b1;
                                progress_ms <= phase_ms + 1'b1;
                            end
                        end
                    end
                    COUNTDOWN: begin
                        if (ms_tick) begin
                            if (phase_ms + 1 >= COUNTDOWN_MS) begin
                                state <= PRACTICE;
                                phase_ms <= 0;
                                countdown_digit <= 0;
                                // Samples from the demonstration/countdown
                                // (including this transition clock) do not count.
                                audio_seen <= 0;
                                audio_age <= 0;
                                in_target <= 0;
                            end else begin
                                phase_ms <= phase_ms + 1'b1;
                                countdown_digit <= (COUNTDOWN_MS - phase_ms - 1 > 2000) ? 2'd3 :
                                                   (COUNTDOWN_MS - phase_ms - 1 > 1000) ? 2'd2 : 2'd1;
                            end
                        end
                    end
                    PRACTICE: begin
                        if (audio_valid) begin
                            latest_energy <= energy;
                            audio_seen <= 1;
                            audio_age <= 0;
                            in_target <= new_in_target;
                        end else if (audio_seen) begin
                            if (audio_age < TIMEOUT_CYCLES) audio_age <= audio_age + 1'b1;
                            if (!sample_fresh) in_target <= 0;
                        end
                        // Out-of-range updates and expiry clear the continuous
                        // streak immediately, even between millisecond ticks.
                        if (!counting) begin
                            current_ms <= 0;
                            progress_ms <= 0;
                        end
                        if (ms_tick) begin
                            phase_ms <= phase_ms + 1'b1;
                            elapsed_ms <= phase_ms + 1'b1;
                            trace_tick <= 1;
                            trace_energy <= sampled_energy;
                            trace_class <= !sample_fresh ? 2'd3 :
                                           (sampled_energy < target_low) ? 2'd0 :
                                           (sampled_energy < target_high) ? 2'd1 : 2'd2;
                            if (counting) begin
                                current_ms <= current_ms + 1'b1;
                                progress_ms <= (current_ms + 1 >= GOAL_MS) ? GOAL_MS : current_ms + 1'b1;
                                in_range_ms <= in_range_ms + 1'b1;
                                if (current_ms + 1 > best_ms) best_ms <= current_ms + 1'b1;
                            end
                            // Success latches, but every round runs its full duration.
                            if (counting && current_ms + 1 >= GOAL_MS)
                                result_success <= 1;
                            if (phase_ms + 1 >= SESSION_MS) begin
                                state <= RESULT;
                            end
                        end
                    end
                    default: state <= UNCALIBRATED;
                endcase
            end
        end
    end
endmodule
