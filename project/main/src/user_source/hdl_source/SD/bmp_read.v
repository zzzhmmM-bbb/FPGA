module bmp_read #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer IO_TIMEOUT_MS = 500
)(
    input clk, input rst, output ready,
    input scan_start,
    input [31:0] scan_start_sector, input [31:0] scan_max_sector,
    input [2:0] scan_target_count,
    output reg scan_done, output reg scan_found_valid,
    output reg [31:0] scan_found_sector, output reg [2:0] scan_found_total,
    input load_start, input [31:0] load_sector, input load_abort,
    output reg load_done, output reg load_error, output reg [3:0] error_code,
    input sd_init_done, output reg [3:0] state_code,
    input [15:0] bmp_width, input [15:0] bmp_height,
    output reg write_req, input write_req_ack,
    output reg sd_sec_read, output reg [31:0] sd_sec_read_addr,
    input [7:0] sd_sec_read_data,
    input sd_sec_read_data_valid, input sd_sec_read_end,
    output reg bmp_data_wr_en, output reg [23:0] bmp_data
);
localparam ST_IDLE=0, ST_SCAN=1, ST_LOAD_HDR=2, ST_LOAD_WAIT=3,
           ST_LOAD_DATA=4, ST_LOAD_CHECK=5, ST_SCAN_NEXT=6;
// Scan sub-modes. LINEAR is the original sector-by-sector scan.
localparam [1:0] SM_LINEAR=2'd0, SM_PROBE0=2'd1, SM_PROBE_BPB=2'd2, SM_FAST=2'd3;
// ST_SCAN_NEXT steps: every decision uses registered inputs only.
localparam [2:0] SN_WAIT=3'd0, SN_DECIDE=3'd1, SN_FAT1=3'd2, SN_FAT2=3'd3,
                 SN_PAD=3'd4, SN_INC=3'd5, SN_SETTLE=3'd6, SN_ISSUE=3'd7;
localparam [3:0] ERR_HEADER=4'h8, ERR_SECTOR=4'h9,
                 ERR_TIMEOUT=4'ha, ERR_PIXELS=4'hb;
