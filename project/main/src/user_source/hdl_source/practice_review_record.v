// One volatile previous score and 100 snapshots for the current eight-second round.
module practice_review_record (
    input wire clk, rst_n, calibration_ready,
    input wire [2:0] state,
    input wire [15:0] reference_level, low_threshold, high_threshold,
    input wire [12:0] best_ms, in_range_ms, elapsed_ms,
    input wire trace_tick,
    input wire [15:0] trace_energy,
    input wire [1:0] trace_class,
    input wire [6:0] read_index,
    output wire [6:0] read_height,
    output wire [1:0] read_class,
    output reg [6:0] point_count,
    output reg result_valid, previous_valid,
    output reg [12:0] previous_best_ms,
    output reg [6:0] current_percent, previous_percent,
    output reg [1:0] feedback_code
);
    localparam [2:0] IDLE = 1, DEMO = 2, PRACTICE = 4, RESULT = 5;
    (* ram_style = "bram" *) reg [8:0] points [0:127];
    reg [8:0] rd_q; reg rd_ok;
    assign read_height = rd_ok ? rd_q[6:0] : 7'd0;
    assign read_class = rd_ok ? rd_q[8:7] : 2'd3;
    reg [2:0] previous_state;
    reg [15:0] config_reference, config_low, config_high, round_reference;
    reg round_active, last_valid;
    reg [12:0] last_best_ms, completed_best_ms;
    reg [12:0] low_ms, high_ms;
    reg [6:0] last_percent;
    reg [6:0] snapshot_ticks;
    reg height_busy;
    reg [4:0] height_bits;
    reg [21:0] height_dividend, height_quotient;
    reg [16:0] height_remainder;
    reg [1:0] pending_class;
    reg percent_busy, completion_pending;
    reg [12:0] percent_remainder;
    reg [6:0] percent_quotient;
    wire config_changed = reference_level != config_reference ||
                          low_threshold != config_low || high_threshold != config_high;
    wire round_start = state == DEMO && previous_state != DEMO;
    wire [21:0] scaled_energy = {6'd0, trace_energy} * 6'd60;
    wire [16:0] remainder_shift = {height_remainder[15:0], height_dividend[21]};
    wire quotient_bit = remainder_shift >= {1'b0, round_reference};
    wire [16:0] remainder_next = quotient_bit ?
                         remainder_shift - {1'b0, round_reference} : remainder_shift;
    wire [21:0] quotient_next = {height_quotient[20:0], quotient_bit};

    // No reset on the memory: point_count hides old entries and permits RAM inference.
    always @(posedge clk) begin
        if (rst_n && height_busy && height_bits == 1 && calibration_ready &&
            !config_changed && !round_start && state != IDLE)
            points[point_count] <= {pending_class,
                                  (round_reference == 0) ? 7'd0 :
                                  (quotient_next > 120) ? 7'd120 : quotient_next[6:0]};
        rd_q <= points[read_index];
        rd_ok <= read_index < point_count && read_index < 100;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            previous_state <= 0;
            config_reference <= 0;
            config_low <= 0;
            config_high <= 0;
            round_reference <= 0;
            point_count <= 0;
            result_valid <= 0;
            low_ms <= 0;
            high_ms <= 0;
            feedback_code <= 0;
            previous_valid <= 0;
            previous_best_ms <= 0;
            current_percent <= 0;
            previous_percent <= 0;
            round_active <= 0;
            last_valid <= 0;
            last_best_ms <= 0;
            completed_best_ms <= 0;
            last_percent <= 0;
            snapshot_ticks <= 0;
            height_busy <= 0;
            height_bits <= 0;
            height_dividend <= 0;
            height_quotient <= 0;
            height_remainder <= 0;
            pending_class <= 3;
            percent_busy <= 0;
            completion_pending <= 0;
            percent_remainder <= 0;
            percent_quotient <= 0;
        end else begin
            previous_state <= state;
            config_reference <= reference_level;
            config_low <= low_threshold;
            config_high <= high_threshold;
            if (!calibration_ready || config_changed) begin
                last_valid <= 0;
                previous_valid <= 0;
                result_valid <= 0;
                low_ms <= 0;
                high_ms <= 0;
                feedback_code <= 0;
                point_count <= 0;
                current_percent <= 0;
                previous_best_ms <= 0;
                previous_percent <= 0;
                round_active <= calibration_ready && round_start;
                round_reference <= reference_level;
                snapshot_ticks <= 0;
                height_busy <= 0;
                percent_busy <= 0;
                completion_pending <= 0;
            end else if (round_start) begin
                previous_valid <= last_valid;
                previous_best_ms <= last_valid ? last_best_ms : 13'd0;
                previous_percent <= last_valid ? last_percent : 7'd0;
                round_reference <= reference_level;
                round_active <= 1;
                result_valid <= 0;
                low_ms <= 0;
                high_ms <= 0;
                feedback_code <= 0;
                point_count <= 0;
                current_percent <= 0;
                snapshot_ticks <= 0;
                height_busy <= 0;
                percent_busy <= 0;
                completion_pending <= 0;
            end else if (state == IDLE && previous_state != IDLE) begin
                // Cancellation discards only the unfinished current trace.
                round_active <= 0;
                result_valid <= 0;
                low_ms <= 0;
                high_ms <= 0;
                feedback_code <= 0;
                point_count <= 0;
                current_percent <= 0;
                snapshot_ticks <= 0;
                height_busy <= 0;
                percent_busy <= 0;
                completion_pending <= 0;
            end else begin
                if (round_active && trace_tick &&
                    (state == PRACTICE || (state == RESULT && elapsed_ms == 8000))) begin
                    if (trace_class == 0) low_ms <= low_ms + 1'b1;
                    if (trace_class == 2) high_ms <= high_ms + 1'b1;
                    if (snapshot_ticks == 79) begin
                        snapshot_ticks <= 0;
                        if (point_count < 100) begin
                            height_busy <= 1;
                            height_bits <= 22;
                            height_dividend <= (trace_class == 3 || round_reference == 0) ?
                                               22'd0 : scaled_energy;
                            height_quotient <= 0;
                            height_remainder <= 0;
                            pending_class <= trace_class;
                        end
                    end else snapshot_ticks <= snapshot_ticks + 1'b1;
                end
                if (height_busy) begin
                    height_dividend <= {height_dividend[20:0], 1'b0};
                    height_quotient <= (round_reference == 0) ? 22'd0 : quotient_next;
                    height_remainder <= remainder_next;
                    height_bits <= height_bits - 1'b1;
                    if (height_bits == 1) begin
                        height_busy <= 0;
                        point_count <= point_count + 1'b1;
                    end
                end
                // Controller outputs already include the last millisecond here.
                if (round_active && state == RESULT && previous_state == PRACTICE && elapsed_ms == 8000) begin
                    completed_best_ms <= best_ms;
                    percent_remainder <= in_range_ms;
                    percent_quotient <= 0;
                    percent_busy <= 1;
                    completion_pending <= 1;
                    round_active <= 0;
                end
                if (percent_busy) begin
                    if (percent_remainder >= 80) begin
                        percent_remainder <= percent_remainder - 13'd80;
                        percent_quotient <= percent_quotient + 1'b1;
                    end else begin
                        current_percent <= percent_quotient;
                        percent_busy <= 0;
                    end
                end
                if (completion_pending && !height_busy && !percent_busy && point_count == 100) begin
                    result_valid <= 1;
                    if (completed_best_ms >= 5000) feedback_code <= 1;
                    else if (low_ms > 4000) feedback_code <= 2;
                    else if (high_ms > 4000) feedback_code <= 3;
                    else feedback_code <= 0;
                    last_valid <= 1;
                    last_best_ms <= completed_best_ms;
                    last_percent <= current_percent;
                    completion_pending <= 0;
                end
            end
        end
    end
endmodule
