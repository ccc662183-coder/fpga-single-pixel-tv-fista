Stage-4C：TV Prox BRAM 预取与计算状态重叠（第一版）
====================================================

Stage-4B 已冻结且用户实测：
- 1轮集成仿真：6,992,025 cycles，4096/4096 完全匹配。
- 40轮集成仿真：260,622,701 cycles，4096/4096 完全匹配。
- 50MHz post-route：LUT 4231, FF 967, BRAM Tile 25, DSP 4；WNS +7.562ns，WHS +0.105ns。

Stage-4C 改动（仅 rtl/tv_prox64_bram_q11.v）：
1. U 更新阶段：在 S_U_WRITE 写入 u[i] 的同时，从独立的
   f_mem、px_mem、py_mem 同步预取地址 i+1。
2. 下一像素直接进入 S_U_READ_PREV（无须再次 S_U_READ_CUR）。
3. 在 S_U_CAPTURE_PREV 当拍从 BRAM 同步读数据计算精确的 18-bit
   signed divergence；乘以20、算术 >>>11 改为 S_U_WRITE 的组合路径。
4. 最终输出阶段 S_F_* 采用相同的预取与状态合并。
5. 不改变 35 次 Jacobi 内循环、BRAM bank 数量、投影计算模块、
   FWHT/FISTA、Q5.11截断规则、每个向量的黄金数据。

U 和最终 F 从 6 cycles/pixel 降至近 3 cycles/pixel；每趟扫描
第0个像素需多1周期作为启动预取。单次 TV Prox 35次 U 扫描 + 1次 F：
理论减少 3×4096×(35+1) − 36 = 442,332 cycles。
按用户 Stage-4B 集成基线推算：
- 一轮 FISTA：6,992,025 − 442,332 = 6,549,693 cycles
- 40轮 FISTA：260,622,701 − 40×442,332 = 242,929,421 cycles
这都是理论周期预测，不是 Stage-4C RTL 实测结果。

文件目录：
- rtl/：完整 Stage-4B RTL；仅 tv_prox64_bram_q11.v 做功能修改。
- baseline_reference/tv_prox64_bram_q11_stage4b.v.orig：冻结原版。
- baseline_reference/stage4c_only_change.patch：逐行差异。
- sim/tv_prox64_bram_q11_reference.v：仅仿真使用的原版模块（改模块名）。
- sim/tb_tv_prox_stage4c_ab.v：原版/新版 35 次 TV Prox 并行 A/B 检验。
- sim/tb_fista_top_q11.v：单轮 / 完整40轮 TV-FISTA 黄金数据验收。
- data/input_f_q11.mem 与 expected_prox_q11.mem：Stage-1 35轮独立黄金向量。
- data/：其余为 Stage-4B 原始定点测量值、beta ROM 和黄金输出。
- scripts/verify_prefetch_schedule.py：PC软件侧 BRAM 时序预取模型检查。
- constraints/stage4c_50mhz.xdc：50 MHz 独立计算IP核心时钟约束。
- create_vivado_project.tcl：创建 Vivado 2019.2 新工程。

第一步：Vivado 2019.2 -> Tcl Console（请另建独立目录，勿覆盖Stage-4B）：
    cd "<checkout>/stage4c_memory_overlap"
    source ./create_vivado_project.tcl
    launch_simulation -simset sim_1 -mode behavioral
    run all

默认 tb_tv_prox_stage4c_ab，预期：
    PASS: Stage-4C vs frozen Stage-4B TV Prox 4096/4096 bit-exact
    PASS: Stage-1 independent golden 4096/4096 bit-exact
    PASS: A/B cycles baseline=... optimized=... saved=442332
    ALL TESTS PASSED: Stage-4C BRAM prefetch and state-overlap A/B

第二步（仅第一步通过后）：一轮完整系统。
    close_sim
    set_property top tb_fista_top_q11_one_iter [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    run all
预期：4096/4096、range_error=0、protocol_error=0、输出范围[108,1530]、
总和3930561、周期<6992025（理论6549693）。

第三步：综合 + 布局布线 50MHz 时序，检查 WNS/WHS/TNS/THS、
LUT/FF/BRAM/DSP。预取和组合乘法可能导致新的关键路径；
如果 WNS<0 或 WHS<0，不能宣称 Stage-4C 通过。

第四步（上述通过后再做）：可选 40轮完整仿真，确认最终结果
范围 [81,1526]、总和 3930589、4096/4096 精确匹配；
预期理论周期 242929421，实际以 XSim 为准。

重要：本环境没有 Vivado/XSim，尚未验证新 RTL 的实际正确性、
综合资源和布线时序。所有“预期周期”只是状态机循环计算。
这是实验候选版，Stage-4B 全部保持不变。
