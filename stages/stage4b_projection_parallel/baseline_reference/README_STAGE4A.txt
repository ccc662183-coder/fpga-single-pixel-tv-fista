Stage-4A: TV-Prox 除以 5 运算加速（首次性能优化）
================================================

基线
----
原 Stage-3：cat64、40轮 FISTA、35次 TV 内迭代，4096/4096 精确匹配。
原计算周期：560,631,327 cycles；50MHz 时约11.2126秒。
原布局布线：LUT 3716, FF 900, BRAM Tile 25, DSP 4；WNS +8.251ns，WHS +0.089ns。
这些是用户在 Vivado 2019.2 上已经验证过的 Stage-3 历史结果，不是 Stage-4A 实测。

本阶段优化范围
--------------
只修改 rtl/tv_prox64_bram_q11.v 的 S_DIV_RUN 中除以5的串行计算器。
原操作：gradient *64 /5，两个方向并行，每周期分别处理1位，24个周期。
新操作：两个方向并行，每周期分别处理4位，6个周期。
4个 restoring-division 子步骤合并为一个组合路径，整数商和余数完全等价。

保持不变的内容
--------------
- 4096点 FWHT、测量一致性、FISTA 顶层和所有 BRAM 封装
- TV 梯度/散度、lambda=20/2048、投影、Jacobi 双缓冲
- 64×64、1024 测量、40次 FISTA 外迭代、35次 TV 内迭代
- Q5.11 与 S32.F11 格式及所有 Python 黄金数据

文件说明
--------
rtl/：完整可综合 Stage-3 RTL ；仅 tv_prox64_bram_q11.v 发生功能改动
sim/tb_fista_top_q11.v：沿用上一周已通过的干净版 Testbench，
    增加优化后计算周期必须小于 Stage-3 基线的检查
data/：与 Stage-3 完全相同的 cat64 黄金测试向量、掩码和系数 ROM
baseline_reference/：原 Stage-3 TV Prox 源码及唯一差异补丁
scripts/verify_radix16_div5.py：在 PC 上穷举全部262144种18位幅值，验证除法商/余数
create_vivado_project.tcl：在本目录自动建立新的独立 Vivado 工程
constraints/stage4a_50mhz.xdc：50MHz 内部时钟基线

建议操作顺序
------------
A. PC侧轻量自检（可选，但很快）：
    python scripts/verify_radix16_div5.py
    预期输出：[PASS] 262144/262144 ...

B. Vivado 2019.2，Tcl Console：
    cd "<checkout>/stage4a_tv_div5_optimized"
    source ./create_vivado_project.tcl

C. Behavioral Simulation -> run all.
默认 sim top = tb_fista_top_q11_one_iter。
必须看到：
    PASS: output pixels 4096/4096 exact; errors=0
    PASS: Stage-4A accelerated TV division; compute cycles=...
    ALL TESTS PASSED: Stage-3 TV-FISTA top-level integration

预期（理论推算，不是实测）：
    Stage-3 1轮 15,102,027 cycles -> Stage-4A 12,521,547 cycles
    Stage-3 40轮 560,631,327 cycles -> Stage-4A 457,412,127 cycles
    50MHz下完整40轮约从11.2126秒减少到9.1482秒（约18.4%延迟下降）。
    具体以 XSim 实测 cycles 为准。

D. 单轮仿真通过后，运行综合、布局布线。
    重点检查：
      WNS >= 0, TNS=0, WHS >= 0, THS=0
      BRAM Tile 是否仍维持约25个
      LUT/FF/DSP 相比 Stage-3 的变化
    不满足时序时，应回退/调整，不可宣称“加速成功”。

E. 如果单轮、综合、布局布线都通过，再验证完整40轮：
    close_sim
    set_property top tb_fista_top_q11_full [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    run all

验收优先级
----------
1) 正确性不退化：4096/4096 像素 bit-exact
2) 周期减少：加速效果必须可量化
3) 时序不退化到无法运行：完成 post-route 50MHz 验证
4) 资源合理：对比 LUT FF BRAM DSP

风险与边界
----------
本机没有 Vivado/XSim，故尚未对优化 RTL 进行 XSim 或布局布线验证；
“理论加速”不是实际测得的性能。
原 Stage-3 的所有文件未被覆盖。
输入输出接口仍是独立计算 IP，不是最终 AX7020 板级 top。
仿真仅 cat64；按此前约定不做四张图像的完整 RTL 仿真。
