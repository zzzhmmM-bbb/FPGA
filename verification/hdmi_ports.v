module hdmi_1_4b_transmitter_core_wrapper #(
    parameter DEVICE = "EG", parameter HTOTAL = 2200, parameter HSA = 44, parameter HFP = 88,
    parameter HBP = 148, parameter HACTIVE = 1920, parameter VTOTAL = 1125, parameter VSA = 5,
    parameter VFP = 4, parameter VBP = 36, parameter VACTIVE = 1080, parameter VIDEO_TPG = "Enable",
    parameter VIDEO_FORMAT = "RGB", parameter VIDEO_VIC = 16, parameter AUDIO_SAMPLE_RATE = "48K",
    parameter IIC_SCL_DIV = 125
)(
    input wire I_pixel_clk, input wire I_rst,
    input wire I_edid_read_trig, output wire O_edid_read_valid, output wire [7:0] O_edid_read_data,
    input wire I_axis_s_user, input wire I_axis_s_valid, input wire I_axis_s_last,
    input wire [23:0] I_axis_s_data, output wire O_axis_s_ready,
    input wire I_audio_valid, input wire [23:0] I_audio_left_data, input wire [23:0] I_audio_right_data,
    input wire I_acr_valid, input wire [19:0] I_acr_cts, input wire [19:0] I_acr_n,
    output wire O_video_locked, output wire O_ddc_scl, inout wire IO_ddc_sda,
    output wire [9:0] O_ch0_tmds_data, output wire [9:0] O_ch1_tmds_data,
    output wire [9:0] O_ch2_tmds_data, output wire [9:0] O_clk_tmds_data);
endmodule
// Anlogic EG4 primitive (vendor sim library not available here).
module EG_LOGIC_ODDR(input clk, input rst, input d1, input d0, output q);
endmodule
