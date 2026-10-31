
module top(
    input                       clk,
    input                       rst_n,          // Physical KEY1: short reset / long auto toggle
    input                       sw3_thumb, // Physical SW3 / C6
    input                       sw_param_mode, // Physical SW1
    input                       sw_param_select, // Physical SW2
    input                       key_cal_n,      // Physical KEY3: calibration
    input                       key1,           // Physical KEY2: short next / long previous / parameter down
    input                       key2,           // Physical KEY4: short confirm / long period / parameter up

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,

    // Board2 link
    input                       link_bclk,
    input                       link_ws,
    input                       link_sd,
    output                      link_ptt
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
// SDRAM slot k base = k * FRAME_PIXELS (elaboration-time constants).
// Slots 0..2: covers of levels 1..3; slots 3..5: level 1..3 backgrounds.
localparam [23:0] SLOT0_ADDR = 24'd0;
localparam [23:0] SLOT1_ADDR = FRAME_PIXELS * 1;
localparam [23:0] SLOT2_ADDR = FRAME_PIXELS * 2;
localparam [23:0] SLOT3_ADDR = FRAME_PIXELS * 3;
localparam [23:0] SLOT4_ADDR = FRAME_PIXELS * 4;
localparam [23:0] SLOT5_ADDR = FRAME_PIXELS * 5;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;
wire [5:0]  slot_valid;
wire [5:0]  slot_failed;
wire [2:0]  slots_found;
wire        preload_done;
wire [2:0]  load_slot;
wire [3:0]  osd_status_video;
wire [23:0] vout_data_osd;
wire [23:0] vout_data_waveform;
wire [23:0] vout_data_level;
wire [23:0] vout_data_calibration;
wire [23:0] vout_data_sustain;
wire        l1_sub_en;
wire [3:0]  l1_slot_en;
wire [19:0] l1_slot_id;
wire [39:0] l1_slot_cx;
wire [35:0] l1_slot_cy;
wire [11:0] l1_slot_kind;
wire [23:0] vout_data_review;
wire [23:0] vout_data_selected;
wire [23:0] vout_data_faded;
wire [23:0] vout_data_menu;
wire [23:0] vout_data_tone;
wire [23:0] vout_data_vowel;
wire [23:0] vout_data_vowel_spec;
reg [23:0] vout_data_plain_q;
reg display_vs_q, display_de_q, practice_view_q, review_page_q;
wire [23:0] vout_data_brightness;
wire [3:0] brightness;
wire practice_view;

// Cover carousel: level drives keys; level_v (latched at frame start) drives
// every display select/enable. display_slot selects the SDRAM slot to show.
wire [2:0] level;
reg  [2:0] level_v;
reg        level_vs_q;
wire [2:0] display_slot;
wire [1:0] cover_idx;
wire [8:0] carousel_alpha;
wire       carousel_busy;
wire [1:0] carousel_period_index;
reg  [5:0] slot_valid_meta;
(* async_reg = "true" *) reg [5:0] slot_valid_v;
wire       auto_mode_ref;
(* async_reg = "true" *) reg auto_mode_meta, auto_mode_video;

wire [3:0]  state_code;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// Hold the system until all PLLs remain locked, then release each clock domain.
wire rst_all;
wire pll_reset, sys_pll_locked, video_pll_locked;
wire rst_sd, rst_mem, rst_video, rst_audio, rst_ref;
wire write_abort_req, write_abort_ack, write_overflow;
(* async_reg = "true" *) reg memory_ready_meta, memory_ready_sd;

wire thumb_active,thumb_ui_busy,thumb_owned,thumb_flip,thumb_ready,thumb_cover_commit;
wire thumb_prefetch_busy,thumb_fault,thumb_reserved,tf_busy;
wire thumb_fifo_reset,thumb_fifo_we,thumb_fifo_full;
wire [8:0] thumb_fifo_used;
wire [31:0] thumb_fifo_data,tf_app_wr_data;
wire tf_app_wr_en;
wire [20:0] tf_app_wr_addr;
wire [1:0] thumb_focus;
wire [2:0] thumb_active_slot,thumb_valid,thumb_source_mask;
wire [3:0] thumb_source_epoch;
wire thumb_rebuild_ready,thumb_rebuild_accepted,thumb_build_start;
wire menu_next_press, menu_prev_press, menu_confirm_press;
wire [14:0] subtitle_addr;wire [10:0] subtitle_meta_addr;
wire [15:0] subtitle_data,subtitle_meta_data;
reg [1:0] thumb_fault_video;
(* async_reg = "true" *) reg [1:0] thumb_key3_sync;
reg thumb_key3_armed;
reg [18:0] thumb_key3_release;
always @(posedge video_clk or posedge rst_video)begin
    if(rst_video)begin thumb_fault_video<=0;thumb_key3_sync<=3;thumb_key3_armed<=0;thumb_key3_release<=0;end
    else begin
        thumb_fault_video<={thumb_fault_video[0],thumb_fault};
        thumb_key3_sync<={thumb_key3_sync[0],key_cal_n};
        if(thumb_owned || !thumb_key3_sync[1])begin thumb_key3_release<=0;if(thumb_owned)thumb_key3_armed<=0;end
        else if(thumb_key3_release==499999)thumb_key3_armed<=1;
        else thumb_key3_release<=thumb_key3_release+1'b1;
    end
end

wire system_reset_n;
key1_mode_control u_key1_mode_control(
    .clk(clk), .key_n(rst_n), .inhibit_long(thumb_owned),
    .system_reset_n(system_reset_n), .auto_mode(auto_mode_ref)
);
startup_reset_control u_startup_reset_control(
    .clk(clk), .rst_n(system_reset_n),
    .sys_pll_locked(sys_pll_locked), .video_pll_locked(video_pll_locked),
    .audio_pll_locked(audio_pll_lock),
    .pll_reset(pll_reset), .global_reset(rst_all)
);
reset_sync u_reset_sd(.clk(sd_card_clk), .async_reset(rst_all), .reset(rst_sd));
reset_sync u_reset_mem(.clk(ext_mem_clk), .async_reset(rst_all), .reset(rst_mem));
reset_sync u_reset_video(.clk(video_clk), .async_reset(rst_all), .reset(rst_video));
reset_sync u_reset_audio(.clk(audio_mclk), .async_reset(rst_all), .reset(rst_audio));
reset_sync u_reset_ref(.clk(clk), .async_reset(rst_all), .reset(rst_ref));
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd) begin
        memory_ready_meta <= 1'b0;
        memory_ready_sd <= 1'b0;
    end else begin
        memory_ready_meta <= Sdr_init_done;
        memory_ready_sd <= memory_ready_meta;
    end
