第五阶段 C：小尺寸 8x8 TV 近端内循环 RTL 整体验证

目的：验证 TV 正则化内循环的多像素数据依赖、梯度/散度、非线性投影和多轮更新连接后的定点结果。

算法与第二阶段 Python 的 prox_tv_isotropic 同类，但采用 Q5.11 定点实现，且只迭代 3 次。
特别注意：这是 TV 内循环，不包含 40 轮 FISTA 外循环、Hadamard 前反向计算、128x128 大图和 PS/PL 接口。

测试数据来源：第 1 阶段 astronaut 示例图缩放到 8x8。
lambda=20/2048，按 Q11 的整数移位/除法计算，参考数值独立由 Python 生成。
因为定点与迭代次数不同，不能直接期待与原 128x128 浮点图像 PSNR 一致。

文件结构：
  rtl/tv_prox8_q11.v        主迭代模块，小图像使用触发器数组，不是 BRAM 架构
  rtl/tv_dual_project_q11.v 复用此前验证过的串行投影单元
  sim/tb_tv_prox8_q11.v    64 点数值检查与超时保护
  data/input_pixels.mem, data/expected_prox.mem Python 整数测试向量
  constraints/tv_prox8_100mhz.xdc 100MHz 时钟约束
  create_vivado_project.tcl

运行：
  1) ZIP 全部解压至 <checkout>/single_pixel/stage5c_tv_prox
  2) Vivado 2019.2 Tcl Console：
     cd "<checkout>/single_pixel/stage5c_tv_prox"
     source ./create_vivado_project.tcl
  3) Run Behavioral Simulation -> run all
  4) 查看到 PASS: 8x8 ... 64 / 64 和 ALL TESTS PASSED 才算功能通过。
  5) 若失败请发送第一条 MISMATCH / ERROR。请勿先综合。

重要：当前环境没有 Vivado/iverilog，已完成 Python 整数参考自测和文件打包，
尚不能声明新的 RTL 已经通过仿真。必须以你本机 Vivado 2019.2 的结果为准。
