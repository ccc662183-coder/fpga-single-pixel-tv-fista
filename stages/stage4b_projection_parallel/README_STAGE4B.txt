Stage-4B：TV Prox 投影单元并行除法加速（独立于正在运行的 Stage-4A 仿真）
=======================================================================

一、工作目标
-----------
当前 Stage-4A 一轮 FISTA 仿真已经通过：12,521,547 cycles，4096/4096 匹配。
用户当前正在另一个 Vivado 工程运行 Stage-4A 完整40轮仿真；本工程不会覆盖它。

查看 RTL 可知，tv_dual_project_q11.v 在超出单位圆时采用：
  16 次 SQRT + 27 次 DIVX + 27 次 DIVY，另有 setup/finish 状态。
原实现的 DIVX/DIVY 依次处理，除法累计54个时钟。

本版保持 SQRT 的16周期整数算法完全不变，把 X/Y 两路整数除法
同步启动、并行计算；每路除法每周期消耗3位，共9个周期。
每次执行慢速投影相对 Stage-4A 可减少46个周期（两路 setup 节点合并）。
在快通道（vx^2+vy^2<=2048^2）保持原行为和原周期。

本版不修改：
  Stage-4A 的加速 /5 TV 更新；TV Jacobi 35 次内迭代；FWHT；
  FISTA 外迭代/参数；50MHz 时钟；黄金测试数据及 Q5.11 规范。

二、文件结构
-----------
  rtl/tv_dual_project_q11.v            仅有的 Stage-4B 核心功能修改
  rtl/                                Stage-4A 全部其余 RTL 复制
  sim/tv_dual_project_q11_reference.v  Stage-4A 原投影源，模块重命名
  sim/tb_tv_dual_project_stage4b.v     2048 组 A/B 独立对比测试
  sim/tb_fista_top_q11.v               cat64 全系统单轮/40轮黄金对照
  data/                                原 golden、mask、beta ROM
  scripts/verify_parallel_radix8.py    PC端 100000 组整数运算等价自检
  baseline_reference/                 Stage-4A 原投影源码、差异补丁
  create_vivado_project.tcl           独立新建 Vivado2019.2 工程
  constraints/stage4b_50mhz.xdc       50MHz 内部时钟约束

三、推荐验证顺序（**不需要先等 Stage-4A 40轮结束**）
-----------------------------------------------------
不要覆盖 stage4a_tv_div5_optimized，保持其 XSim 继续运行。

1) 在另一个 Vivado 2019.2 实例打开 Stage-4B（注意电脑资源）；
   或者保存本包，待已有 XSim 完成再运行以避免抢内存。

   cd "<checkout>/stage4b_projection_parallel"
   source ./create_vivado_project.tcl

2) 第一次运行默认短 Testbench：
   run all
   预期：
   PASS: Stage-4B projection A/B exact 2048/2048 cases, errors=0
   ALL TESTS PASSED: Stage-4B projection radix-8 parallel divider

3) 切换到完整 FISTA 的一轮集成测试：
   close_sim
   set_property top tb_fista_top_q11_one_iter [get_filesets sim_1]
   update_compile_order -fileset sim_1
   launch_simulation -simset sim_1 -mode behavioral
   run all

   必须看到：
   PASS: Stage-4B TV projection acceleration; compute cycles=...
   PASS: output pixels 4096/4096 exact; errors=0
   PASS: range_error=0, protocol_error=0
   ALL TESTS PASSED: Stage-4B TV-FISTA integration
   周期必须小于 Stage-4A 的12,521,547 cycles。

4) 测试正确后再分别运行 Synthesis 和 Implementation，并报告：
   open_run impl_1
   report_utilization -file stage4b_utilization_postroute.rpt
   report_timing_summary -delay_type min_max -file stage4b_timing_summary.rpt
   check_timing -verbose
   WNS/WHS 必须 >=0，TNS/THS=0，不能有内部端点失败。

5) 完整40轮验证：待 Stage-4A 已通过的40轮仿真和本版单轮与时序
   验证都完成后，按需要执行：
   close_sim
   set_property top tb_fista_top_q11_full [get_filesets sim_1]
   update_compile_order -fileset sim_1
   launch_simulation -simset sim_1 -mode behavioral
   run all

四、性能说明
-----------
Stage-4A 一轮实测12,521,547 cycles（50MHz下250.43ms）。
本版慢投影每次预计节省46个周期，但是否每个像素都进入慢通道
取决于输入图像和迭代过程；不凭空声称全局加速百分比。
必须以 XSim 的 one-iteration cycles 和 Implementation 的 timing 为准。

五、重要说明
-----------
- 本机没有 Vivado/XSim，不能宣称新 Verilog 已经过 XSim 或 Implementation。
- Python 自检仅验证除法核心，不能替代 Vivado RTL 对照验证。
- 新版将增加两路除法器的组合逻辑，可能增加 LUT、加长时序。
- 不改变 Stage-4A 原工程，也不使用任何未确认的40轮预测值作为硬门槛。
- Stage-4B 仍不是最终 AX7020 板级工程；外部接口待 Stage-5 完成。
