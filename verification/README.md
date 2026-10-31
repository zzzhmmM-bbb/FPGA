# 可运行检查

从包根运行 `python -B verification/run_checks.py`。若Icarus不在PATH，用 `--iverilog` 和 `--vvp` 指定两个可执行文件；不安装任何工具。

当前脚本检查所有正式工程直接引用以及文本include/readmem依赖，执行主从顶层编译（显式厂商PLL/IP模型）与四组定向仿真：

| 测试 | 判据 |
|---|---|
| TF尾保护 | 256字TF写后接纳视频读间隔至少10拍，要求 `PASS_TF_TAIL_GUARD` |
| admission | 最终素材掩码、背压、单次准入、空图、共复位，要求 `PASS admission` |
| controls | SW3稳定翻转、选择器所有权、正反移焦、退出提交等，要求 `PASS controls` |
| key1 | 长按抑制与短复位独立，要求 `PASS key1` |

结果和完整命令日志写 `output/verification/`，源目录不生成vvp。缺测试/依赖为失败；缺Icarus为incomplete，返回2，不能当仿真PASS。编译顶层使用 `models/` 的显式替代模型，不执行其中SD/SDRAM/HDMI的行为模型，也不证明加密IP内部或物理时序正确。整机 81 帧回归不在本目录内。

`assets/` 的字幕/压缩ROM由冻结的SUB_INIT_B/SHR_INIT_B直接按每16位一字还原，来源与哈希在provenance.json。没有重新生成字体或改生产ROM。

根目录中旧 `vendor_stubs.v`、`system_models.sv`、`hdmi_ports.v` 保留为首版携带的参考副本，当前runner仅采用 `models/` 中明确列出的文件；参考副本不代表额外测试已经执行。