// Divide first: 500 * 100 MHz overflows a 32-bit parameter expression.
localparam integer IO_TIMEOUT_CYCLES = (CLK_FREQ_HZ / 1000) * IO_TIMEOUT_MS;
reg [2:0] state;
reg [9:0] sector_bytes;
reg [31:0] io_timer;
reg [7:0] header_0, header_1;
reg [31:0] file_len, pixel_offset, dib_size, width, height, compression;
reg [15:0] planes, bit_count;
reg [31:0] scan_sector, load_sector_latched, bmp_len_cnt, pixel_count;
reg [1:0] bmp_byte_idx;
// header_match only accepts bmp_width==640 && bmp_height==480, so the frame
// size is a constant; this avoids a width*height multiplier.
localparam [31:0] EXPECTED_PIXELS = 32'd307200;
wire [32:0] pixel_end = {1'b0,pixel_offset} + 33'd921600;
wire [32:0] dib_end = {1'b0,dib_size} + 33'd14;
reg [32:0] sector_count_q;
reg [32:0] next_scan_sector_q;
// File length is complete by byte 5; split rounding and address addition
// across cycles before the complete header sector is accepted.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sector_count_q <= 33'd0;
        next_scan_sector_q <= 33'd0;
    end else begin
        sector_count_q <= ({1'b0,file_len} + 33'd511) >> 9;
        next_scan_sector_q <= {1'b0,scan_sector} + sector_count_q;
    end
end
wire header_match = header_0 == "B" && header_1 == "M" &&
                    width == {16'd0,bmp_width} && height == {16'd0,bmp_height} &&
                    bmp_width == 16'd640 && bmp_height == 16'd480 &&
                    planes == 16'd1 && bit_count == 16'd24 && compression == 0 &&
                    dib_size >= 40 && dib_end <= {1'b0,pixel_offset} &&
                    pixel_offset >= 54 && !pixel_end[32] &&
                    {1'b0,file_len} >= pixel_end;
reg header_match_q;
// Header fields end at byte 33. A full 512-byte header-sector read leaves
// ample clocks for this validation stage before either address decision.
always @(posedge clk or posedge rst) begin
    if (rst)
        header_match_q <= 1'b0;
    else
        header_match_q <= header_match;
end

// ---------------------------------------------------------------------------
// FAT32 fast locate (only when scan_start_sector==0). Sector 0 is probed:
// a BMP header keeps the original linear scan; an MBR whose first entry is
// FAT32 (0B/0C), or a FAT32 boot sector at 0, leads to a BPB read; a valid
// BPB gives data_start = part_lba + reserved + num_fats*fatsz, and then only
// cluster-boundary sectors are checked. Probe/BPB failure, or a fast pass that
// finds nothing, continues the original linear scan from sector 1.
// BPB fields reuse the header registers: bytes 10..13 -> pixel_offset,
// bytes 14..17 -> dib_size. MBR LBA (454..457) and BPB fatsz (36..39) share
// p_val; values >= 2^17 only set p_hi (such a layout falls back to linear).
// ---------------------------------------------------------------------------
reg [1:0] scan_mode;
reg [2:0] scan_step;
reg scan_ovf, beyond_q;
reg sig_ok, name_ok, ptype_ok, p_hi;
reg [16:0] p_val;
reg [7:0] clus_spc, pad_q;
reg mbr_ok_q, vbr_ok_q, bpb_ok_q, pix_ok_q, load_fit_q;
wire [7:0] f_spc = pixel_offset[31:24];
wire [15:0] f_bps = pixel_offset[23:8];
wire [15:0] f_rsvd = dib_size[15:0];
wire [7:0] f_nfats = dib_size[23:16];
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sig_ok<=0; name_ok<=0; ptype_ok<=0; p_hi<=0; p_val<=0;
    end else if (state == ST_SCAN && sd_sec_read_data_valid) begin
        case (sector_bytes)
            82:  name_ok<=sd_sec_read_data=="F";
            83:  name_ok<=name_ok && sd_sec_read_data=="A";
            84:  name_ok<=name_ok && sd_sec_read_data=="T";
            85:  name_ok<=name_ok && sd_sec_read_data=="3";
            86:  name_ok<=name_ok && sd_sec_read_data=="2";
            87,88,89: name_ok<=name_ok && sd_sec_read_data==" ";
            450: ptype_ok<=sd_sec_read_data==8'h0b || sd_sec_read_data==8'h0c;
            510: sig_ok<=sd_sec_read_data==8'h55;
            511: sig_ok<=sig_ok && sd_sec_read_data==8'haa;
            default: ;
        endcase
        if (scan_mode == SM_PROBE_BPB) begin
            case (sector_bytes)
                36: p_val[7:0]<=sd_sec_read_data;
                37: p_val[15:8]<=sd_sec_read_data;
                38: begin p_val[16]<=sd_sec_read_data[0]; p_hi<=sd_sec_read_data[7:1]!=0; end
                39: p_hi<=p_hi || sd_sec_read_data!=0;
                default: ;
            endcase
        end else begin
            case (sector_bytes)
                454: p_val[7:0]<=sd_sec_read_data;
                455: p_val[15:8]<=sd_sec_read_data;
                456: begin p_val[16]<=sd_sec_read_data[0]; p_hi<=sd_sec_read_data[7:1]!=0; end
                457: p_hi<=p_hi || sd_sec_read_data!=0;
                default: ;
            endcase
        end
    end
end
// Registered checks; consumed two or more cycles after the sector end.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        mbr_ok_q<=0; vbr_ok_q<=0; bpb_ok_q<=0; beyond_q<=0; pad_q<=0;
        pix_ok_q<=0; load_fit_q<=0;
    end else begin
        mbr_ok_q <= sig_ok && ptype_ok && !p_hi;
        vbr_ok_q <= sig_ok && name_ok && (header_0 == 8'heb || header_0 == 8'he9);
        bpb_ok_q <= sig_ok && f_bps == 16'd512 && f_spc != 8'd0 &&
                    (f_spc & (f_spc - 8'd1)) == 8'd0 && f_rsvd != 16'd0 &&
                    (f_nfats == 8'd1 || f_nfats == 8'd2) && p_val != 17'd0 && !p_hi;
        beyond_q <= scan_ovf || scan_sector > scan_max_sector;
        // Sectors from (file end) up to the next cluster boundary.
        pad_q <= (~sector_count_q[7:0] + 8'd1) & (clus_spc - 8'd1);
        pix_ok_q <= pixel_count == EXPECTED_PIXELS;
        load_fit_q <= {1'b0,load_sector_latched} + sector_count_q <= 33'h100000000;
    end
end
// Single scan-address adder shared by all scan steps.
reg [16:0] scan_addend;
always @(*) begin
    case (scan_step)
        SN_FAT1, SN_FAT2: scan_addend = p_val;
        SN_PAD: scan_addend = {9'd0,pad_q};
        SN_DECIDE:
            case (scan_mode)
                SM_PROBE0: scan_addend = mbr_ok_q ? p_val : 17'd1;
                SM_PROBE_BPB: scan_addend = {1'b0,f_rsvd};
                SM_FAST: scan_addend = {9'd0,clus_spc};
                default: scan_addend = 17'd1;
            endcase
        default: scan_addend = 17'd1;
    endcase
end
wire [32:0] scan_sum = {1'b0,scan_sector} + {16'd0,scan_addend};

// Read address register, decoupled from the error/abort priority chain: on
// an error or abort the state returns to ST_IDLE and the address is reloaded
// before the next read, so an update in that cycle is harmless.
always @(posedge clk or posedge rst) begin
    if (rst)
        sd_sec_read_addr <= 32'd0;
    else if (state == ST_IDLE) begin
        if (scan_start) sd_sec_read_addr <= scan_start_sector;
        else if (load_start) sd_sec_read_addr <= load_sector;
    end else if (state == ST_LOAD_DATA && sd_sec_read_end)
        sd_sec_read_addr <= sd_sec_read_addr + 1'b1;   // unused after the last sector
    else if (state == ST_SCAN_NEXT && scan_step == SN_ISSUE)
        sd_sec_read_addr <= scan_sector;
end

wire reading = state == ST_SCAN || state == ST_LOAD_HDR || state == ST_LOAD_DATA;
wire [32:0] length_at_end = {1'b0,bmp_len_cnt} + (sd_sec_read_data_valid ? 33'd1 : 33'd0);
wire pixel_byte = sd_sec_read_data_valid && bmp_len_cnt >= pixel_offset &&
                  {1'b0,bmp_len_cnt} < pixel_end;
assign ready = state == ST_IDLE;

task clear_header;
    begin
        header_0<=0; header_1<=0; file_len<=0; pixel_offset<=0; dib_size<=0;
        width<=0; height<=0; planes<=0; bit_count<=0; compression<=0;
    end
endtask
task fail_operation;
    input [3:0] code;
    begin
        load_error<=1; error_code<=code; state_code<=code;
        state<=ST_IDLE; sd_sec_read<=0; write_req<=0; bmp_data_wr_en<=0;
        if (state == ST_SCAN) scan_done<=1;
    end
endtask
// Continue the original linear scan after sector scan_start_sector (==0).
task scan_fallback;
    begin
        scan_mode<=SM_LINEAR; scan_sector<=scan_start_sector; scan_ovf<=1'b0;
        scan_step<=SN_INC;
    end
endtask

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state<=ST_IDLE; state_code<=0; sector_bytes<=0; io_timer<=0;
        clear_header();
        scan_sector<=0; load_sector_latched<=0; bmp_len_cnt<=0; pixel_count<=0;
        bmp_byte_idx<=0; write_req<=0; sd_sec_read<=0;
        scan_done<=0; scan_found_valid<=0; scan_found_sector<=0; scan_found_total<=0;
        load_done<=0; load_error<=0; error_code<=0; bmp_data_wr_en<=0; bmp_data<=0;
        scan_mode<=SM_LINEAR; scan_step<=SN_WAIT; scan_ovf<=0; clus_spc<=0;
    end else begin
        scan_found_valid<=0; load_done<=0; load_error<=0; bmp_data_wr_en<=0;
        if (bmp_data_wr_en) pixel_count<=pixel_count+1'b1;
        if (load_abort || !sd_init_done) begin
            state<=ST_IDLE; sd_sec_read<=0; write_req<=0;
            sector_bytes<=0; io_timer<=0; bmp_byte_idx<=0;
        end else if ((reading || state == ST_LOAD_WAIT) && io_timer >= IO_TIMEOUT_CYCLES-1) begin
            fail_operation(ERR_TIMEOUT);
        end else if (reading && ((sd_sec_read_data_valid && sector_bytes >= 512) ||
                     (sd_sec_read_end && (sd_sec_read_data_valid ?
                        sector_bytes != 10'd511 : sector_bytes != 10'd512)))) begin
            fail_operation(ERR_SECTOR);
        end else begin
            if (reading || state == ST_LOAD_WAIT) io_timer<=io_timer+1'b1;
            else io_timer<=0;
            if (reading) begin
                if (sd_sec_read_end) begin sector_bytes<=0; io_timer<=0; end
                else if (sd_sec_read_data_valid) sector_bytes<=sector_bytes+1'b1;
            end else sector_bytes<=0;
            if ((state == ST_SCAN || state == ST_LOAD_HDR) && sd_sec_read_data_valid) begin
                case (sector_bytes)
                    0: header_0<=sd_sec_read_data;
                    1: header_1<=sd_sec_read_data;
                    2: file_len[7:0]<=sd_sec_read_data;
                    3: file_len[15:8]<=sd_sec_read_data;
                    4: file_len[23:16]<=sd_sec_read_data;
                    5: file_len[31:24]<=sd_sec_read_data;
                    10: pixel_offset[7:0]<=sd_sec_read_data;
                    11: pixel_offset[15:8]<=sd_sec_read_data;
                    12: pixel_offset[23:16]<=sd_sec_read_data;
                    13: pixel_offset[31:24]<=sd_sec_read_data;
                    14: dib_size[7:0]<=sd_sec_read_data;
                    15: dib_size[15:8]<=sd_sec_read_data;
                    16: dib_size[23:16]<=sd_sec_read_data;
                    17: dib_size[31:24]<=sd_sec_read_data;
                    18: width[7:0]<=sd_sec_read_data;
                    19: width[15:8]<=sd_sec_read_data;
                    20: width[23:16]<=sd_sec_read_data;
                    21: width[31:24]<=sd_sec_read_data;
                    22: height[7:0]<=sd_sec_read_data;
                    23: height[15:8]<=sd_sec_read_data;
                    24: height[23:16]<=sd_sec_read_data;
                    25: height[31:24]<=sd_sec_read_data;
                    26: planes[7:0]<=sd_sec_read_data;
                    27: planes[15:8]<=sd_sec_read_data;
                    28: bit_count[7:0]<=sd_sec_read_data;
                    29: bit_count[15:8]<=sd_sec_read_data;
                    30: compression[7:0]<=sd_sec_read_data;
                    31: compression[15:8]<=sd_sec_read_data;
                    32: compression[23:16]<=sd_sec_read_data;
                    33: compression[31:24]<=sd_sec_read_data;
                    default: ;
                endcase
            end
            case (state)
                ST_IDLE: begin
                    state_code<=1; sd_sec_read<=0; write_req<=0; io_timer<=0;
                    // Unconditional: keeps scan_start/load_start off the header-register data path.
                    clear_header();
                    if (scan_start) begin
                        scan_done<=0; scan_found_total<=0;
                        scan_sector<=scan_start_sector;
                        scan_mode<=(scan_start_sector == 32'd0) ? SM_PROBE0 : SM_LINEAR;
                        scan_ovf<=1'b0;
                        error_code<=0; state<=ST_SCAN;
                    end else if (load_start) begin
                        load_sector_latched<=load_sector;
                        bmp_len_cnt<=0;
                        pixel_count<=0; bmp_byte_idx<=0; error_code<=0; state<=ST_LOAD_HDR;
                    end
                end
                ST_SCAN: begin
                    // Sector end only changes state; decisions follow in ST_SCAN_NEXT.
                    // Header registers are not cleared: bytes 0..33 of every sector overwrite them.
                    state_code<=2; sd_sec_read<=1; scan_step<=SN_WAIT;
                    if (sd_sec_read_end) begin
                        sd_sec_read<=0; state<=ST_SCAN_NEXT;
                    end
                end
                ST_SCAN_NEXT: begin
                    state_code<=2; sd_sec_read<=0;
                    case (scan_step)
                        SN_WAIT: scan_step<=SN_DECIDE;
                        SN_DECIDE: begin
                            if (header_match_q && scan_mode != SM_PROBE_BPB) begin
                                // BMP found (LINEAR, FAST, or a raw layout at sector 0).
                                if (scan_mode == SM_PROBE0) scan_mode<=SM_LINEAR;
                                scan_found_valid<=1; scan_found_sector<=scan_sector;
                                scan_found_total<=scan_found_total+1'b1;
                                if (scan_found_total+1'b1 >= scan_target_count) begin
                                    scan_done<=1; state<=ST_IDLE;
                                end else begin
                                    scan_sector<=next_scan_sector_q[31:0]; scan_ovf<=next_scan_sector_q[32];
                                    scan_step<=(scan_mode == SM_FAST) ? SN_PAD : SN_SETTLE;
                                end
                            end else begin
                                case (scan_mode)
                                    SM_PROBE0: begin
                                        if (mbr_ok_q) begin
                                            // scan_sector==0, so scan_sum is the partition LBA.
                                            scan_mode<=SM_PROBE_BPB; scan_sector<=scan_sum[31:0];
                                        end else if (vbr_ok_q) begin
                                            scan_mode<=SM_PROBE_BPB;          // re-read sector 0 as BPB
                                        end else begin
                                            scan_mode<=SM_LINEAR; scan_sector<=scan_sum[31:0]; scan_ovf<=scan_sum[32];
                                        end
                                        scan_step<=SN_SETTLE;
                                    end
                                    SM_PROBE_BPB: begin
                                        if (bpb_ok_q) begin
                                            // part_lba + reserved; FAT size added in SN_FAT1/2.
                                            scan_mode<=SM_FAST; clus_spc<=f_spc;
                                            scan_sector<=scan_sum[31:0]; scan_ovf<=scan_sum[32];
                                            scan_step<=SN_FAT1;
                                        end else scan_fallback();
                                    end
                                    default: begin
                                        // LINEAR: +1; FAST: next cluster boundary.
                                        scan_sector<=scan_sum[31:0]; scan_ovf<=scan_sum[32];
                                        scan_step<=SN_SETTLE;
                                    end
                                endcase
                            end
                        end
                        SN_FAT1, SN_FAT2: begin
                            scan_sector<=scan_sum[31:0]; scan_ovf<=scan_ovf | scan_sum[32];
                            scan_step<=(scan_step == SN_FAT1 && f_nfats == 8'd2) ? SN_FAT2 : SN_SETTLE;
                        end
                        SN_PAD, SN_INC: begin
                            scan_sector<=scan_sum[31:0]; scan_ovf<=scan_ovf | scan_sum[32];
                            scan_step<=SN_SETTLE;
                        end
                        SN_SETTLE: scan_step<=SN_ISSUE;          // beyond_q follows scan_sector
                        default: begin                           // SN_ISSUE
                            if (!beyond_q) state<=ST_SCAN;
                            else if (scan_mode != SM_LINEAR && scan_found_total == 3'd0) scan_fallback();
                            else begin scan_done<=1; state<=ST_IDLE; end
                        end
                    endcase
                end
                ST_LOAD_HDR: begin
                    state_code<=2; sd_sec_read<=1;
                    if (sd_sec_read_end) begin
                        sd_sec_read<=0;
                        // sd_sec_read_addr still equals load_sector_latched (set from ST_IDLE).
                        if (header_match_q && load_fit_q) begin
                            write_req<=1; state<=ST_LOAD_WAIT;
                        end else fail_operation(ERR_HEADER);
                    end
                end
                ST_LOAD_WAIT: begin
                    state_code<=3;
                    if (write_req_ack) begin write_req<=0; io_timer<=0; state<=ST_LOAD_DATA; end
                end
                ST_LOAD_DATA: begin
                    state_code<=4; sd_sec_read<=1; scan_step<=3'd0;
                    if (sd_sec_read_data_valid) bmp_len_cnt<=bmp_len_cnt+1'b1;
                    if (pixel_byte) begin
                        case (bmp_byte_idx)
                            0: begin bmp_data[7:0]<=sd_sec_read_data; bmp_byte_idx<=1; end
                            1: begin bmp_data[15:8]<=sd_sec_read_data; bmp_byte_idx<=2; end
                            2: begin bmp_data[23:16]<=sd_sec_read_data; bmp_byte_idx<=0; bmp_data_wr_en<=1; end
                        endcase
                    end
                    if (sd_sec_read_end) begin
                        sd_sec_read<=0;
                        if (length_at_end >= {1'b0,file_len}) state<=ST_LOAD_CHECK;
                    end
                end
                ST_LOAD_CHECK: begin
                    // Wait until a final registered pixel is counted and pix_ok_q follows it.
                    if (scan_step != 3'd2) scan_step<=scan_step+1'b1;
                    else if (pix_ok_q && bmp_byte_idx == 0) begin
                        load_done<=1; state<=ST_IDLE;
                    end else fail_operation(ERR_PIXELS);
                end
                default: fail_operation(ERR_HEADER);
            endcase
        end
    end
end
endmodule
