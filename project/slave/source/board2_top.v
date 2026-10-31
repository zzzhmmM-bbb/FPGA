// Board2 (AC201 + AC601, EG4S20BG256) speech recognition + link top.
// KEY2 = rst_n, KEY0 = key_ptt_n, KEY1 = key_disp_n (toggle cost / second cost).
// INMP441 on mic_sck / mic_ws / mic_sd; link to the main board on
// link_bclk / link_ws / link_sd / link_ptt (board link protocol v4);
// 8-digit 7-seg via two 74HC595; led[3:0] active low.
module board2_top (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       key_ptt_n,
    input  wire       key_disp_n,
    output wire       mic_sck,
    output wire       mic_ws,
    input  wire       mic_sd,
    output wire       link_bclk,
    output wire       link_ws,
    output wire       link_sd,
    input  wire       link_ptt,
    output wire       seg7_sclk,
    output wire       seg7_rclk,
    output wire       seg7_dio,
    output wire [3:0] led
);
    wire pll_locked, mic_mclk;

    // clk0_out is fed back to the PLL inside the IP (bufg_feedback -> fbclk).
    PLL_HDMI_AUDIO u_mic_pll (
        .refclk(clk), .reset(~rst_n), .extlock(pll_locked),
        .clk0_out(), .clk1_out(), .clk2_out(mic_mclk)
    );

    wire async_reset = ~rst_n | ~pll_locked;
    wire sys_reset, mic_reset;
    reset_sync u_sys_reset (.clk(clk),      .async_reset(async_reset), .reset(sys_reset));
    reset_sync u_mic_reset (.clk(mic_mclk), .async_reset(async_reset), .reset(mic_reset));

    wire               mic_valid;
    wire signed [15:0] mic_data;
    wire [23:0]        status_bundle;
    wire [23:0]        f0_bundle;
    wire [257:0]       spec_bundle;
    board2_audio_link #(.GAIN_SHIFT(0)) u_mic (
        .mclk(mic_mclk), .mclk_reset(mic_reset), .sd(mic_sd),
        .sck(mic_sck), .ws(mic_ws),
        .link_bclk(link_bclk), .link_ws(link_ws), .link_sd(link_sd),
        .clk(clk), .reset(sys_reset),
        .sample_valid(mic_valid), .sample_data(mic_data),
        .status_bundle(status_bundle),
        .f0_bundle(f0_bundle),
        .spec_bundle(spec_bundle)
    );

    wire [7:0] seg_data_0, seg_data_1, seg_data_2, seg_data_3;
    wire [7:0] seg_data_4, seg_data_5, seg_data_6, seg_data_7;
    board2_logic #(
        .CLK_HZ(50_000_000), .DEBOUNCE_MS(20), .MAX_SAMPLES(80000)
    ) u_logic (
        .clk(clk), .reset(sys_reset),
        .mic_valid(mic_valid), .mic_data(mic_data),
        .key_ptt_n(key_ptt_n), .key_disp_n(key_disp_n), .link_ptt(link_ptt),
        .seg_data_0(seg_data_0), .seg_data_1(seg_data_1), .seg_data_2(seg_data_2),
        .seg_data_3(seg_data_3), .seg_data_4(seg_data_4), .seg_data_5(seg_data_5),
        .seg_data_6(seg_data_6), .seg_data_7(seg_data_7),
        .led(led), .status_bundle(status_bundle), .f0_bundle(f0_bundle),
        .spec_bundle(spec_bundle)
    );

    hc595_seg8 #(.DIGIT_CYCLES(50000)) u_seg (
        .clk(clk), .reset(sys_reset),
        .seg_data_0(seg_data_0), .seg_data_1(seg_data_1), .seg_data_2(seg_data_2),
        .seg_data_3(seg_data_3), .seg_data_4(seg_data_4), .seg_data_5(seg_data_5),
        .seg_data_6(seg_data_6), .seg_data_7(seg_data_7),
        .seg7_sclk(seg7_sclk), .seg7_rclk(seg7_rclk), .seg7_dio(seg7_dio)
    );
endmodule
