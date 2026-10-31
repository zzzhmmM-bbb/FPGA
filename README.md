双 EG4S20BG256 FPGA 主从结构的 HDMI 多媒体交互系统。主板负责 TF 卡读图、SDRAM 帧缓存、图层叠加、HDMI 视频和音频输出以及交互；从板负责 INMP441 麦克风采集和语音特征提取（基频、共振峰、语谱），两板之间通过四线链路传输数据。

| 板 | 版本 | 工程 | bit |
|---|---|---|---|
| 主板 | T10b | `project/main/` | `bit/main/main_T10b_lv3fix.bit` |
| 从板 | v26 | `project/slave/` | `bit/slave/slave_v26_local.bit` |

两个 bit 都已上板验证，SHA256 见 `bit/SHA256SUMS.txt`。

## 目录

```
project/main/      主板工程（安路 TD 6.2.168116，顶层 top_tf_hdmi_audio.v）
  build.tcl                         主板构建脚本
  src/td_project/                   工程文件 .al、PLL/ROM IP、BGM 乐谱表
  src/user_source/hdl_source/       RTL（SD/ 读卡与帧缓存，thumbnail/ 缩略图，其余为三关、图层、音频）
  src/user_source/constraints_source/  引脚 pin.adc、时序 timing.sdc、局部布局 slot_local.adc
project/slave/     从板工程（顶层 board2_top.v，board2.al，pin.adc，timing.sdc）
bit/               两块板的 bit 与 SHA256
assets/tf_card/    TF 卡上的 6 张 640×480、24 bit BMP（3 张封面、3 张关卡背景）
tools/             构建脚本、可选的离线 TF 布局生成工具
build_reports/     主板 T10b 布局布线后的面积报告与时序报告
verification/      仿真测试（结构检查、定向仿真、T10/T10b 新增测试），说明见 verification/README.md
doc/mockup/        缩略图页位级参考模型 thumb_model.py；verification/t10/gen_vectors.py 用它生成期望值，
                   字库文件用 verification/assets/reference/compressed.mem
```

## 构建

需要安路 TD 6.2.168116（Windows）和 Python 3.9 及以上版本。TD 不支持带空格或中文的路径，Windows 下全路径还必须短于 260 个字符，所以请先把本目录复制到一个较短的英文路径下，例如 `D:\kjfs`。

1. 把 `tools/toolchain.example.json` 复制为 `tools/toolchain.json`，在 `td_commands` 里填写本机 `td_commands_prompt.exe` 的路径。
2. 在本目录下运行：
   - 主板：`python -B tools/build.py --board main`
   - 从板：`python -B tools/build.py --board slave`
   - 也可以用 PowerShell 运行 `tools/build.ps1 -Board main`。
3. 构建结果写在 `output/<板>/<时间戳>/`：
   - bit：主板是 `src/src/td_project/main_vowel_fixed.bit`，从板是 `src/slave_v26_local.bit`；
   - 日志、报告：同一目录下的 `build.log`、`result.json`；
   - 源目录不会被改动。

重新构建出的 bit 和交付的 bit 不一定逐字节相同（构建路径不同就会有差异），资源与时序应与 `build_reports/` 接近。主板布局对随机性比较敏感，每次构建后请检查全局 hold。

仿真检查：`python -B verification/run_checks.py`（需要 Icarus Verilog，可用 `--iverilog`、`--vvp` 指定路径）。

## 下载与运行

1. 两板分别供电，并且共地。板间连线如下：

   | 信号 | 方向 | 从板 P3 / FPGA 球号 | 主板 J1 / FPGA 球号 |
   |---|---|---|---|
   | LINK_BCLK | 从→主 | 5 / M10 | 1 / D14 |
   | LINK_WS | 从→主 | 6 / M11 | 2 / G11 |
   | LINK_SD | 从→主 | 7 / T9 | 3 / G12 |
   | PTT | 主→从 | 8 / P11 | 4 / F13 |
   | GND | 共地 | 12 | 12 或 30 |

   INMP441 接从板 N12（SCK）、L12（WS）、T13（SD）。排针上的 5 V 脚不要接到信号线上。
2. 主板插 TF 卡，接 HDMI 显示器（显示器需支持 HDMI 音频）。
3. 用安路下载工具分别给两块板加载对应的 bit。

## TF 卡

`assets/tf_card/` 中的 6 张 BMP 按文件名顺序对应槽位 0–5。主板上电后先解析 FAT32，定位到数据区，再按簇查找 BMP 文件头；FAT32 解析失败，或者一张图都没找到时，会回退为从 1 号扇区起逐扇区扫描。主板按发现的先后顺序取前 6 张，并要求每张图连续存放。

把卡快速格式化为 FAT32 后按 00→05 顺序依次复制 6 张图，一般能满足"从簇边界开始、连续存放"的要求，但本包没有用这种方式做实卡验证；如果开机缺图，请改用逐扇区连续写入的方式。

`python -B tools/make_tf_layout.py` 会在 `output/tf_layout/` 下生成一个裸扇区布局的 `.img` 文件，仅供离线参考。这个工具不会访问任何磁盘。

## 按键（主板）

| 按键 | 功能 |
|---|---|
| KEY1 | 短按复位；长按约 2 s 切换自动/手动轮播 |
| KEY2 | 下一张封面、换训练目标；在封面上长按为上一张 |
| KEY3 | 第一关短按为校准；第二关结果页短按回放录音；任意关卡长按约 2 s 返回封面 |
| KEY4 | 确认、进入、开始；在封面上长按循环切换 4/8/12 s 轮播周期 |
| SW1 / SW2 | 参数模式开关 / 选择调亮度或门限 |
| SW3 | 在空闲封面翻转，进入或退出三卡缩略图选择页 |

## 资源与时序（主板 T10b，来自 build_reports/）

| 项 | 值 |
|---|---|
| LUT | 17945 / 19600（91.6%） |
| 寄存器 | 8796 / 19600 |
| BRAM9K / BRAM32K | 64/64、16/16 |
| DSP | 15 / 29 |
| 全局 SWNS / HWNS | −6.699 ns / −0.020 ns |

时序没有完全收敛。全局 SWNS 来自 SDRAM 180° 相移时钟的接口路径。