end

// 保持原有的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (pll_reset),
    .locked     (sys_pll_locked)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (pll_reset),
    .locked     (video_pll_locked)
);

// 复用 I2S->HDMI 例程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (pll_reset),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（6 槽预加载） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd6)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .memory_ready      (memory_ready_sd),
    .write_abort_req   (write_abort_req),
    .write_abort_ack   (write_abort_ack),
    .write_overflow    (write_overflow),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),
    .slot_valid        (slot_valid),
    .slot_failed       (slot_failed),
    .slots_found       (slots_found),
    .preload_done      (preload_done),
    .load_slot         (load_slot),

    .write_finish_toggle(frame_write_toggle_mem),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

// slot_valid bits only go 0 -> 1, so per-bit two-stage sync is safe.
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        slot_valid_meta <= 6'd0;
        slot_valid_v <= 6'd0;
    end else begin
        slot_valid_meta <= slot_valid;
        slot_valid_v <= slot_valid_meta;
    end
end

// display_valid 来自 sd_card_clk 域，开机后只 0 -> 1 一次，两级同步后再进像素选择
reg display_valid_meta, display_valid_v;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        display_valid_meta <= 1'b0;
        display_valid_v <= 1'b0;
    end else begin
        display_valid_meta <= display_valid;
        display_valid_v <= display_valid_meta;
    end
end

assign seg_sel = 6'b111111;
assign seg_data = 8'hff;

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

// Coordinates use the exact raw timing entering the 20-cycle pixel pipeline.
reg thumb_vs_q;
reg [9:0] thumb_x,thumb_y;
always @(posedge video_clk or posedge rst_video) begin
    if(rst_video)begin thumb_vs_q<=0;thumb_x<=0;thumb_y<=0;end
    else begin
        thumb_vs_q<=vs_0;
        if(!vs_0)begin thumb_x<=0;thumb_y<=0;end
        else if(de_0)begin
            if(thumb_x==639)begin thumb_x<=0;thumb_y<=thumb_y+1'b1;end
            else thumb_x<=thumb_x+1'b1;
        end
    end
end
wire thumb_frame_start=thumb_vs_q && !vs_0;
thumbnail_controls u_thumbnail_controls(
    .clk(video_clk),.rst(rst_video),.sw3(sw3_thumb),.active(thumb_active),
    .ui_busy(thumb_ui_busy),.cover_commit(thumb_cover_commit),.ready(thumb_ready),
    .valid_slots(thumb_valid),.current_cover(cover_idx),.level(level),
    .carousel_busy(carousel_busy),.fault(thumb_fault_video[1]),
    .key_next(menu_next_press),.key_prev(menu_prev_press),
    .flip(thumb_flip),.owned(thumb_owned),.focus(thumb_focus));
thumbnail_load_admission u_thumbnail_load(
    .sd_clk(sd_card_clk),.sd_rst(rst_sd),.preload_done(preload_done),.slot_valid(slot_valid),
    .mem_clk(ext_mem_clk),.mem_rst(rst_mem),.rebuild_ready(thumb_rebuild_ready),
    .rebuild_accepted(thumb_rebuild_accepted),.build_start(thumb_build_start),
    .source_mask(thumb_source_mask),.source_epoch(thumb_source_epoch));
