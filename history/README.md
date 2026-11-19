# 早期原型（非当前主线）

`early_prototypes/` 保留原工程 `single_pixel/` 下四组独立实验：8-bit 输入 FWHT、逐像素 TV 梯度/散度、定点对偶投影和 8×8 TV Prox。它们的旧文件夹名并非当前 README 的阶段编号；例如旧 `stage5b_tv_proj` 不是现在的 Stage-5B UART 系统，旧 `stage5c_tv_prox` 也不是四图实板验收。

保留了能解释算法演进的 RTL、Testbench、约束、Tcl 和相应数值夹具。早期生成工具引用的图像/旧结果目录不一定随包分发；复现主线请以 `stages/` 为准。Stage-4A/4B/4C 自身更完整的改动记录保存在各自 `baseline_reference/`。
