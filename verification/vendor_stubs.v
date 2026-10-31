`timescale 1ns/1ps
// Port-only stubs for vendor IP / encrypted modules, used only for top-level lint.
module sys_pll(input refclk, input reset, output clk0_out, output clk1_out, output clk2_out, output locked);
endmodule
module video_pll(input refclk, input reset, output clk0_out, output clk1_out, output locked);
endmodule
module PLL_HDMI_AUDIO(input refclk, input reset, output extlock, output clk0_out, output clk1_out, output clk2_out);
endmodule
module sdram(
    input Clk, input Clk_sft, input Rst,
    output Sdr_init_done, output Sdr_init_ref_vld, output Sdr_busy,
    input App_wr_en, input [20:0] App_wr_addr, input [3:0] App_wr_dm, input [31:0] App_wr_din,
    input App_rd_en, input [20:0] App_rd_addr, output Sdr_rd_en, output [31:0] Sdr_rd_dout);
endmodule
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
