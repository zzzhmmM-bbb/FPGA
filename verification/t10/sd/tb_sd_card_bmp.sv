`timescale 1ns/1ps
// System-level TB for sd_card_bmp (scan + preload) against a sparse TF image.
// Build with either sd_txn_top.sv (transaction-level SD stack) or the real
// sd_card_top/sd_card_cmd/sd_card_sec_read_write/spi_master + SPI=1 define
// (sd_spi_card.sv model on the SPI pins).
// Plusargs: +IMG=<dir>  +STOP=first|all  +TAG=<text>  +ADDRLOG=<file>  +MAXREADS=<n>  +FAULT_AT=<n>
module tb_sd_card_bmp;
    reg clk = 0; always #5 clk = ~clk;            // 100 MHz sd_card_clk
    reg rst = 1;
    wire [3:0] state_code;
    wire display_valid, preload_done;
    wire [5:0] slot_valid, slot_failed;
    wire [2:0] slots_found, load_slot;
    reg write_req_ack = 0, write_abort_ack = 0, write_finish_toggle = 0;
    wire write_req, write_abort_req, write_en;
    wire [31:0] write_data;
    wire SD_nCS, SD_DCLK, SD_MOSI, SD_MISO;
    sd_card_bmp #(.CLK_FREQ_HZ(100_000_000), .SCAN_START_SECTOR(32'd0),
                  .SCAN_MAX_SECTOR(32'd131071), .SCAN_TARGET_COUNT(3'd6)) dut(
        .clk(clk), .rst(rst), .state_code(state_code),
        .bmp_width(16'd640), .bmp_height(16'd480),
        .display_valid(display_valid), .slot_valid(slot_valid), .slot_failed(slot_failed),
        .slots_found(slots_found), .preload_done(preload_done), .load_slot(load_slot),
        .memory_ready(1'b1), .write_finish_toggle(write_finish_toggle),
        .write_req(write_req), .write_req_ack(write_req_ack),
        .write_abort_req(write_abort_req), .write_abort_ack(write_abort_ack), .write_overflow(1'b0),
        .write_en(write_en), .write_data(write_data),
        .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK), .SD_MOSI(SD_MOSI), .SD_MISO(SD_MISO));
`ifdef SPI
    sd_spi_card card(.sclk(SD_DCLK), .cs_n(SD_nCS), .mosi(SD_MOSI), .miso(SD_MISO));
