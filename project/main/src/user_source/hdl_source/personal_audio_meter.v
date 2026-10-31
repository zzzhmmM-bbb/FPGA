module personal_audio_meter (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              pcm_valid,
    input  wire signed [15:0] pcm_sample,
    input  wire              short_press,
    input  wire              long_press,
    input  wire              threshold_down,
    input  wire              threshold_up,
    output reg  [1:0]        level,
    output reg  [3:0]        status,
    output reg  [15:0]       noise_floor,
    output reg  [15:0]       voice_reference,
    output reg  [15:0]       loud_threshold,
    output wire [15:0]       current_energy,
    output wire [15:0]       quiet_threshold,
    output reg              energy_valid
);

    // pcm_sample is raw signed PCM[23:8], before display gain or clipping.
    // status: 0 idle, 1 noise capture, 2 voice prompt, 3 voice capture/divide,
    //         4 ready, 5 clipped input during noise capture, 6 weak voice, 7 near-full-scale voice.
    reg [9:0] sample_count;
    reg [25:0] sample_sum;
    reg [10:0] clipped_samples;
    reg [7:0] window_index;
    reg [21:0] noise_sum;
    reg [23:0] voice_sum;
    reg [7:0] voice_count;
    reg [15:0] voice_min;
    reg [15:0] voice_max;
    reg [7:0] clipped_windows;
    reg [15:0] quiet_enter;
    reg [15:0] quiet_exit;
    reg [15:0] filtered;
    assign current_energy = filtered;
    assign quiet_threshold = quiet_enter;
    reg divide_active;
    reg [4:0] divide_step;
    reg [23:0] divide_quotient;
    reg [8:0] divide_remainder;
    reg [7:0] divide_denominator;

    wire busy = (status == 4'd1) || (status == 4'd3);
    wire start_noise = !busy && (long_press ||
                       (short_press && (status == 4'd0 || status == 4'd5)));
    wire start_voice = !busy && short_press &&
                       (status == 4'd2 || status == 4'd6 || status == 4'd7);
    // A 26-bit accumulator holds 1024 * 32768, including negative full scale.
    wire [15:0] magnitude = pcm_sample[15]
                           ? (~pcm_sample + 16'd1) : pcm_sample;
    wire [25:0] window_sum = sample_sum + {10'd0, magnitude};
    wire [15:0] window_mean = window_sum[23:8];
    wire [10:0] clipped_samples_next = clipped_samples +
                                      ((magnitude >= 16'd32767) ? 11'd1 : 11'd0);
    wire [21:0] noise_sum_next = noise_sum + {6'd0, window_mean};
    wire [15:0] noise_mean = noise_sum_next[21:6];
    wire [17:0] noise_triple = {2'd0, noise_mean} + {1'd0, noise_mean, 1'b0};
    wire [16:0] noise_double = {noise_mean, 1'b0};
    wire usable_voice = window_mean >= quiet_enter;
    // 128 windows * 32768 = 4194304; 24 bits leave ample sum headroom.
    wire [23:0] voice_sum_next = voice_sum +
                                (usable_voice ? {8'd0, window_mean} : 24'd0);
    wire [7:0] voice_count_next = voice_count + (usable_voice ? 8'd1 : 8'd0);
    wire [15:0] voice_min_next = usable_voice && window_mean < voice_min
                                ? window_mean : voice_min;
    wire [15:0] voice_max_next = usable_voice && window_mean > voice_max
                                ? window_mean : voice_max;
    wire [7:0] clipped_windows_next = clipped_windows +
                        ((clipped_samples_next >= 11'd32) ? 8'd1 : 8'd0);

    // Restoring unsigned division consumes one dividend bit per clock. The
    // quotient register starts as the 24-bit trimmed sum, then becomes its
    // quotient after exactly 24 clocks, avoiding a combinational '/' circuit.
    wire [8:0] divide_trial = {divide_remainder[7:0], divide_quotient[23]};
    wire divide_subtract = divide_trial >= {1'b0, divide_denominator};
    wire [8:0] remainder_next = divide_subtract
                     ? divide_trial - {1'b0, divide_denominator} : divide_trial;
    wire [23:0] quotient_next = {divide_quotient[22:0], divide_subtract};
    wire [15:0] reference_candidate = quotient_next[15:0];
    wire [16:0] reference_margin = (reference_candidate[15:1] > 15'd64)
                         ? {2'd0, reference_candidate[15:1]} : 17'd64;
    wire [16:0] candidate_loud = {1'b0, reference_candidate} + reference_margin;
    wire [16:0] quiet_loud_min = {1'b0, quiet_enter} + 17'd64;
    wire [16:0] initial_loud = candidate_loud > quiet_loud_min
                              ? candidate_loud : quiet_loud_min;
    wire [16:0] reference_min = {1'b0, quiet_enter} + 17'd32;
    wire [16:0] threshold_min = {1'b0, voice_reference} + 17'd32;
    wire [16:0] threshold_min_plus_step = threshold_min + 17'd32;
    // Widen before adding; both thresholds and the reference are unsigned.
    wire [16:0] loud_exit_sum = {1'b0, voice_reference} + {1'b0, loud_threshold};
    wire [15:0] loud_exit = loud_exit_sum[16:1];
    wire [17:0] filter_sum = {2'd0, filtered} + {1'b0, filtered, 1'b0}
                           + {2'd0, window_mean};
    wire [15:0] filtered_next = filter_sum[17:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            energy_valid <= 1'b0;
            level <= 2'd0;
            status <= 4'd0;
            noise_floor <= 16'd0;
            voice_reference <= 16'd0;
            loud_threshold <= 16'd0;
            sample_count <= 10'd0;
            sample_sum <= 26'd0;
            clipped_samples <= 11'd0;
            window_index <= 8'd0;
            noise_sum <= 22'd0;
            voice_sum <= 24'd0;
            voice_count <= 8'd0;
            voice_min <= 16'hffff;
            voice_max <= 16'd0;
            clipped_windows <= 8'd0;
            quiet_enter <= 16'd48;
            quiet_exit <= 16'd32;
            filtered <= 16'd0;
            divide_active <= 1'b0;
            divide_step <= 5'd0;
            divide_quotient <= 24'd0;
            divide_remainder <= 9'd0;
            divide_denominator <= 8'd0;
        end else if (start_noise) begin
            energy_valid <= 1'b0;
            status <= 4'd1;
            level <= 2'd0;
            noise_floor <= 16'd0;
            voice_reference <= 16'd0;
            loud_threshold <= 16'd0;
            sample_count <= 10'd0;
            sample_sum <= 26'd0;
            clipped_samples <= 11'd0;
            window_index <= 8'd0;
            noise_sum <= 22'd0;
            voice_sum <= 24'd0;
            voice_count <= 8'd0;
            voice_min <= 16'hffff;
            voice_max <= 16'd0;
            clipped_windows <= 8'd0;
            filtered <= 16'd0;
            divide_active <= 1'b0;
        end else if (start_voice) begin
            energy_valid <= 1'b0;
            status <= 4'd3;
            level <= 2'd0;
            sample_count <= 10'd0;
            sample_sum <= 26'd0;
            clipped_samples <= 11'd0;
            window_index <= 8'd0;
            voice_sum <= 24'd0;
            voice_count <= 8'd0;
            voice_min <= 16'hffff;
            voice_max <= 16'd0;
            clipped_windows <= 8'd0;
            filtered <= 16'd0;
            divide_active <= 1'b0;
        end else begin
            energy_valid <= 1'b0;
            if (status == 4'd4 && threshold_up != threshold_down) begin
                if (threshold_up)
                    loud_threshold <= loud_threshold >= 16'd29968
                                    ? 16'd30000 : loud_threshold + 16'd32;
                else
                    loud_threshold <= {1'b0, loud_threshold} <= threshold_min_plus_step
                                    ? threshold_min[15:0] : loud_threshold - 16'd32;
            end
            if (divide_active) begin
                divide_remainder <= remainder_next;
                divide_quotient <= quotient_next;
                if (divide_step == 5'd23) begin
                    divide_active <= 1'b0;
                    sample_count <= 10'd0;
                    sample_sum <= 26'd0;
                    clipped_samples <= 11'd0;
                    filtered <= 16'd0;
                    if ({1'b0, reference_candidate} < reference_min)
                        status <= 4'd6;
                    else if (reference_candidate > 16'd29968)
                        status <= 4'd7;
                    else begin
                        voice_reference <= reference_candidate;
                        loud_threshold <= initial_loud > 17'd30000
                                        ? 16'd30000 : initial_loud[15:0];
                        status <= 4'd4;
                    end
                end else
                    divide_step <= divide_step + 5'd1;
            end else if (pcm_valid && (status == 4'd1 || status == 4'd3 || status == 4'd4)) begin
                if (sample_count == 10'd255) begin
                    sample_count <= 10'd0;
                    sample_sum <= 26'd0;
                    clipped_samples <= 11'd0;
                    if (status == 4'd1) begin
                        if (window_index == 8'd95) begin
                            window_index <= 8'd0;
                            noise_sum <= 22'd0;
                            noise_floor <= noise_mean;
                            quiet_enter <= noise_triple > 18'd65535 ? 16'hffff
                                         : noise_triple > 18'd48
                                         ? noise_triple[15:0] : 16'd48;
                            quiet_exit <= noise_double > 17'd65535 ? 16'hffff
                                        : noise_double > 17'd32
                                        ? noise_double[15:0] : 16'd32;
                            clipped_windows <= clipped_windows_next;
                            status <= clipped_windows_next >= 8'd8 ? 4'd5 : 4'd2;
                        end else begin
                            window_index <= window_index + 8'd1;
                            if (window_index >= 8'd32) begin
                                noise_sum <= noise_sum_next;
                                clipped_windows <= clipped_windows_next;
                            end
                        end
                    end else if (status == 4'd3) begin
                        if (window_index >= 8'd16) begin
                            voice_sum <= voice_sum_next;
                            voice_count <= voice_count_next;
                            voice_min <= voice_min_next;
                            voice_max <= voice_max_next;
                            clipped_windows <= clipped_windows_next;
                        end
                        if (window_index == 8'd143) begin
                            window_index <= 8'd0;
                            if (clipped_windows_next >= 8'd8)
                                status <= 4'd7;
                            else if (voice_count_next < 8'd64)
                                status <= 4'd6;
                            else begin
                                divide_quotient <= voice_sum_next - {8'd0, voice_min_next}
                                                   - {8'd0, voice_max_next};
                                divide_denominator <= voice_count_next - 8'd2;
                                divide_remainder <= 9'd0;
                                divide_step <= 5'd0;
                                divide_active <= 1'b1;
                            end
                        end else
                            window_index <= window_index + 8'd1;
                    end else begin
                        filtered <= filtered_next;
                        energy_valid <= 1'b1;
                        case (level)
                            2'd0: begin
                                if (filtered_next >= loud_threshold)
                                    level <= 2'd2;
                                else if (filtered_next >= quiet_enter)
                                    level <= 2'd1;
                            end
                            2'd1: begin
                                if (filtered_next >= loud_threshold)
                                    level <= 2'd2;
                                else if (filtered_next <= quiet_exit)
                                    level <= 2'd0;
                            end
                            2'd2: begin
                                if (filtered_next <= quiet_exit)
                                    level <= 2'd0;
                                else if (filtered_next <= loud_exit)
                                    level <= 2'd1;
                            end
                            default: level <= 2'd0;
                        endcase
                    end
                end else begin
                    sample_count <= sample_count + 10'd1;
                    sample_sum <= window_sum;
                    clipped_samples <= clipped_samples_next;
                end
            end
        end
    end
endmodule