thumbnail_datapath u_thumbnail_datapath(
    .video_clk(video_clk),.video_rst(rst_video),.mem_clk(ext_mem_clk),.mem_rst(rst_mem),
    .mode_flip(thumb_flip),.restricted(level!=0 || carousel_busy),.frame_start(thumb_frame_start),
    .focus(thumb_focus),.original_slot(display_slot),.build_start(thumb_build_start),
    .build_abort(1'b0),.source_valid(thumb_source_mask),.source_epoch(thumb_source_epoch),
    .subtitle_addr(subtitle_addr),.subtitle_meta_addr(subtitle_meta_addr),
    .subtitle_data(subtitle_data),.subtitle_meta_data(subtitle_meta_data),
    .static_request(),.text_cancel(),.build_x(),.build_y(),.build_advance(),
    .sdr_busy(Sdr_busy || !Sdr_init_done),.sdr_rd_valid(Sdr_rd_en),.sdr_rd_data(Sdr_rd_dout),
    .tf_busy(tf_busy),.tf_wr_en(tf_app_wr_en),.tf_wr_addr(tf_app_wr_addr),.tf_wr_data(tf_app_wr_data),
    .fifo_used(thumb_fifo_used),.fifo_full(thumb_fifo_full),
    .hs(hs_0),.vs(vs_0),.de(de_0),.screen_x(thumb_x),.screen_y(thumb_y),.fifo_dout(video_read_data),
    .fifo_read(video_read_en),.hs_out(hs),.vs_out(vs),.de_out(de),.rgb(vout_data_raw),
    .fifo_reset(thumb_fifo_reset),.fifo_we(thumb_fifo_we),.fifo_data(thumb_fifo_data),
    .app_rd_en(App_rd_en),.app_rd_addr(App_rd_addr),.app_wr_en(App_wr_en),
    .app_wr_addr(App_wr_addr),.app_wr_data(App_wr_din),
    .active_mode(thumb_active),.active_slot(thumb_active_slot),.cover_commit(thumb_cover_commit),
    .bus_reserved(thumb_reserved),.ready_video(thumb_ready),.mode_busy(thumb_prefetch_busy),
    .build_busy(),.ui_busy(thumb_ui_busy),.cache_valid_video(thumb_valid),
    .prefetch_ready(),.fault(thumb_fault),.rebuild_ready(thumb_rebuild_ready),
    .rebuild_accepted(thumb_rebuild_accepted));

// 首图提交前黑屏；菜单显示第 0 张，各关卡以第 1 张起的照片为背景
assign vout_data = display_valid_v ? vout_data_brightness : 24'd0;

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .thumb_reserved(thumb_reserved),.tf_busy(tf_busy),
    .thumb_fifo_reset(thumb_fifo_reset),.thumb_fifo_we(thumb_fifo_we),
    .thumb_fifo_data(thumb_fifo_data),.thumb_fifo_used(thumb_fifo_used),.thumb_fifo_full(thumb_fifo_full),
    .rst               (rst_all),
    .write_abort_req   (write_abort_req),
    .write_abort_ack   (write_abort_ack),
    .write_overflow    (write_overflow),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (),
    .App_rd_addr       (),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (SLOT0_ADDR),
    .read_addr_1       (SLOT1_ADDR),
    .read_addr_2       (SLOT2_ADDR),
    .read_addr_3       (SLOT3_ADDR),
    .read_addr_4       (SLOT4_ADDR),
    .read_addr_5       (SLOT5_ADDR),
    .read_addr_index   (display_slot),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (tf_app_wr_en),
    .App_wr_addr       (tf_app_wr_addr),
    .App_wr_din        (tf_app_wr_data),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (SLOT0_ADDR),
    .write_addr_1      (SLOT1_ADDR),
    .write_addr_2      (SLOT2_ADDR),
    .write_addr_3      (SLOT3_ADDR),
    .write_addr_4      (SLOT4_ADDR),
    .write_addr_5      (SLOT5_ADDR),
    .write_addr_index  (load_slot),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// Global single-score BGM; no scene switching or extra storage.
wire bgm_pause_video, rec_tone_selected;
// Select from the committed display scene, not a key/request pulse.
// Register the decode before the existing single-bit audio-domain synchronizer.
// Cover changes retain song 0; all three levels share song 1.
reg bgm_song_video;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) bgm_song_video <= 1'b0;
    else bgm_song_video <= (level_v != 3'd0);
end
wire [23:0] bgm_tone_left, bgm_tone_right;
// ===================== 音频：内部 I2S 全局BGM =====================
hdmi_audio_tone_i2s_64fs #(
    .PHASE_INC (32'd39370534),
    .AMP       (24'sd2000000)
) u_hdmi_audio_tone_i2s_64fs (
    .I_mclk      (audio_mclk),
    .I_rst       (rst_audio),
    .I_song      (bgm_song_video),
    .I_pause     (bgm_pause_video),
    .O_i2s_BCLK  (audio_i2s_bclk),
    .O_i2s_LRCK  (audio_i2s_lrck),
    .O_i2s_DOUT  (audio_i2s_dout)
);

I2S_receiver u_I2S_receiver(
    .I_clk              (video_clk),
    .I_rst              (rst_video),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (audio_left_data),
    .O_audio_right_data (audio_right_data)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
osd_status_cdc u_osd_status_cdc(
    .src_clk    (sd_card_clk),
    .dst_clk    (video_clk),
    .rst        (rst_all),
    .src_status ({display_valid, 3'b000}),
    .dst_status (osd_status_video)
);

video_brightness u_video_brightness(
    .clk(video_clk), .rst_n(~rst_video), .vsync(vs),
    .rgb_in(vout_data_raw), .brightness(brightness),
    .rgb_out(vout_data_brightness)
);

assign vout_data_osd = vout_data;

// Board2 link capture stays in the 25 MHz video clock domain.
wire signed [23:0] mic_sample;
wire signed [15:0] mic_display_sample;
wire mic_sample_valid;
wire link_up;
wire [1:0] remote_phase, remote_code;
wire remote_have_result, remote_accepted, remote_error;
wire [2:0] remote_counter;
wire [13:0] remote_cost;
wire f0_valid;
wire [5:0] f0_code;
wire vowel_valid;
wire vowel_fresh;
wire [5:0] f1_bin;
wire [6:0] f2_bin;
wire spec_grp_valid;
wire [1:0] spec_seq;
wire [3:0] spec_grp;
wire [15:0] spec_mag;
board2_link_rx u_board2_link_rx(
    .clk(video_clk), .rst_n(~rst_video),
    .link_bclk(link_bclk), .link_ws(link_ws), .link_sd(link_sd),
    .sample_valid(mic_sample_valid), .sample_data(mic_sample),
    .link_up(link_up), .remote_phase(remote_phase),
    .remote_have_result(remote_have_result), .remote_code(remote_code),
    .remote_accepted(remote_accepted), .remote_error(remote_error),
    .remote_counter(remote_counter), .remote_cost(remote_cost),
    .f0_valid(f0_valid), .f0_code(f0_code),
    .vowel_valid(vowel_valid), .vowel_fresh(vowel_fresh), .f1_bin(f1_bin), .f2_bin(f2_bin),
    .spec_grp_valid(spec_grp_valid), .spec_seq(spec_seq), .spec_grp(spec_grp), .spec_mag(spec_mag)
);
inmp441_display_gain u_mic_gain(
    .sample_in(mic_sample), .sample_out(mic_display_sample)
);

promax_audio_waveform #(.DECIMATE(4)) u_audio_waveform(
    .clk            (video_clk),
    .rst_n          (~rst_video),
    .vsync          (vs),
    .de             (de),
    .rgb_in         (vout_data_osd),
    .enable         (osd_status_video[3] && !practice_view &&
                     level_v == 3'd1),
    .pcm_tap_valid  (mic_sample_valid),
    .pcm_tap_left   (mic_display_sample),
    .rgb_out        (vout_data_waveform),
    .waveform_active()
);

// Analyze the raw signed high 16 bits, before display gain and saturation.
wire [1:0] mic_volume_level;
wire [3:0] calibration_status;
wire calibration_short, calibration_long;
wire parameter_mode, select_threshold;
wire threshold_down, threshold_up;
wire [15:0] noise_floor, voice_reference, loud_threshold;
wire [15:0] current_energy, quiet_threshold;
// v35 noise gate: once calibrated (status 4), drop board-2 f0/vowel valid below quiet_threshold.
wire cal_ready   = (calibration_status == 4'd4);
wire noise_pass  = !cal_ready || (current_energy >= quiet_threshold);
wire f0_valid_g    = f0_valid    && noise_pass;
wire vowel_valid_g = vowel_valid && noise_pass;
wire vowel_display_valid = vowel_valid_g && link_up && vowel_fresh;
wire energy_valid, practice_start, practice_busy;
wire [2:0] practice_state;
wire [1:0] countdown_digit;
wire [12:0] practice_current_ms, practice_best_ms, practice_progress_ms;
wire [12:0] practice_elapsed_ms, practice_in_range_ms;
wire trace_tick;
wire [15:0] trace_energy;
wire [1:0] trace_class;
wire [6:0] review_read_index, review_read_height;
wire [1:0] review_read_class;
wire [1:0] review_feedback_code;
wire review_valid, previous_valid;
wire [12:0] previous_best_ms;
wire [6:0] current_percent, previous_percent;
wire practice_in_target, practice_success;
wire [15:0] target_low, target_high, target_reference;
wire [17:0] reference_triple = {2'b0, voice_reference} + {1'b0, voice_reference, 1'b0};
wire [15:0] practice_lower = quiet_threshold > reference_triple[17:2]
                           ? quiet_threshold : reference_triple[17:2];
wire interaction_locked = practice_busy || calibration_status == 4'd1 || calibration_status == 4'd3;
assign practice_view = calibration_status == 4'd4 && !parameter_mode && level_v == 3'd1;
wire practice_start_raw;
wire menu_period_press;
wire menu_navigation_hold;
assign practice_start = practice_start_raw & (level == 3'd1) & !carousel_busy && !thumb_owned;
parameter_controls u_parameter_controls(
    .clk(video_clk), .rst_n(~rst_video),
    .sw_mode(sw_param_mode), .sw_select(sw_param_select),
    .key_down_n(key1), .key_up_n(key2),
    .calibration_status(calibration_status),
    .interaction_locked(interaction_locked), .selector_owned(thumb_owned),
    .selector_active(thumb_active && !thumb_ui_busy && !thumb_flip), .practice_start(practice_start_raw),
    .next_press(menu_next_press), .prev_press(menu_prev_press), .confirm_press(menu_confirm_press),
    .period_press(menu_period_press),
    .navigation_hold(menu_navigation_hold),
    .mode(parameter_mode), .select_threshold(select_threshold),
    .brightness(brightness), .threshold_down(threshold_down),
    .threshold_up(threshold_up),
    .image_next_n(), .image_auto_n()
);
calibration_key u_calibration_key(
    .clk(video_clk), .rst_n(~rst_video), .key_n(thumb_key3_armed ? key_cal_n : 1'b1),
    .short_press(calibration_short), .long_press(calibration_long)
);
// KEY1 mode is held in the independent reference domain; synchronize its level.
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        auto_mode_meta <= 1'b0;
        auto_mode_video <= 1'b0;
    end else begin
        auto_mode_meta <= auto_mode_ref;
        auto_mode_video <= auto_mode_meta;
    end
end
// Same edge as the level_v latch below.
wire carousel_blinds_active;
wire carousel_frame_start = level_vs_q && !vs;
cover_carousel_ctrl u_cover_carousel_ctrl(
    .clk(video_clk), .rst_n(~rst_video),
    .frame_start(carousel_frame_start), .slot_valid(slot_valid_v),
    .auto_mode(auto_mode_video),
    .manual_hold(menu_navigation_hold),
    .selector_hold(thumb_owned),.selector_commit(thumb_cover_commit),.selector_slot(thumb_active_slot[1:0]),
    .next_press(menu_next_press && !thumb_owned), .prev_press(menu_prev_press && !thumb_owned), .confirm_press(menu_confirm_press && !thumb_owned),
    .period_press(menu_period_press && !thumb_owned),
    .back_long(calibration_long && !thumb_owned), .back_block(interaction_locked),
    .level(level), .display_slot(display_slot), .cover_idx(cover_idx),
    .alpha(carousel_alpha), .busy(carousel_busy),
    .blinds_active(carousel_blinds_active), .period_index(carousel_period_index)
);
// Display-side level changes only at frame start (same edge as pitch_line_overlay24).
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        level_vs_q <= 1'b1;
        level_v <= 3'd0;
    end else begin
        level_vs_q <= vs;
        if (level_vs_q && !vs)
            level_v <= level;
    end
end
// Calibration only in the loudness level; KEY3 short press re-measures noise once calibrated.
wire cal_allowed = (level == 3'd1) && !practice_busy && !carousel_busy;
personal_audio_meter u_personal_audio_meter(
    .clk(video_clk), .rst_n(~rst_video),
    .pcm_valid(mic_sample_valid), .pcm_sample($signed(mic_sample[23:8])),
    .short_press(calibration_short & cal_allowed),
    .long_press(calibration_short & cal_allowed & (calibration_status == 4'd4)),
    .threshold_down(threshold_down), .threshold_up(threshold_up),
    .level(mic_volume_level), .status(calibration_status),
    .noise_floor(noise_floor), .voice_reference(voice_reference),
    .loud_threshold(loud_threshold), .current_energy(current_energy),
    .quiet_threshold(quiet_threshold), .energy_valid(energy_valid)
);
voice_practice_controller u_voice_practice_controller(
    .clk(video_clk), .rst_n(~rst_video),
    .calibration_ready(calibration_status == 4'd4),
    .parameter_mode(parameter_mode), .start_press(practice_start),
    .audio_valid(energy_valid), .energy(current_energy),
    .reference_level(voice_reference), .low_threshold(practice_lower),
    .high_threshold(loud_threshold), .state(practice_state),
    .busy(practice_busy), .countdown_digit(countdown_digit),
    .current_ms(practice_current_ms), .best_ms(practice_best_ms),
    .progress_ms(practice_progress_ms), .in_target(practice_in_target),
    .result_success(practice_success), .target_low(target_low),
    .target_high(target_high), .target_reference(target_reference),
    .elapsed_ms(practice_elapsed_ms), .in_range_ms(practice_in_range_ms),
    .trace_tick(trace_tick), .trace_energy(trace_energy), .trace_class(trace_class)
);
practice_review_record u_practice_review_record(
    .clk(video_clk), .rst_n(~rst_video), .calibration_ready(calibration_status == 4'd4),
    .state(practice_state), .reference_level(voice_reference),
    .low_threshold(practice_lower), .high_threshold(loud_threshold),
    .best_ms(practice_best_ms), .in_range_ms(practice_in_range_ms),
    .elapsed_ms(practice_elapsed_ms), .trace_tick(trace_tick),
    .trace_energy(trace_energy), .trace_class(trace_class),
    .read_index(review_read_index), .read_height(review_read_height),
    .read_class(review_read_class), .point_count(), .result_valid(review_valid),
    .previous_valid(previous_valid), .previous_best_ms(previous_best_ms),
    .current_percent(current_percent), .previous_percent(previous_percent),
    .feedback_code(review_feedback_code)
);
audio_level_overlay24 u_audio_level_overlay(
    .clk(video_clk), .rst_n(~rst_video), .vsync(vs), .de(de),
    .rgb_in(vout_data_waveform),
    .enable(osd_status_video[3] && calibration_status == 4'd4 && !practice_view &&
            level_v == 3'd1),
    .level(mic_volume_level), .rgb_out(vout_data_level)
);

personal_status_overlay24 u_personal_status_overlay(
    .clk(video_clk), .rst_n(~rst_video), .vsync(vs), .de(de),
    .rgb_in(vout_data_level),
    .enable(osd_status_video[3] && !practice_view && level_v == 3'd1),
    .status(calibration_status), .mode(parameter_mode),
    .select_threshold(select_threshold), .brightness(brightness),
    .noise_floor(noise_floor), .voice_reference(voice_reference),
    .loud_threshold(loud_threshold), .rgb_out(vout_data_calibration)
);

sustain_game_overlay24 u_sustain_game_overlay(
    .clk(video_clk), .rst_n(~rst_video), .vsync(vs), .de(de),
    .rgb_in(vout_data_osd),
    .enable(osd_status_video[3] && practice_view && practice_state != 3'd5),
    .state(practice_state), .countdown_digit(countdown_digit),
    .energy(current_energy), .reference_level(target_reference),
    .target_low(target_low), .target_high(target_high),
    .current_ms(practice_current_ms), .best_ms(practice_best_ms),
    .progress_ms(practice_progress_ms), .elapsed_ms(practice_elapsed_ms),
    .in_target(practice_in_target),
    .result_success(practice_success), .rgb_out(vout_data_sustain),
    .l1_sub_en(l1_sub_en), .slot_en(l1_slot_en), .slot_id(l1_slot_id),
    .slot_cx(l1_slot_cx), .slot_cy(l1_slot_cy), .slot_kind(l1_slot_kind)
);

practice_review_overlay24 u_practice_review_overlay(
    .clk(video_clk), .rst_n(~rst_video), .vsync(vs), .de(de),
    .rgb_in(vout_data_osd),
    .enable(osd_status_video[3] && practice_view && practice_state == 3'd5),
    .result_valid(review_valid), .best_ms(practice_best_ms),
    .feedback_code(review_feedback_code),
    .current_percent(current_percent), .previous_valid(previous_valid),
    .previous_best_ms(previous_best_ms), .previous_percent(previous_percent),
    .reference_level(target_reference), .target_low(target_low), .target_high(target_high),
    .read_index(review_read_index), .read_height(review_read_height),
    .read_class(review_read_class), .rgb_out(vout_data_review)
);

assign link_ptt = 1'b0;

// Cover page: play (auto) / pause (manual) icon on the cover image.
mode_icon_overlay24 u_mode_icon_overlay(
    .clk(video_clk), .rst_n(~rst_video), .vsync(vs), .de(de),
    .rgb_in(vout_data_osd), .enable(osd_status_video[3] && level_v == 3'd0),
    .auto_mode(auto_mode_video), .period_index(carousel_period_index),
    .rgb_out(vout_data_menu)
);

// Tone level (v33): tone_game_core judges the 120-frame practice, tone_game_overlay24
// draws stage / stars / bird / curves over the plain background (0 clock latency), the
// shared subtitle engine below draws the top bar on top of it.
wire [1:0]  flow_stage;
wire        l2_pract, l2_target_blink;
wire [1:0]  l2_tone;
wire [8:0]  tg_bird_x, tg_bird_y;
wire [15:0] tg_rt_mask;
wire [7:0]  tg_nv;
wire        tg_trail_we;
wire [5:0]  tg_trail_idx;
wire [8:0]  tg_trail_y;
wire        tg_post_done, tg_unheard;
wire [7:0]  tg_seg_start, tg_L;
wire [9:0]  tg_s0;
wire [15:0] tg_hit_mask;
wire [4:0]  tg_hits;
wire [1:0]  tg_stars;
wire [6:0]  tg_score;
wire [3:0]  tg_kmax;
wire        tg_sign, tg_kmax_valid;
wire [8:0]  tg_curve_raddr, tg_curve_y;
wire [8:0]  tg_play_x;
wire        tg_play_on;
wire        tg_rec_go;      // core: first voiced practice frame seen (level)
wire        rec_play_busy;
wire [6:0]  rec_play_frame;
wire [23:0] rec_aud_l, rec_aud_r;
// Registered frame start (same as level_flow_ctrl's internal one).
reg tg_vs_q, tg_frame_start;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        tg_vs_q <= 1'b1;
        tg_frame_start <= 1'b0;
    end else begin
        tg_vs_q <= vs;
        tg_frame_start <= tg_vs_q && !vs;
    end
end
tone_game_core u_tone_game_core(
    .clk(video_clk), .rst_n(~rst_video), .frame_start(tg_frame_start),
    .pract(l2_pract), .tone(l2_tone),
    .f0_valid(f0_valid_g), .f0_code(f0_code),
    .bird_x(tg_bird_x), .bird_y(tg_bird_y), .rt_mask(tg_rt_mask), .nv(tg_nv),
    .trail_we(tg_trail_we), .trail_idx(tg_trail_idx), .trail_y(tg_trail_y),
    .post_done(tg_post_done), .unheard(tg_unheard), .seg_start(tg_seg_start), .L(tg_L),
    .s0(tg_s0), .hit_mask(tg_hit_mask), .hits(tg_hits), .stars(tg_stars), .score(tg_score),
    .kmax(tg_kmax), .sign(tg_sign), .kmax_valid(tg_kmax_valid),
    .curve_raddr(tg_curve_raddr), .curve_y(tg_curve_y),
    .play_f(rec_play_frame), .play_x(tg_play_x), .play_on(tg_play_on),
    .rec_go(tg_rec_go)
);
tone_game_overlay24 u_tone_game_overlay(
    .clk(video_clk), .rst_n(~rst_video), .vsync(vs), .de(de),
    .rgb_in(vout_data_osd), .enable(osd_status_video[3] && level_v == 3'd2),
    .stage(flow_stage), .tone(l2_tone), .target_blink(l2_target_blink),
    .play_busy(rec_play_busy),
    .bird_x(tg_bird_x), .bird_y(tg_bird_y), .rt_mask(tg_rt_mask), .nv(tg_nv),
    .trail_we(tg_trail_we), .trail_idx(tg_trail_idx), .trail_y(tg_trail_y),
    .post_done(tg_post_done), .unheard(tg_unheard), .seg_start(tg_seg_start), .L(tg_L),
    .s0(tg_s0), .hit_mask(tg_hit_mask), .hits(tg_hits), .stars(tg_stars), .score(tg_score),
    .kmax(tg_kmax), .sign(tg_sign), .kmax_valid(tg_kmax_valid),
    .curve_raddr(tg_curve_raddr), .curve_y(tg_curve_y),
    .play_x(tg_play_x), .play_on(tg_play_on),
    .rgb_out(vout_data_tone)
);

// Level 2/3 flow: target -> countdown -> practice -> result.
// KEY2/KEY4 pulses are only produced with SW1=0; ignore them during carousel fades.
wire [3:0]  flow_slot_en;
wire [19:0] flow_slot_id;
wire [39:0] flow_slot_cx;
wire [35:0] flow_slot_cy;
wire [11:0] flow_slot_kind;
wire        flow_subtitle_en;
wire        flow_target_en, flow_target_blink;
wire [2:0]  flow_target_id;
wire [5:0]  flow_hold_progress;
wire flow_hold_progress_en;
wire [1:0]  flow_hold_phase;

// Level 3 fault-tolerant hold & overlay parameters
localparam integer LV3_CLK_HZ           = 25_000_000;
localparam integer LV3_ENTER_RADIUS     = 2;
localparam integer LV3_KEEP_RADIUS      = 3;
localparam integer LV3_GRACE_MS         = 200;
localparam integer LV3_DECAY_MS_PER_MS  = 1;
localparam integer LV3_INVALID_CLEAR_MS = 750;
localparam integer LV3_HOLD_MS          = 3000;

level_flow_ctrl #(
    .CLK_HZ(LV3_CLK_HZ),
    .ENTER_RADIUS(LV3_ENTER_RADIUS),
    .KEEP_RADIUS(LV3_KEEP_RADIUS),
    .GRACE_MS(LV3_GRACE_MS),
    .DECAY_MS_PER_MS(LV3_DECAY_MS_PER_MS),
    .INVALID_CLEAR_MS(LV3_INVALID_CLEAR_MS),
    .HOLD_MS(LV3_HOLD_MS)
) u_level_flow_ctrl(
    .clk(video_clk), .rst_n(~rst_video), .vsync(vs),
    .level_v(level_v), .l2_enable(1'b1),
    .next_press(menu_next_press & !carousel_busy),
    .confirm_press(menu_confirm_press & !carousel_busy),
    .vowel_valid(vowel_valid_g), .f1_bin(f1_bin), .f2_bin(f2_bin),
    .link_up(link_up), .vowel_fresh(vowel_fresh),
    .f0_valid(f0_valid_g), .f0_code(f0_code),
    .l2_unheard(tg_unheard), .l2_stars(tg_stars), .l2_post_done(tg_post_done),
    .l2_play_busy(rec_play_busy),
    .slot_en(flow_slot_en), .slot_id(flow_slot_id), .slot_cx(flow_slot_cx),
    .slot_cy(flow_slot_cy), .slot_kind(flow_slot_kind),
    .subtitle_enable(flow_subtitle_en),
    .target_en(flow_target_en), .target_id(flow_target_id), .target_blink(flow_target_blink),
    .stage(flow_stage), .stars(),
    .hold_progress(flow_hold_progress), .hold_progress_en(flow_hold_progress_en),
    .hold_phase(flow_hold_phase),
    .l2_pract(l2_pract), .l2_tone(l2_tone), .l2_target_blink(l2_target_blink)
);

// Level 2: record the practice (mic, 8 kHz mu-law) and play it back on HDMI audio.
// v34: recording starts at the first voiced practice frame (core rec_go rising edge).
// KEY3 short press plays it in RESULT once the judge is done and the voice was heard
// (again = restart). Stop on leaving RESULT / level 2 and on KEY2 / KEY4.
// level (keys) and level_v (display / flow) are both video_clk; level_v follows level at
// the next frame start, so both must be 2. calibration_key is in video_clk as well.
reg  tg_rec_go_q;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) tg_rec_go_q <= 1'b0;
    else           tg_rec_go_q <= tg_rec_go;
end
wire l2_play_ctx = (level == 3'd2) && (level_v == 3'd2) && (flow_stage == 2'd3) && !carousel_busy;
wire l2_play_start = calibration_short && l2_play_ctx && tg_post_done && !tg_unheard;
wire l2_play_stop  = !l2_play_ctx || menu_next_press || menu_confirm_press;   // level, not a pulse
// Pause at the displayed countdown, through the whole practice window.
// Scope both controllers to the active/displayed level so stale states cannot
// mute a cover or another level. Keep capture/playback protection independent.
wire bgm_l1_practice_pause = (level == 3'd1) && (level_v == 3'd1) &&
    // The calibration page includes prompts, capture and retry states.
    // Status 4 is ready; keep BGM quiet until success or scene exit.
    ((calibration_status != 4'd4) ||
     (practice_state == 3'd3) || (practice_state == 3'd4));
wire bgm_l23_practice_pause =
    (((level == 3'd2) && (level_v == 3'd2)) ||
     ((level == 3'd3) && (level_v == 3'd3))) &&
    ((flow_stage == 2'd1) || (flow_stage == 2'd2));
// Register the state decode before it feeds the existing audio-domain CDC.
// This avoids a decode glitch when L1 COUNTDOWN (3) changes to PRACTICE (4).
// The extra video cycle is about 40 ns, ahead of the audible sample boundary.
reg bgm_practice_pause;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) bgm_practice_pause <= 1'b0;
    else bgm_practice_pause <= bgm_l1_practice_pause || bgm_l23_practice_pause;
end
bgm_record_guard u_bgm_record_guard(
    .I_capture(tg_rec_go || bgm_practice_pause), .I_play_start(l2_play_start),
    .I_play_busy(rec_play_busy), .I_tone_selected(rec_tone_selected),
    .I_left(audio_left_data), .I_right(audio_right_data),
    .O_pause(bgm_pause_video), .O_left(bgm_tone_left), .O_right(bgm_tone_right)
);
tone_audio_rec u_tone_audio_rec(
    .clk(video_clk), .rst_n(~rst_video),
    .rec_start(tg_rec_go && !tg_rec_go_q), .rec_en(tg_rec_go),
    .mic_valid(mic_sample_valid), .mic_sample(mic_sample),
    .play_start(l2_play_start), .play_stop(l2_play_stop), .frame_start(tg_frame_start),
    .aud_valid(audio_valid), .tone_l(bgm_tone_left), .tone_r(bgm_tone_right),
    .aud_l(rec_aud_l), .aud_r(rec_aud_r),
    .tone_selected(rec_tone_selected),
    .play_busy(rec_play_busy), .play_frame(rec_play_frame), .rec_len()
);

// Vowel level: F1/F2 vowel chart with six targets and the live formant point.
vowel_chart_overlay24 #(
    .ENTER_RADIUS(LV3_ENTER_RADIUS),
    .KEEP_RADIUS(LV3_KEEP_RADIUS)
) u_vowel_chart_overlay(
    .clk(video_clk), .rst_n(~rst_video), .vsync(vs), .de(de),
    .rgb_in(vout_data_osd), .enable(osd_status_video[3] && level_v == 3'd3),
    .vowel_valid(vowel_display_valid), .f1_bin(f1_bin), .f2_bin(f2_bin),
    .target_en(flow_target_en), .target_id(flow_target_id), .target_blink(flow_target_blink),
    .hold_progress(flow_hold_progress), .hold_progress_en(flow_hold_progress_en),
    .hold_phase(flow_hold_phase),
    .rgb_out(vout_data_vowel)
);

// Vowel level: spectrogram strip below the vowel chart.
spectrogram_overlay24 u_spectrogram_overlay(
    .clk(video_clk), .rst_n(~rst_video), .vsync(vs), .de(de),
    .rgb_in(vout_data_vowel), .enable(osd_status_video[3] && level_v == 3'd3),
    .spec_grp_valid(spec_grp_valid), .spec_seq(spec_seq), .spec_grp(spec_grp), .spec_mag(spec_mag),
    .rgb_out(vout_data_vowel_spec)
);

// Levels 1/2/3: pre-rendered subtitles (top bar), one shared engine. Level 3 on top of
// chart + spectrogram, level 2 on top of tone_game_overlay24, level 1 practice on top of
// sustain_game_overlay24 (combinational select).
wire [23:0] vout_data_vowel_sub;
subtitle_overlay24 u_subtitle_overlay(
    .shared_addr(subtitle_addr),.shared_meta_addr(subtitle_meta_addr),
    .shared_data(subtitle_data),.shared_meta_data(subtitle_meta_data),
    .clk(video_clk), .rst_n(~rst_video), .vsync(vs), .de(de),
    .rgb_in((level_v == 3'd2) ? vout_data_tone
          : (level_v == 3'd1) ? vout_data_sustain : vout_data_vowel_spec),
    .enable(osd_status_video[3] &&
            (((level_v == 3'd3 || level_v == 3'd2) && flow_subtitle_en) ||
             (level_v == 3'd1 && practice_view && practice_state != 3'd5 && l1_sub_en))),
    .slot_en(flow_slot_en | l1_slot_en), .slot_id(flow_slot_id | l1_slot_id),
    .slot_cx(flow_slot_cx | l1_slot_cx), .slot_cy(flow_slot_cy | l1_slot_cy),
    .slot_kind(flow_slot_kind | l1_slot_kind),
    .rgb_out(vout_data_vowel_sub)
);

// Only the review renderer delays pixels by one video clock. Register the other
// pages (incl. level 1 practice via the subtitle engine), page select, VSYNC and DE
// to that same pixel latency.
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        vout_data_plain_q <= 24'd0;
        display_vs_q <= 1'b1;
        display_de_q <= 1'b0;
        practice_view_q <= 1'b0;
        review_page_q <= 1'b0;
    end else begin
        vout_data_plain_q <= thumb_active ? vout_data
                           : (level_v == 3'd0) ? vout_data_menu
                           : (level_v == 3'd2) ? vout_data_vowel_sub
                           : (level_v == 3'd3) ? vout_data_vowel_sub
                           : (level_v == 3'd1 && practice_view) ? vout_data_vowel_sub
                           : vout_data_calibration;
        display_vs_q <= vs;
        display_de_q <= de;
        practice_view_q <= practice_view;
        review_page_q <= (practice_state == 3'd5);
    end
end
assign vout_data_selected = (practice_view_q && review_page_q) ? vout_data_review
                         : vout_data_plain_q;

// Cover blinds / original scene fade, using the final aligned pixel timing.
// Combinational RGB path: no extra RGB/DE/VS latency.
blinds_transition u_blinds_transition(
    .clk(video_clk), .rst_n(~rst_video),
    .vs(display_vs_q), .de(display_de_q),
    .rgb_in(vout_data_selected), .alpha(carousel_alpha),
    .blinds_active(carousel_blinds_active), .rgb_out(vout_data_faded)
);

video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (display_vs_q),
    .I_de          (display_de_q),
    .I_rgb         (vout_data_faded),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    // Original HDMI audio cadence; test tone, or the level-2 recording while it plays.
    .I_audio_left_data  (rec_aud_l),
    .I_audio_right_data (rec_aud_r),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
