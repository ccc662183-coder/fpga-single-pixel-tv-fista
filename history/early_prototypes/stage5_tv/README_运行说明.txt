单像素计算成像软件/硬件 MVP 第五阶段 A：TV 梯度与散度计算单元
针对：ALINX AX7020 / XC7Z020-2CLG400 / Vivado 2019.2

一、为什么需要这一步
前一阶段 4096 点 FWHT 完成功能仿真、资源综合和 100 MHz 后布局布线时序。
本阶段只研究 TV 正则化中的二维局部差分算子：前向梯度 G 和散度 div=-G^T。
使用 16x16 灰度真实图片片段 + Python 整数参考值测试 256 个像素。

重要边界：这不是完整 TV-FISTA；没有光学测量、AXI/DDR、板卡运行，也没有 TV 近端算子或投影计算。
只有单像素邻域算术模块，邻域数据在本阶段由 Testbench 提供。

二、安装操作
1. 把整个 ZIP 解压到：
   <checkout>\single_pixel\stage5_tv
2. 确保根目录下直接存在 create_vivado_project.tcl，以及 rtl、sim、data、constraints、tools 文件夹。
3. 打开 Vivado 2019.2，在 Tcl Console 输入：
   cd "<checkout>/single_pixel/stage5_tv"
   source ./create_vivado_project.tcl
4. 点击 Simulation -> Run Simulation -> Run Behavioral Simulation。
5. 在仿真界面 Tcl Console 输入：
   run all

三、预期 PASS 输出（仅当 Vivado 实际验证后才算通过）
PASS: TV forward gradient 256 / 256
PASS: TV divergence 256 / 256
PASS: discrete adjoint identity
ALL TESTS PASSED: Stage-5A TV gradient and divergence RTL

如果失败，请提供首个 MISMATCH 或 ERROR 截图。不需自己修改数据。
如出现无法读入 .mem，检查 Simulation Sources 中 6 个 .mem 是否全部加入。

四、通过后再考虑综合
先保存一张包含 PASS 和 Vivado 仿真界面的截图：15_tv_gradient_divergence_sim_pass.png。
然后可运行 Run Synthesis，观察 LUT、FF、DSP。
由于本阶段 RTL 不包含完整行缓存/双端口 BRAM，资源占用不能外推整个迭代重建系统。
XDC 的 100 MHz 约束仅用于内部时序试验，并没有引脚绑定，不生成开发板比特流。

五、算法和整数规则
输入 x 是 8bit 无符号灰度；邻接双变量 p_x,p_y 是 12bit 有符号整数。
右、下梯度为邻居减去中心；右/下边界梯度强制为 0。
散度是负伴随算子（含四侧边界处理），有恒等式：
  <Gx,p> + <x,div(p)> = 0
测试向量中 p=(Gx)*20，仅是确定性压力测试，不代表 FISTA 算法中的真实双变量。

六、后续
本轮全部通过后，进行 TV 双变量更新/投影和定点误差，再考虑近端迭代调度。
