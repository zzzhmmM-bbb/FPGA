module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter [31:0] SCAN_START_SECTOR = 32'd0,
    parameter [31:0] SCAN_MAX_SECTOR = 32'd131071,
    parameter [2:0] SCAN_TARGET_COUNT = 3'd6,   // 1..6
    parameter integer IO_TIMEOUT_MS = 500,
    parameter integer LOAD_TIMEOUT_MS = 5000,
    parameter integer INIT_TIMEOUT_MS = 5000
)(
    input clk, input rst,
    output [3:0] state_code,
    input [15:0] bmp_width, input [15:0] bmp_height,
    output reg display_valid,        // at least one slot loaded; 0->1 only
    output reg [5:0] slot_valid,     // slot k fully written to SDRAM
    output reg [5:0] slot_failed,    // slot k failed after retry, skipped
    output reg [2:0] slots_found,    // images found by scan, 0..6
    output reg preload_done,         // every found slot loaded or failed
    output reg [2:0] load_slot,      // slot being written -> write_addr_index
    input memory_ready,
    input write_finish_toggle,
    output reg write_req, input write_req_ack,
    output reg write_abort_req, input write_abort_ack, input write_overflow,
    output write_en, output [31:0] write_data,
    output SD_nCS, output SD_DCLK, output SD_MOSI, input SD_MISO
);
localparam P_WAIT_SD=0, P_SCAN=1, P_IDLE=2, P_LOAD=3,
           P_ABORT_HIGH=4, P_ABORT_LOW=5, P_REINIT=6, P_FAILED=7, P_ABORT_FAILED=8,
           P_PREP=9, P_DONE=10;
localparam integer LOAD_CYCLES=(CLK_FREQ_HZ/1000)*LOAD_TIMEOUT_MS;
localparam integer INIT_CYCLES=(CLK_FREQ_HZ/1000)*INIT_TIMEOUT_MS;
localparam integer ABORT_CYCLES=(CLK_FREQ_HZ/1000)*IO_TIMEOUT_MS;
reg [3:0] phase, last_error;
reg [31:0] phase_timer;
reg [3:0] settle_count;
reg sd_recover_rst;
wire sd_sec_read;
wire [31:0] sd_sec_read_addr;
wire [7:0] sd_sec_read_data;
wire sd_sec_read_data_valid, sd_sec_read_end, sd_init_done;
wire bmp_ready, scan_done, scan_found_valid;
wire [31:0] scan_found_sector;
wire [2:0] scan_found_total;
wire bmp_data_wr_en;
wire [23:0] bmp_data;
wire parser_write_req, source_done, source_error;
wire [3:0] parser_state, source_error_code;
reg scan_start_pulse, load_start_pulse;
reg [31:0] load_sector;
reg [31:0] slot_sector0, slot_sector1, slot_sector2, slot_sector3, slot_sector4, slot_sector5;
reg source_done_seen, memory_done_seen;
reg retried, retry_pending, recover_scan;
reg [2:0] wrfin_tgl_sync;
reg [1:0] abort_ack_sync, write_ack_sync;
wire write_finish_pulse=wrfin_tgl_sync[2]^wrfin_tgl_sync[1];
wire load_timeout=phase_timer>=LOAD_CYCLES-1;
wire transaction_error=source_error || write_overflow || !memory_ready || !sd_init_done || load_timeout;
assign state_code=last_error!=0 ? last_error : parser_state;
// Only a registered request crosses to the memory-domain request synchronizer.
always @(posedge clk or posedge rst) begin
    if (rst)
        write_req <= 1'b0;
    else
        write_req <= parser_write_req && phase==P_LOAD && !transaction_error && !write_abort_req;
