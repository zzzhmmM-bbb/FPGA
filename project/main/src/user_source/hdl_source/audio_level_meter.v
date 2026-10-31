module audio_level_meter (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               pcm_valid,
    input  wire signed [15:0]  pcm_sample,
    input  wire               calibrate_start,
    output reg  [1:0]          level,
    output reg  [1:0]          calibration_status
);

    reg [9:0]  sample_count;
    reg [25:0] sample_sum;
    reg [15:0] filtered;
    reg [6:0]  calibration_window;
    reg [21:0] noise_sum;
    reg [15:0] quiet_enter;
    reg [15:0] quiet_exit;
    reg [15:0] loud_enter;
    reg [15:0] loud_exit;

    // Unsigned magnitude preserves the value 32768 for PCM -32768.
    wire [15:0] magnitude = pcm_sample[15]
                          ? (~pcm_sample + 16'd1) : pcm_sample;
    wire [25:0] window_sum = sample_sum + {10'd0, magnitude};
    wire [15:0] window_mean = window_sum[25:10];
    wire [17:0] filter_sum = {2'b00, filtered}
                           + {1'b0, filtered, 1'b0}
                           + {2'b00, window_mean};
    wire [15:0] filtered_next = filter_sum[17:2];
    wire [21:0] noise_sum_next = noise_sum + {6'd0, window_mean};
    wire [15:0] noise_mean = noise_sum_next[21:6];
    wire [15:0] noise_twice = noise_mean << 1;
    wire [15:0] noise_three_times = noise_twice + noise_mean;
    wire [15:0] noise_four_times = noise_mean << 2;
    wire [15:0] noise_six_times = noise_three_times << 1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count <= 10'd0;
            sample_sum   <= 26'd0;
            filtered     <= 16'd0;
            level        <= 2'd0;
            calibration_status <= 2'd0;
            calibration_window <= 7'd0;
            noise_sum    <= 22'd0;
            quiet_enter  <= 16'd768;
            quiet_exit   <= 16'd512;
            loud_enter   <= 16'd6144;
            loud_exit    <= 16'd4096;
        end else if (calibrate_start && calibration_status != 2'd1) begin
            sample_count <= 10'd0;
            sample_sum   <= 26'd0;
            filtered     <= 16'd0;
            level        <= 2'd0;
            calibration_status <= 2'd1;
            calibration_window <= 7'd0;
            noise_sum    <= 22'd0;
        end else if (pcm_valid) begin
            if (sample_count == 10'd1023) begin
                sample_count <= 10'd0;
                sample_sum   <= 26'd0;
                if (calibration_status == 2'd1) begin
                    filtered <= 16'd0;
                    level    <= 2'd0;
                    // Discard 32 windows so the key can be released, then
                    // average 64 complete windows, including this last one.
                    if (calibration_window == 7'd95) begin
                        calibration_window <= 7'd0;
                        noise_sum <= 22'd0;
                        if (noise_mean <= 16'd4096) begin
                            calibration_status <= 2'd2;
                            quiet_enter <= (noise_three_times > 16'd768)
                                         ? noise_three_times : 16'd768;
                            quiet_exit <= (noise_twice > 16'd512)
                                        ? noise_twice : 16'd512;
                            loud_enter <= (noise_six_times > 16'd6144)
                                        ? noise_six_times : 16'd6144;
                            loud_exit <= (noise_four_times > 16'd4096)
                                       ? noise_four_times : 16'd4096;
                        end else begin
                            // Failed calibration keeps the previous thresholds.
                            calibration_status <= 2'd3;
                        end
                    end else begin
                        calibration_window <= calibration_window + 7'd1;
                        if (calibration_window >= 7'd32)
                            noise_sum <= noise_sum_next;
                    end
                end else begin
                    filtered <= filtered_next;

                // Hysteresis limits switching near each level boundary.
                case (level)
                    2'd0: begin
                        if (filtered_next >= loud_enter)
                            level <= 2'd2;
                        else if (filtered_next >= quiet_enter)
                            level <= 2'd1;
                    end
                    2'd1: begin
                        if (filtered_next >= loud_enter)
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
                sample_sum   <= window_sum;
            end
        end
    end

endmodule
