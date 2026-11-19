Stage-2A：4096 点 Q5.11 FWHT 适配与验证
==========================================

本阶段目标
----------
复用原 Stage-4 的 fwht_inplace.v，不改动其蝶形地址、状态机和 BRAM 原位更新结构。
新增一个薄适配层，将 Stage-0.2 的 64x64 Q5.11 图像输入接入 32 位 FWHT 工作存储，
并在读取结果时执行 arithmetic >>> 6，得到 W = H_4096 / 64。

本阶段只验证：
1. Q5.11 输入符号扩展为 S32.F11；
2. 4096 点未归一化整数 FWHT；
3. 完整变换后算术右移 6 位；
4. 原始系数和归一化系数均与 Stage-0.2 黄金数据逐点匹配。

本阶段不实现：
- 1024 点测量投影控制；
- FWHT 伴随变换的数据调度；
- FISTA 外层迭代；
- TV Prox 集成；
- UART、AXI、PS/DDR、板级顶层及 bitstream。

目录
----
rtl/fwht_inplace.v           原 Stage-4 RTL，逐字节复用
rtl/fwht_q11_stage2.v        32 位 S32.F11 接口及 >>>6 归一化适配层
sim/tb_fwht_q11_stage2.v     4096 点 raw/norm 双重逐点比较
data/cat64_input_q11_s16.mem Stage-0.2 cat64 输入，signed Q5.11
data/cat64_fwht_raw_q11_s32.mem
data/cat64_fwht_normalized_q11_s32.mem
data/                        同时包含 Stage-2B 后续需要的掩码、测量和黄金向量

Vivado 2019.2 操作
------------------
1. 将整个 stage2_fwht_q11 文件夹放到 FPGA_MVP 下。
2. 打开 Vivado 2019.2，在 Tcl Console 执行：

   cd "<checkout>/stage2_fwht_q11"
   source ./create_vivado_project.tcl

3. Run Simulation -> Run Behavioral Simulation。
4. 在仿真 Tcl Console 执行 run all。
5. 预期看到：

   PASS: raw FWHT 4096/4096 exact, signed S32.F11
   PASS: normalized FWHT 4096/4096 exact, arithmetic >>> 6
   ALL TESTS PASSED: Stage-2A Q5.11 FWHT adapter

6. 通过后再运行综合，检查 BRAM 是否仍推断为 4 个 RAMB36 等效块，以及 LUT/FF/DSP。
7. 本阶段只做行为仿真和综合；不生成 bitstream、不上板。

时序/周期
---------
原 Stage-4 核心每个蝶形 4 个时钟：
  12 stages × 2048 butterflies × 4 clocks = 98,304 butterfly clocks。
加上状态控制开销后，以 XSim 实际 cycles 为准。
50 MHz 下纯蝶形周期约 1.966 ms。

数值规则
--------
- 输入图像：signed 16-bit Q5.11。
- 写入 FWHT 工作 RAM 前，必须符号扩展到 signed 32-bit S32.F11。
- 蝶形计算保持 32-bit，不在每级右移。
- 完成全部 12 级后，输出算术右移 6 位。
- 不做饱和或截断到 16-bit；归一化 FWHT 系数仍为 signed 32-bit。
- Python 负数 >> 6 为向负无穷取整，与 Verilog signed >>> 6 一致。

冻结边界
--------
原始 single_pixel/stage4_hw 工程保持不变。
本工程是独立 Stage-2A 验证工程。仿真未通过前，不进入 Stage-2B。