end
assign write_en=bmp_data_wr_en && phase==P_LOAD && !transaction_error;
assign write_data={bmp_data[23:16],bmp_data[15:8],bmp_data[7:0],8'd0};

function [5:0] found_mask;
    input [2:0] count;
    begin
        case (count)
            3'd0: found_mask = 6'b000000;
            3'd1: found_mask = 6'b000001;
            3'd2: found_mask = 6'b000011;
            3'd3: found_mask = 6'b000111;
            3'd4: found_mask = 6'b001111;
            3'd5: found_mask = 6'b011111;
            default: found_mask = 6'b111111;
        endcase
    end
endfunction
// Lowest slot that is neither loaded nor failed.
function [2:0] first_open;
    input [5:0] open;
    begin
        if (open[0]) first_open = 3'd0;
        else if (open[1]) first_open = 3'd1;
        else if (open[2]) first_open = 3'd2;
        else if (open[3]) first_open = 3'd3;
        else if (open[4]) first_open = 3'd4;
        else first_open = 3'd5;
    end
endfunction
function [31:0] sector_of;
    input [2:0] idx;
    begin
        case(idx)
            0: sector_of=slot_sector0;
            1: sector_of=slot_sector1;
            2: sector_of=slot_sector2;
            3: sector_of=slot_sector3;
            4: sector_of=slot_sector4;
            default: sector_of=slot_sector5;
        endcase
    end
endfunction
wire [5:0] open_slots=found_mask(slots_found) & ~(slot_valid | slot_failed);
task start_scan;
    begin
        scan_start_pulse<=1; slots_found<=0;
        phase<=P_SCAN; phase_timer<=0;
    end
endtask
// load_sector is registered in P_PREP; a retry reuses it unchanged.
task start_load;
    begin
        load_start_pulse<=1;
        source_done_seen<=0; memory_done_seen<=0;
        phase<=P_LOAD; phase_timer<=0;
    end
endtask
task start_recovery;
    input [3:0] code; input for_scan;
    begin
        last_error<=code; recover_scan<=for_scan;
        retry_pending<=!retried; retried<=1;
        source_done_seen<=0; memory_done_seen<=0;
        write_abort_req<=1; sd_recover_rst<=1; settle_count<=0;
        phase<=P_ABORT_HIGH; phase_timer<=0;
    end
endtask
// Terminal stop: unfinished slots count as failed.
task stop_preload;
    begin
        preload_done<=1; slot_failed<=slot_failed | open_slots;
    end
endtask

always @(posedge clk or posedge rst) begin
    if (rst) begin
        phase<=P_WAIT_SD; last_error<=0; phase_timer<=0; settle_count<=0;
        sd_recover_rst<=0; write_abort_req<=0;
        wrfin_tgl_sync<=0; abort_ack_sync<=0; write_ack_sync<=0;
        scan_start_pulse<=0; load_start_pulse<=0; load_sector<=0;
        slots_found<=0; load_slot<=0;
        slot_sector0<=0; slot_sector1<=0; slot_sector2<=0;
        slot_sector3<=0; slot_sector4<=0; slot_sector5<=0;
        slot_valid<=0; slot_failed<=0; preload_done<=0;
        source_done_seen<=0; memory_done_seen<=0;
        retried<=0; retry_pending<=0; recover_scan<=0; display_valid<=0;
    end else begin
        wrfin_tgl_sync<={wrfin_tgl_sync[1:0],write_finish_toggle};
        abort_ack_sync<={abort_ack_sync[0],write_abort_ack};
        write_ack_sync<={write_ack_sync[0],write_req_ack};
        scan_start_pulse<=0; load_start_pulse<=0;
        if (phase==P_WAIT_SD || phase==P_LOAD || phase==P_ABORT_HIGH ||
            phase==P_ABORT_LOW || phase==P_REINIT) phase_timer<=phase_timer+1'b1;
        else phase_timer<=0;

        if (phase==P_SCAN && scan_found_valid) begin
            case(slots_found)
                0: slot_sector0<=scan_found_sector;
                1: slot_sector1<=scan_found_sector;
                2: slot_sector2<=scan_found_sector;
                3: slot_sector3<=scan_found_sector;
                4: slot_sector4<=scan_found_sector;
                5: slot_sector5<=scan_found_sector;
            endcase
            if (slots_found<6) slots_found<=slots_found+1'b1;
        end

        case(phase)
            P_WAIT_SD: begin
                if (sd_init_done && memory_ready) begin retried<=0; start_scan(); end
                else if (phase_timer>=INIT_CYCLES-1) begin
                    last_error<=4'he; sd_recover_rst<=1; stop_preload(); phase<=P_FAILED;
                end
            end
            P_SCAN: begin
                if (source_error || !sd_init_done) start_recovery(source_error ? source_error_code : 4'he,1'b1);
                else if (scan_done && !scan_start_pulse) begin
                    phase<=P_IDLE; retried<=0;
                end
            end
            P_IDLE: begin
                // Pick the next slot; its sector is registered in P_PREP.
                if (slots_found==0) begin last_error<=4'h8; preload_done<=1; phase<=P_DONE; end
                else if (open_slots==0) begin preload_done<=1; phase<=P_DONE; end
                else begin load_slot<=first_open(open_slots); retried<=0; phase<=P_PREP; end
            end
            P_PREP: begin
                load_sector<=sector_of(load_slot);
                if (bmp_ready && memory_ready && sd_init_done) start_load();
            end
            P_LOAD: begin
                // An error invalidates the transaction even when both completions arrive now.
                if (transaction_error) begin
                    start_recovery(source_error ? source_error_code :
                                   write_overflow ? 4'hc : 4'ha,1'b0);
                end else begin
                    if (source_done) source_done_seen<=1;
                    if (write_finish_pulse) memory_done_seen<=1;
                    if ((source_done_seen || source_done) && (memory_done_seen || write_finish_pulse)) begin
                        slot_valid[load_slot]<=1; display_valid<=1;
                        source_done_seen<=0; memory_done_seen<=0; last_error<=0;
                        retried<=0; phase<=P_IDLE; phase_timer<=0;
                    end
                end
            end
            P_ABORT_HIGH: begin
                if (abort_ack_sync[1]) begin
                    write_abort_req<=0; phase<=P_ABORT_LOW; phase_timer<=0; settle_count<=0;
                end else if (phase_timer>=ABORT_CYCLES-1) begin
                    // No safe cancellation acknowledgement: never launch another writer.
                    last_error<=4'hd; stop_preload(); phase<=P_ABORT_FAILED;
                end
            end
            P_ABORT_LOW: begin
                // Keep the SD stack reset while old write completion crosses the synchronizer.
                if (!abort_ack_sync[1] && !write_ack_sync[1] && wrfin_tgl_sync=={3{wrfin_tgl_sync[2]}}) begin
                    if (settle_count==7) begin
                        if (retry_pending) begin
                            sd_recover_rst<=0; phase<=P_REINIT; phase_timer<=0;
                        end else if (!recover_scan) begin
                            // Retry failed: skip this slot, reinit SD for the next one.
                            slot_failed[load_slot]<=1;
                            sd_recover_rst<=0; phase<=P_REINIT; phase_timer<=0;
                        end else begin stop_preload(); phase<=P_FAILED; end
                    end else settle_count<=settle_count+1'b1;
                end else settle_count<=0;
                if (phase_timer>=ABORT_CYCLES-1) begin
                    last_error<=4'hd; stop_preload(); phase<=P_ABORT_FAILED;
                end
            end
            P_REINIT: begin
                if (sd_init_done && memory_ready && bmp_ready) begin
                    if (recover_scan) start_scan();
                    else if (retry_pending) start_load();
                    else phase<=P_IDLE;
                end else if (phase_timer>=INIT_CYCLES-1) begin
                    last_error<=4'he; sd_recover_rst<=1; stop_preload(); phase<=P_FAILED;
                end
            end
            P_FAILED: begin
                // Terminal: no automatic retry loop.
            end
            P_ABORT_FAILED: begin
                // Memory cancellation did not finish; system reset is required to re-arm.
            end
            P_DONE: begin
                // Preload finished; no further loads.
            end
            default: begin last_error<=4'hd; stop_preload(); phase<=P_ABORT_FAILED; end
        endcase
    end
end

bmp_read #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.IO_TIMEOUT_MS(IO_TIMEOUT_MS)) bmp_read_m0(
    .clk(clk),.rst(rst),.ready(bmp_ready),
    .scan_start(scan_start_pulse),.scan_start_sector(SCAN_START_SECTOR),
    .scan_max_sector(SCAN_MAX_SECTOR),.scan_target_count(SCAN_TARGET_COUNT),
    .scan_done(scan_done),.scan_found_valid(scan_found_valid),
    .scan_found_sector(scan_found_sector),.scan_found_total(scan_found_total),
    .load_start(load_start_pulse),.load_sector(load_sector),
    .load_abort(phase!=P_SCAN && phase!=P_LOAD),
    .load_done(source_done),.load_error(source_error),.error_code(source_error_code),
    .sd_init_done(sd_init_done),.state_code(parser_state),
    .bmp_width(bmp_width),.bmp_height(bmp_height),
    .write_req(parser_write_req),.write_req_ack(write_ack_sync[1]),
    .sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),.bmp_data_wr_en(bmp_data_wr_en),.bmp_data(bmp_data));
sd_card_top sd_card_top_m0(
    .clk(clk),.rst(rst | sd_recover_rst),
    .SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),
    .sd_init_done(sd_init_done),.sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),.sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),
    .sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end());
endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
