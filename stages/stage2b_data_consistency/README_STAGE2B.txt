Stage-2B：4096 点数据一致性计算单元
=======================================

设计目标
--------
完成 FISTA 外层的一次数据一致性梯度步，不包含 TV Prox 或动量更新：
  c = (H_4096*z) >>> 6
  r[i] = mask[i] ? (c[i] - y[rank(i)]) : 0
  g = (H_4096*r) >>> 6
  v = z - g
这里 rank(i) 是按照升序排列的已测系数下标（0~1023）。
必须采用残差与伴随变换路径；不能使用浮点意义下等价、
但定点舍入次序不同的“直接替换测量系数后再做一次逆变换”路径。

复用与数据规格
--------------
- 原 Stage-4 fwht_inplace.v：保持不变；原 Stage-2A fwht_q11_stage2.v：保持不变。
- 4096 点 FWHT 原位计算，按顺序复用同一个核心两次。
- 输入 z：4096 个 signed Q5.11，16 bit。
- y：1024 个 signed S32.F11，32 bit，按 Stage-0.2 mask 的升序索引打包。
- BRAM：FWHT work (4096×32)、原图 z (4096×16)、测量 y (1024×32)、输出 (4096×16)。
- 固定 4096×1 mask_rom 从 Stage-0.2 的掩码文件初始化，不能替换为任意“前1024个系数”。
- 归一化 FWHT 结果保留 signed 32 bit；输出 v 为 signed 16 bit Q5.11。
- 流程控制：start / ready / busy / done、溢出标志 range_error、单地址同步结果读端口。

操作（Vivado 2019.2）
----------------------
1. 将整个 stage2b_data_consistency 解压到桌面 FPGA_MVP 总目录下。
2. 打开 Vivado 2019.2，Tcl Console：

   cd "<checkout>/stage2b_data_consistency"
   source ./create_vivado_project.tcl

3. Run Behavioral Simulation；在仿真窗口 Tcl Console 执行 run all。
4. 有四组测试：
   0. direct：z 是 25% 测量的直接重建图像，测量残差非零。
   1. original：z 是测量生成所用的定点原图，测量残差为零。
   2. perturbed：z 是在直接重建上施加小扰动的图像，测量残差非零。
   3. zero：z 全零，测试负残差与有符号截断。

5. 验收标准：
   PASS: case 0, 4096/4096, ...
   PASS: case 1, 4096/4096, ...
   PASS: case 2, 4096/4096, ...
   PASS: case 3, 4096/4096, ...
   PASS: mask=1024/4096; all 4 input sets and 16384 pixels exact
   ALL TESTS PASSED: Stage-2B data consistency RTL

6. 只有功能仿真通过后再做综合与布局布线，检查 BRAM 推断和 50MHz 内部时序。

验收证据建议
------------
FPGA_MVP/90_仿真日志与报告/Stage2B_DataConsistency/
  01_behavioral_simulation/stage2b_4cases_pass.png
  01_behavioral_simulation/stage2b_console.log
  02_synthesis/stage2b_utilization.rpt
  03_timing/stage2b_postroute_timing.rpt
只有通过验证的截图和报告才需要保存，不需要保存编译中途的界面。

边界
----
- 本包 RTL 是首版，未在此环境执行 Vivado/XSim。实际通过与否以本机 Vivado 为准。
- 这是独立计算 IP，没有 PS、UART、板级 pin XDC；不要生成 bitstream。
- 当前掩码固定编译为 ROM，测量值可通过 load 接口写入。后续若要支持
  动态测量掩码，需要扩展接口和存储管理，不属于本阶段。
- `range_error` 只检测残差和最终输出的定点存储溢出；
  不代替后续完整系统的端到端溢出与异常输入验证。
- source files 与 golden vectors 的出处由 data/golden_summary.json 和 scripts/validate_vectors.py 记录。
