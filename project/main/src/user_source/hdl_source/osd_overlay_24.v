`timescale 1ns/1ps

// Reconstruct active-area coordinates from the 640x480 video timing.
// Rendering uses half-resolution coordinates for fixed 2x glyph scaling.
module osd_overlay_24 #(
    parameter integer OSD_X = 8,
    parameter integer OSD_Y = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vsync,
    input  wire        de,
    input  wire [23:0] rgb_in,
    input  wire [1:0]  active_index,
    input  wire        auto_enabled,
    input  wire        display_valid,
    output wire [23:0] rgb_out
);
    reg [11:0] pixel_x;
    reg [11:0] line_y;
    reg de_q;
    reg vs_q;
    wire frame_start = vs_q && !vsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x <= 12'd0;
            line_y <= 12'd0;
            de_q <= 1'b0;
            vs_q <= 1'b1;
        end else begin
            de_q <= de;
            vs_q <= vsync;
            // Blanking leaves x at zero for the first active pixel.
            if (!vsync || !de)
                pixel_x <= 12'd0;
            else
                pixel_x <= pixel_x + 1'b1;

            // Active-low vsync resets y before the first active line.
            if (!vsync)
                line_y <= 12'd0;
            else if (de_q && !de)
                line_y <= line_y + 1'b1;
        end
    end

    wire [11:0] osd_rgb12;
    wire osd_hit;

    status_osd_overlay #(
        .OSD_X(OSD_X),
        .OSD_Y(OSD_Y)
    ) u_osd (
        .clk(clk), .rst_n(rst_n),
        .frame_start(frame_start),
        .active_index(active_index), .auto_enabled(auto_enabled),
        .display_valid(display_valid),
        .in_de(de),
        .in_rgb({rgb_in[23:20], rgb_in[15:12], rgb_in[7:4]}),
        .pixel_x({1'b0, pixel_x[11:1]}),
        .pixel_y({1'b0, line_y[11:1]}),
        .out_rgb(osd_rgb12),
        .out_de(),
        .osd_pixel(osd_hit)
    );

    // Preserve every source colour bit outside the yellow glyph pixels.
    // This mux adds no registered video delay.
    assign rgb_out = osd_hit ?
        {osd_rgb12[11:8], osd_rgb12[11:8],
         osd_rgb12[7:4],  osd_rgb12[7:4],
         osd_rgb12[3:0],  osd_rgb12[3:0]} : rgb_in;
endmodule
