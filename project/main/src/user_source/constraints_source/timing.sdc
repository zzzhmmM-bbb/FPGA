
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 增加 hdmi_5x_clk / audio_mclk 的命名
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径按当前工程实例名写：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#      音频 PLL     -> u_audio_pll
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {audio_mclk}  -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_pll/pll_inst.clkc[2]}]

# ------------------------------------------------------------
# 4. 从原 timing(2).sdc 迁移过来的 HDMI 像素/串行时钟约束
#
#    原文件是：
#      create_clock -name pixel_clk  ... [get_nets {S_pixel_clk}]
#      create_clock -name serial_clk ... [get_nets {S_serial_clk}]
#      set_clock_groups -exclusive ...
#
#    在整合工程里，这两个时钟已经由 video_pll 产生，并通过 derive_clocks 建出来了，
#    所以这里只保留“组关系”，不再重复 create_clock。
#
#    这里沿用原例程的写法，把 video_clk 和 hdmi_5x_clk 设成 exclusive。
#    如果后面 Timing Analyzer 明确显示两者之间需要做同步时序分析，再把这一条去掉。
# ------------------------------------------------------------
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 5. 音频 I2S 发生器/接收器跨域
#
#    audio_mclk 域里生成 I2S，video_clk 域里做三拍同步采样。
#    这类路径不是普通同步时序路径，直接切掉更合理。
# ------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks {audio_mclk}] \
    -group [get_clocks {video_clk} hdmi_5x_clk sd_card_clk ext_mem_clk]

# ------------------------------------------------------------
# 6. 可选：如果 frame_read_write 内部异步 FIFO 已经完全处理好了跨域，
#    且报告里总出现 video_clk / sd_card_clk / ext_mem_clk 之间的大量伪违例，
#    可以打开下面这组异步分组。
#
#    建议先不要开，先看报告；
#    只有确认这些跨域都只经过 FIFO / 同步器时再开。
# ------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks {sd_card_clk}] \
#     -group [get_clocks {ext_mem_clk}] \
#     -group [get_clocks {video_clk}] \
#     -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 6b. 逐条 CDC 约束（T10）：只针对已核对 RTL 的同步器第一级
#     -datapath_only 配合 -from 时 TD 自动对 hold 做 false path
#     （SWUG200 3.11.3），setup 仍按目标时钟周期限制线延迟。
#     不打开上面整组 asynchronous；异步 FIFO 格雷码路径不在此列。
# ------------------------------------------------------------
# osd_status_cdc.v:42,49 ack_toggle(video) -> :19,29 ack_sync1(sd) 2FF 第一级
set_max_delay -datapath_only -from [get_clocks {video_clk}] -to [get_regs {u_osd_status_cdc/ack_sync1}] 10
# thumbnail_mode_commit.v:29,64 req_toggle(video) -> :68,87 req_sync[0](mem) 2FF 第一级
set_max_delay -datapath_only -from [get_clocks {video_clk}] -to [get_regs {u_thumbnail_datapath/mode/req_sync[0]}] 8
# thumbnail_mode_commit.v:32,59-63 payload_mode/payload_slot(video) 仅在无未完成握手时随 req_toggle 翻转更新；
# mem 侧 :99-104 在 req_sync[1] 变化后经 DRAIN/CLEAR(8)/RECOVER(20) 才采样，ack 回传(:107)前源端不再变
set_max_delay -datapath_only -from [get_regs {u_thumbnail_datapath/mode/payload_mode u_thumbnail_datapath/mode/payload_slot[0] u_thumbnail_datapath/mode/payload_slot[1] u_thumbnail_datapath/mode/payload_slot[2]}] -to [get_clocks {ext_mem_clk}] 8
# thumbnail_rebuild_guard.v:17,34 revoke_ack(video) -> :18,42 ack_m[0](mem) 2FF 第一级
set_max_delay -datapath_only -from [get_clocks {video_clk}] -to [get_regs {u_thumbnail_datapath/guard/ack_m[0]}] 8
# cdc_payload_mailbox.v:9,25 ack(video) -> :10,16 ack_sync[0](mem) 2FF 第一级
set_max_delay -datapath_only -from [get_clocks {video_clk}] -to [get_regs {u_thumbnail_datapath/guard/status/ack_sync[0]}] 8
# key1_mode_control.v:21,28 inhibit_sync[0](clk, async_reg) 2FF 第一级；源 thumb_owned 为组合 OR
set_max_delay -datapath_only -from [get_clocks {video_clk}] -to [get_regs {u_key1_mode_control/inhibit_sync[0]}] 20

# ------------------------------------------------------------
# 7. 其余 Input/Output delay 先保持空白
#    原有的两个 sdc 也都没有写这部分。
# ------------------------------------------------------------
