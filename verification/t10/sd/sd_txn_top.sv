// Transaction-level replacement for sd_card_top (same module name and ports).
// It replaces sd_card_top/sd_card_sec_read_write/sd_card_cmd/spi_master AND
// the card: sectors are served directly on the sd_sec_read interface with the
// same handshake as sd_card_sec_read_write (sd_sec_read sampled in the wait
// state, 512 registered data_valid pulses, one-cycle sd_sec_read_end, one
// cycle back to wait). Used only to count sector reads fast; bmp_read and
// sd_card_bmp are the real RTL.
module sd_card_top #(
    parameter SPI_LOW_SPEED_DIV = 248, parameter SPI_HIGH_SPEED_DIV = 0
)(
    input clk, input rst,
    output SD_nCS, output SD_DCLK, output SD_MOSI, input SD_MISO,
    output reg sd_init_done,
    input sd_sec_read, input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data, output reg sd_sec_read_data_valid,
    output sd_sec_read_end,
    input sd_sec_write, input [31:0] sd_sec_write_addr, input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req, output sd_sec_write_end
);
    parameter integer INIT_CYC = 2000, LAT = 40, GAP = 1, TAIL = 70;
    assign SD_nCS = 1'b1; assign SD_DCLK = 1'b1; assign SD_MOSI = 1'b1;
    assign sd_sec_write_data_req = 1'b0; assign sd_sec_write_end = 1'b0;
    sd_image_store store();
    integer st, cnt, idx, gapc;
    integer rd_count;
    reg [31:0] last_addr;
    initial rd_count = 0;
    assign sd_sec_read_end = (st == 5);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st <= 0; cnt <= 0; idx <= 0; gapc <= 0; sd_init_done <= 0;
            sd_sec_read_data <= 0; sd_sec_read_data_valid <= 0;
        end else begin
            sd_sec_read_data_valid <= 0;
            case (st)
                0: begin cnt <= cnt + 1; if (cnt >= INIT_CYC) begin sd_init_done <= 1; st <= 1; end end
                1: if (sd_sec_read) begin
                       last_addr = sd_sec_read_addr; store.fetch(sd_sec_read_addr);
                       rd_count = rd_count + 1; cnt <= 0; st <= 2;
                   end
                2: begin cnt <= cnt + 1; if (cnt >= LAT) begin idx <= 0; gapc <= 0; st <= 3; end end
                3: begin
                       if (gapc == 0) begin
                           sd_sec_read_data_valid <= 1; sd_sec_read_data <= store.sbuf[idx];
                           idx <= idx + 1; gapc <= GAP;
                           if (idx == 511) begin cnt <= 0; st <= 4; end
                       end else gapc <= gapc - 1;
                   end
                4: begin cnt <= cnt + 1; if (cnt >= TAIL) st <= 5; end
                5: st <= 1;
            endcase
        end
    end
endmodule
