阶段 0：64×64 TV-FISTA 浮点黄金参考模型
=======================================

本阶段目的
----------
建立后续 RTL 定点化和端到端仿真的统一软件参考，不修改原有 Vivado 工程。

运行环境
--------
Python 3.10+；依赖 numpy、Pillow、matplotlib。

运行命令（在本目录）
--------------------
python stage0_reference_64.py

固定实验参数
------------
图像：64×64，4096 像素
测量率：25%，1024 个 Hadamard 系数
变换：W = H_4096 / 64，Sylvester 自然序，图像按 row-major 展开
掩码：沿用原 Stage-1/2/3 的 low-sequency 生成规则，在 64×64 尺寸重新生成
TV：各向同性 TV，lambda=0.01
FISTA：外迭代 40 次，每次 TV Prox 内迭代 35 次

本次验收内容
------------
1. 64×64 正交归一化 FWHT 往返误差小于 1e-10。
2. 梯度/散度负伴随恒等式误差小于 1e-9。
3. 掩码恰好包含 1024 个位置。
4. 对 Stage-4 cat64 输入，重新计算的原始整数 FWHT 输入与 4096 个期望系数，
   必须与现有 fwht64_input.mem / fwht64_expected.mem 逐项完全一致。
5. 对 cat64、moon、rocket、text 四张 64×64 图像，生成 25% 直接重建与 TV-FISTA 结果，
   记录 PSNR 和软件运行时间。

输出文件
--------
stage0_reference_64/reference_report.txt       本阶段报告与验收结果
stage0_reference_64/metrics_64.csv              四张图像的指标
stage0_reference_64/reconstruction_64.png      原图、直接重建、TV-FISTA 对照图
stage0_reference_64/golden_vectors_cat64.npz    原图、掩码、系数和参考重建数组
stage0_reference_64/mask_64x64_rowmajor.txt    4096 位 row-major 测量掩码
stage0_reference_64/golden_measurements_1024_int32.hex
                                                1024 个已测整数未归一化系数

边界说明
--------
本阶段是 PC 浮点软件参考，不是 FPGA 执行结果，也不是实际光学采集。
导出的 1024 个十六进制测量值是 H_4096(image_u8) 的未归一化整数系数，
仅供下一阶段定义接口和定点缩放时使用；当前尚未冻结 FPGA 内部定点数值格式，
因此不得直接认定为最终 UART 协议或最终硬件算法数据格式。

Stage-4 的输入和期望向量在本次脚本运行中已逐项比对，均完全一致。
