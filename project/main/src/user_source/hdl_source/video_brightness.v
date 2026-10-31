// Combinational RGB scaling; latch the requested scale only at frame boundary.
module video_brightness (
    input wire clk, rst_n, vsync,
    input wire [23:0] rgb_in,
    input wire [3:0] brightness,
    output wire [23:0] rgb_out
);
    reg vsync_d;
    reg [3:0] frame_brightness;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d <= 0;
            frame_brightness <= 8;
        end else begin
            vsync_d <= vsync;
            if (vsync_d && !vsync) frame_brightness <= brightness;
        end
    end
    function [7:0] scale_channel;
        input [7:0] channel;
        input [3:0] scale;
        reg [11:0] product;
        begin
            product = channel * scale;
            scale_channel = (product > 12'd2040) ? 8'd255 : product[10:3];
        end
    endfunction
    assign rgb_out = {scale_channel(rgb_in[23:16], frame_brightness),
                      scale_channel(rgb_in[15:8], frame_brightness),
                      scale_channel(rgb_in[7:0], frame_brightness)};
endmodule
