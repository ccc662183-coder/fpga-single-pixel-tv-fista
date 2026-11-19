阶段 1：64×64 BRAM 版 TV Prox
================================

本阶段目标
----------
把原 Stage-5C 的 8×8 触发器数组演示模块扩展为 64×64 BRAM 存储结构，
实现完整 35 次 Jacobi 对偶迭代，并与阶段 0.2 的 Python 整数模型逐像素比较。

本阶段不包含：
- FWHT 与测量一致性更新
- FISTA 40 轮外迭代
- UART / NanoDAP
- PS / DDR3 / AXI
- 板级顶层及管脚约束

关键规格
--------
图像：64×64，4096 点，row-major
输入/输出：signed Q5.11，16 bit
TV：各向同性投影
lambda：20/2048
TV 内迭代：35 次
更新：Jacobi（先写 pn_x/pn_y，整幅图完成后再 commit）
BRAM：f/u/px/py/pnx/pny 六个单口同步 RAM + 一个输出简单双口 RAM
预计存储量：7 × 4096 × 16 = 458,752 bit，约 14 个 RAMB36 等效块

已有基础
--------
tv_dual_project_q11.v 直接复用交接包 Stage-5C 已通过向量验证的投影模块。
输入和期望输出由阶段 0.2 的 tv_prox_q11(direct_q11, steps=35) 生成。
参考输入范围：[76, 1565]
参考输出范围：[107, 1530]
参考输出总和：3926432
本次输入来自 cat64 的 25% Hadamard 直接重建初始化结果。

运行方式（Vivado 2019.2）
-------------------------
1. 解压整个 stage1_tv_prox64 目录。
2. Vivado Tcl Console 执行：

   cd "<解压路径>/stage1_tv_prox64"
   source ./create_vivado_project.tcl

3. Run Behavioral Simulation，运行 run all。
4. 等待完整测试结束，必须看到：

   PASS: 64x64 BRAM TV Prox, all 4096 pixels match
   PASS: 35 Jacobi dual iterations, Q5.11 arithmetic
   ALL TESTS PASSED: Stage-1 64x64 BRAM TV Prox

5. 仿真通过后再运行 Synthesis，查看 RAMB36/RAMB18、LUT、FF、DSP。
   预期存储结构约为 14 个 RAMB36 等效块；如果大部分数组被综合成 FF/LUTRAM，
   不要继续，先检查 BRAM 推断。

预计仿真工作量
--------------
约 1,600 万至 2,000 万个时钟周期（取决于投影是否进入快速路径）。
测试平台设置 25,000,000 周期保护上限和 500 ms 仿真时间保护。

重要说明
--------
- 本包 RTL 是首版 BRAM 架构，必须以本机 Vivado 2019.2 仿真结果为准。
- 目前没有在此环境运行 Vivado/XSim，不能预先宣称 RTL 仿真通过。
- 首次只做行为仿真，不要先跑实现或上板。
- 本工程是独立 IP 验证工程，不要覆盖交接包中 Stage-4/5A/5B/5C 原工程。
- 如果出现 MISMATCH、综合不推断 BRAM、或超时，请保存首条错误和完整日志发回。
