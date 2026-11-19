阶段 0.2：64×64 TV-FISTA 定点黄金参考模型
==========================================

目的
----
把阶段 0.1 的 64×64 浮点参考算法转成与现有 Stage-4/5B/5C RTL 数值规则一致的整数参考模型。
本阶段仍在 PC 上运行，不需要打开 Vivado，也不代表 FPGA 已经完成 64×64 TV-FISTA。

运行环境
--------
Python 3.10+
依赖：numpy、Pillow、matplotlib
（matplotlib 是随附的 Stage-0.1 浮点参考脚本的依赖。）

运行命令
--------
在解压目录 single_pixel 中运行：

    python stage0_2_fixedpoint.py

固定算法参数
------------
图像：64×64，4096 像素
测量数：1024，测量率 25%
变换：W = H_4096 / 64
Hadamard 顺序：Sylvester 自然序；图像按 row-major 展开
测量掩码：与 Stage-0.1 完全相同的 low-sequency 掩码
FISTA 外迭代：40 次
TV Prox 内迭代：35 次
TV：各向同性 TV

拟定定点数值规范（本阶段验证通过后再冻结）
--------------------------------------------
1. 图像、FISTA 状态 x/z、TV 对偶变量 p/q：
   signed 16-bit，11 个小数位，即 Q5.11；1.0 对应整数 2048。
   数值范围 [-16, 15.99951171875]。

2. FWHT 工作存储、归一化系数、测量值、残差：
   signed 32-bit，11 个小数位（S32.F11）。
   FWHT 执行未归一化 H_4096，变换后 arithmetic >>> 6，得到 H/64。
   测量值按 mask 的 row-major 位置升序排列。

3. TV divergence / gradient：
   至少 signed 18-bit，11 个小数位；脚本会检查 18-bit 范围。
   TV u/f 与对偶变量仍使用 signed 16-bit Q5.11。

4. TV lambda：
   采用现有 Stage-5C RTL 的整数常数 20，即 20/2048=0.009765625。
   Stage-0.1 浮点参考使用 0.01；两者差异在报告中明确记录。

5. TV 更新舍入规则：
   u = f + ((div * 20) >>> 11)，负数算术右移按向负无穷取整。
   对偶梯度增量为 sign(grad) * floor(abs(grad)*64/5)，即向零截断。
   投影使用整数 floor sqrt，分量商采用正幅值四舍五入。

6. FISTA 动量：
   beta_k=(t_(k-1)-1)/t_k 预先计算为 16-bit unsigned、15 个小数位。
   RTL 乘法结果 arithmetic >>> 15。

7. 输入 uint8 灰度转 Q5.11：
   round(pixel*2048/255)，使用 (pixel*2048+127)//255。

8. 最终输出裁剪到 [0, 2048]，即 [0,1]。

本阶段验收内容
----------------
- 原 Stage-4 4096 点整数 FWHT 参考向量：4096/4096 完全匹配。
- 原 Stage-5B Q5.11 投影向量：128/128 完全匹配。
- 原 Stage-5C 8×8、3 次内迭代向量：64/64 完全匹配。
- 四张 64×64 图像完成 40×35 次迭代。
- 检查 32-bit FWHT、18-bit TV 中间量、16-bit Q5.11 状态是否溢出。
- 比较定点模型与 Stage-0.1 浮点模型的 PSNR 和逐像素误差。

主要输出
--------
stage0_2_fixedpoint/fixedpoint_report.txt
stage0_2_fixedpoint/metrics_fixedpoint.csv
stage0_2_fixedpoint/*_fixedpoint_comparison.png
stage0_2_fixedpoint/data/numeric_contract.vh
stage0_2_fixedpoint/data/mask_4096_rowmajor.mem
stage0_2_fixedpoint/data/measurement_indices_1024.txt
stage0_2_fixedpoint/data/fista_beta_q15.hex
stage0_2_fixedpoint/data/cat64_measurements_q11_s32.hex
stage0_2_fixedpoint/data/cat64_direct_q11_s16.hex
stage0_2_fixedpoint/data/cat64_tv_fista_q11_s16.hex
stage0_2_fixedpoint/vectors/<image>/golden_vectors.npz

HEX 文件约定
------------
每行一个数，按二进制补码编码。
*_s16.hex：16-bit signed Q5.11。
*_s32.hex：32-bit signed、11 个小数位。
measurement 文件只包含 1024 个已测系数，按 row-major 展平索引升序排列。
图像像素向量按 row-major 顺序展开。

重要边界
--------
- 这只是 PC 定点参考，不是 RTL 仿真或 FPGA 上板结果。
- numeric_contract.vh 是拟定参数文件；先运行并核对本阶段结果，再将其冻结为正式接口规范。
- Stage-4 原有 8-bit 灰度测试向量仍保留，作为旧 FWHT 核兼容性检查；新 TV-FISTA 算法路径使用 Q5.11 图像输入。
- 当前尚未实现 64×64 BRAM TV Prox RTL、FISTA RTL、UART 或顶层系统。
