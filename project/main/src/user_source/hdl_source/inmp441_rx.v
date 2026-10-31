// INMP441 left-channel receiver, clocked entirely by the 25 MHz video clock.
// SCK = clk / 8 = 3.125 MHz; WS = SCK / 64 = 48,828.125 Hz.
module inmp441_rx (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sd,
    output reg                sck,
    output reg                ws,
    output reg                sample_valid,
    output reg signed [23:0]  sample_data
);

    reg [1:0] half_count;
    reg [5:0] frame_bit;
    reg       sd_meta;
    reg       sd_sync;
    reg [23:0] shift_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half_count   <= 2'd0;
            frame_bit    <= 6'd63;
            sck          <= 1'b0;
            ws           <= 1'b1;
            sd_meta      <= 1'b0;
            sd_sync      <= 1'b0;
            shift_data   <= 24'd0;
            sample_valid <= 1'b0;
            sample_data  <= 24'sd0;
        end else begin
            sd_meta      <= sd;
            sd_sync      <= sd_meta;
            sample_valid <= 1'b0;

            if (half_count == 2'd3) begin
                half_count <= 2'd0;
                sck <= ~sck;
                if (sck) begin
                    // Falling SCK: index the bit seen at the next rising edge.
                    // Bit 0 changes WS low and is the I2S one-bit delay;
                    // bits 1..24 carry left MSB..LSB; bit 32 changes WS high.
                    frame_bit <= frame_bit + 6'd1;
                    if (frame_bit == 6'd63)
                        ws <= 1'b0;
                    else if (frame_bit == 6'd31)
                        ws <= 1'b1;
                end
            end else begin
                half_count <= half_count + 2'd1;
            end

            if ((half_count == 2'd1) && sck &&
                (frame_bit >= 6'd1) && (frame_bit <= 6'd24)) begin
                // Consume SD two clk cycles after rising SCK. The old
                // sd_sync now holds the input sampled at that rising edge,
                // giving the microphone the full four-clk half-period.
                // Starting at bit 63 ignores the initial partial slot and
                // requires a WS high-to-low edge before the first sample.
                // First valid is at clk 206 after reset; then every 512 clk.
                shift_data <= {shift_data[22:0], sd_sync};
                if (frame_bit == 6'd24) begin
                    sample_data  <= {shift_data[22:0], sd_sync};
                    sample_valid <= 1'b1;
                end
            end
        end
    end

endmodule