`else
    assign SD_MISO = 1'b1;
`endif
    // Simple SDRAM-side model: ack follows req, finish after 307200 pixels.
    integer px = 0, fin_dly = 0;
    reg [31:0] csum [0:5];
    reg [31:0] cur_sum = 0;
    integer k;
    initial for (k = 0; k < 6; k = k + 1) csum[k] = 0;
    always @(posedge clk) begin
        write_req_ack <= write_req;
        write_abort_ack <= write_abort_req;
        if (write_req && !write_req_ack) begin px = 0; cur_sum = 0; end
        if (write_en) begin
            px = px + 1; cur_sum = cur_sum + write_data;
            if (px == 307200) begin csum[load_slot] = cur_sum; fin_dly = 10; end
        end
        if (fin_dly > 0) begin
            fin_dly = fin_dly - 1;
            if (fin_dly == 0) write_finish_toggle <= ~write_finish_toggle;
        end
    end
    // Read accounting at the sd_sec_read interface (completed sectors).
    integer reads = 0, reads_scan = -1, reads_first = -1, starts = 0;
    integer found_n = 0, fd = 0, maxreads = 0, fault_at = 0, fault_cnt = 0;
    reg [31:0] found_sec [0:15];
    real t_scan = 0, t_first = 0, t_all = 0;
    reg prev_rd = 0, prev_dv = 0;
    string img, stop, tag, alog;
    always @(posedge clk) begin
        prev_rd <= dut.sd_sec_read;
        if (dut.sd_sec_read && !prev_rd) begin
            starts = starts + 1;
            if (fd) $fdisplay(fd, "%0d p%0d m%0d", dut.sd_sec_read_addr, dut.phase, dut.bmp_read_m0.state);
        end
        if (dut.sd_sec_read_end) begin
            reads = reads + 1;
            if (fault_at > 0 && reads == fault_at) begin
                // Fault injection: drop sd_init_done (exercises P_SCAN recovery).
                $display("[%s] FAULT: forcing sd_init_done=0 after read %0d", tag, reads);
                force dut.sd_init_done = 1'b0; fault_cnt = 200;
            end
            if (maxreads > 0 && reads >= maxreads) begin
                $display("[%s] MAXREADS reached", tag); report(); if (fd) $fclose(fd); $finish;
            end
        end
        if (dut.bmp_read_m0.scan_found_valid) begin
            if (found_n < 16) found_sec[found_n] = dut.bmp_read_m0.scan_found_sector;
            found_n = found_n + 1;
            $display("[%s] scan_found_valid #%0d sector=%0d (reads so far %0d)", tag, found_n,
                     dut.bmp_read_m0.scan_found_sector, reads);
        end
        if (dut.load_start_pulse && reads_scan < 0) begin reads_scan = reads; t_scan = $realtime; end
        if (fault_cnt > 0) begin
            fault_cnt = fault_cnt - 1;
            if (fault_cnt == 0) release dut.sd_init_done;
        end
        prev_dv <= display_valid;
        if (display_valid && !prev_dv) begin reads_first = reads; t_first = $realtime; end
    end
`ifdef SPI
    function integer cmd17s; cmd17s = card.cmd17_count; endfunction
`else
    function integer cmd17s; cmd17s = dut.sd_card_top_m0.rd_count; endfunction
`endif
    task report;
        integer i;
        begin
            $display("[%s] RESULT img=%s", tag, img);
            $display("[%s] slots_found=%0d slot_valid=%b slot_failed=%b preload_done=%0d display_valid=%0d last_error=%h",
                     tag, slots_found, slot_valid, slot_failed, preload_done, display_valid, dut.last_error);
            $display("[%s] slot_sectors %0d %0d %0d %0d %0d %0d", tag, dut.slot_sector0, dut.slot_sector1,
                     dut.slot_sector2, dut.slot_sector3, dut.slot_sector4, dut.slot_sector5);
            $display("[%s] checksums %h %h %h %h %h %h", tag, csum[0], csum[1], csum[2], csum[3], csum[4], csum[5]);
            $display("[%s] READS scan_to_first_load_start=%0d to_display_valid=%0d total=%0d read_requests=%0d cmd17=%0d",
                     tag, reads_scan, reads_first, reads, starts, cmd17s());
            $display("[%s] SIMTIME_ms scan_end=%0.3f display_valid=%0.3f end=%0.3f", tag,
                     t_scan / 1e6, t_first / 1e6, $realtime / 1e6);
        end
    endtask
    initial begin
        if (!$value$plusargs("TAG=%s", tag)) tag = "tb";
        if (!$value$plusargs("STOP=%s", stop)) stop = "all";
        if (!$value$plusargs("MAXREADS=%d", maxreads)) maxreads = 0;
        if (!$value$plusargs("FAULT_AT=%d", fault_at)) fault_at = 0;
        if (!$value$plusargs("IMG=%s", img)) img = "?";
        if ($value$plusargs("ADDRLOG=%s", alog)) fd = $fopen(alog, "w");
        repeat (5) @(posedge clk); rst = 0;
        if (stop == "first") wait (display_valid || preload_done);
        else wait (preload_done);
        repeat (20) @(posedge clk);
        report();
        if (fd) $fclose(fd);
        $finish;
    end
    initial begin #20_000_000_000; $display("[%s] WATCHDOG", tag); report(); $finish; end
endmodule
