// Behavioural SPI-mode SDHC card (block addressing) for simulation.
// Supports CMD0/8/55/41/58/16/17. Mode 0/3: samples MOSI on SCLK rising,
// drives MISO on SCLK falling. Bytes received with CS high are ignored.
// CMD41 answers "idle" ACMD41_BUSY times before becoming ready.
module sd_spi_card #(parameter integer NAC_BYTES = 4, parameter integer ACMD41_BUSY = 2)(
    input sclk, input cs_n, input mosi, output reg miso
);
    sd_image_store store();
    reg [7:0] q [0:1023];
    integer qh, qt;
    reg [7:0] rx, txs;
    integer rxc, txc;
    reg [7:0] cmdb [0:5];
    integer cmdi;
    reg idle, app, dbg;
    integer acmd41_n;
    integer cmd17_count, cmd_count;
    reg [31:0] last17;
    initial begin
        miso = 1; qh = 0; qt = 0; rxc = 0; txc = 0; cmdi = 0; idle = 1; app = 0;
        acmd41_n = 0; cmd17_count = 0; cmd_count = 0;
        dbg = $test$plusargs("SDDBG");
    end
    task push(input [7:0] b); begin q[qt] = b; qt = (qt + 1) % 1024; end endtask
    task do_cmd;
        reg [5:0] c; reg [31:0] arg; integer k;
        begin
            c = cmdb[0][5:0]; arg = {cmdb[1], cmdb[2], cmdb[3], cmdb[4]};
            cmd_count = cmd_count + 1;
            if (dbg && (c != 17 || cmd17_count < 3)) $display("[card] t=%0t CMD%0d arg=%h", $time, c, arg);
            qh = 0; qt = 0;
            push(8'hff);                                   // NCR
            case (c)
                0: begin idle = 1; push(8'h01); end
                8: begin push(idle ? 8'h01 : 8'h00); push(8'h00); push(8'h00); push(8'h01); push(arg[7:0]); end
                55: begin app = 1; push(idle ? 8'h01 : 8'h00); end
                41: begin
                        if (acmd41_n >= ACMD41_BUSY) idle = 0;
                        acmd41_n = acmd41_n + 1;
                        push(idle ? 8'h01 : 8'h00);
                    end
                58: begin push(idle ? 8'h01 : 8'h00); push(8'hc0); push(8'hff); push(8'h80); push(8'h00); end
                16: push(8'h00);
                17: begin
                        cmd17_count = cmd17_count + 1; last17 = arg;
                        push(8'h00);
                        for (k = 0; k < NAC_BYTES; k = k + 1) push(8'hff);
                        push(8'hfe);
                        store.fetch(arg);
                        for (k = 0; k < 512; k = k + 1) push(store.sbuf[k]);
                        push(8'h12); push(8'h34);              // CRC (ignored by host)
                    end
                default: push(8'h04);                      // illegal command
            endcase
            if (c != 55) app = 0;
        end
    endtask
    always @(posedge cs_n) begin rxc = 0; txc = 0; cmdi = 0; miso = 1; end
    always @(posedge sclk) if (!cs_n) begin
        rx = {rx[6:0], mosi}; rxc = rxc + 1;
        if (rxc == 8) begin
            rxc = 0;
            if (cmdi == 0) begin
                if (rx[7:6] == 2'b01) begin cmdb[0] = rx; cmdi = 1; end
            end else begin
                cmdb[cmdi] = rx; cmdi = cmdi + 1;
                if (cmdi == 6) begin cmdi = 0; do_cmd(); end
            end
        end
    end
    always @(negedge sclk) if (!cs_n) begin
        if (txc == 0) begin
            if (qh != qt) begin txs = q[qh]; qh = (qh + 1) % 1024; end else txs = 8'hff;
        end
        miso = txs[7]; txs = {txs[6:0], 1'b1};
        txc = (txc + 1) % 8;
    end
endmodule
