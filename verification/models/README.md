# 显式厂商模型

system_models.sv、hdmi_ports.v 用于可移植的顶层编译。

它们替代sys/video/audio PLL、SDRAM、SD以及HDMI核/ODDR。当前run_checks只编译顶层，不运行这些模型，不证明厂商IP内部功能、硬件PLL或时序正确。独立TF/控制测试直接使用正式RTL，不依赖这些外围行为模型。
