单像素成像软件 MVP 第三阶段完成后的 第四阶段：Vivado 2019.2 FWHT 最小核心功能验证

一、为什么做这个？
第三阶段的 TV-FISTA 在独立图片上确有改善，但完整 TV-FISTA 的硬件实现尚未评估。
先验证“真实图片得到的整数 Hadamard 数据”能否由自编 RTL 在 FPGA 计算架构中完全复现。
这一步只验证 64×64 的 FWHT 计算核心，不是 128×128 的完整压缩成像系统，也不是已在 AX7020 板上运行。

二、文件说明
rtl/fwht_inplace.v          可综合 Verilog，4096 点整数 FWHT；逐次蝶形、存储器原位更新
sim/tb_fwht_inplace.v       Testbench，检查 4096 个正变换输出，二次变换检查原图*4096
 data/cat64.png             从第三阶段 cat 图缩小得到的 64×64 8 位灰度测试图
 data/fwht64_input.mem      4096 行，每行 8 位十六进制的有符号 32 位输入
 data/fwht64_expected.mem   4096 行，期望整数系数（有符号 32 位）
 data/fwht64_reference_report.txt  Python 整数计算验证报告
 tools/prepare_fwht_vectors.py    Python 参考生成脚本，可复算两份 .mem
 create_vivado_project.tcl  可选：创建 Vivado 2019.2 项目，不会编程板卡

三、推荐操作（Windows）
1. 将本 ZIP 解压到：
   <checkout>\single_pixel\stage4_hw\
   注意 stage4_hw 下面直接能看到 rtl、sim、data、create_vivado_project.tcl。
2. 打开 Vivado 2019.2（不是 Vitis），在底部 Tcl Console 输入：
   cd "<checkout>/single_pixel/stage4_hw"
   source ./create_vivado_project.tcl
3. 左侧 Flow Navigator -> Simulation -> Run Simulation -> Run Behavioral Simulation。
4. 仿真启动后在 Vivado Tcl Console 输入：run all
5. 理想情况下 Transcript/Console 将出现：
   PASS: forward 4096 / 4096
   PASS: roundtrip 4096 / 4096
   ALL TESTS PASSED: Stage-4 integer FWHT core functional simulation
   注意：这些是 TESTBENCH 预期文字，不表示我已在 Vivado 执行。
6. 请将上述输出与仿真界面一起截图并保存：12_fwht_rtl_sim_pass.png。
   然后发给 ChatGPT，进行下一步综合与资源、时序分析。

四、如果报错
- $readmemh cannot open *.mem：先确认 Simulation Sources 中存在两个 .mem 文件；可尝试将数据文件复制至 Vivado 当前仿真工作目录（通常是工程 .sim/sim_1/behav/xsim）。
- HDL syntax error：完整截图 Error 列表和 Tcl Console 日志。
- mismatch：请保存第一次 MISMATCH 的地址、结果及期望值，不要掩盖错误。
- xsim 仿真比较慢：4096点*12级、两次变换，约十万以上个仿真时钟边沿，不是无限循环。

五、技术边界与下一步
- 使用 64x64 图片验证整数 FWHT：输入实际照片像素，但 Hadamard 测量为数学模拟。
- 输入数据是 8 位灰度，存储为有符号 32 位，单次变换中最大幅度不超过约 4096*255，32 位充足。
- 这份 RTL 是计算正确性原型：没有 AXI/DMA、没有相位、没有 TV-FISTA、没有并行优化。
- 访存与 BRAM 推断、LUT/FF、时序必须以 Vivado 综合结果为准，不能凭代码保证。
- 通过仿真之后才开展综合。再考虑 128x128、部分测量系数、定点 TV 子运算。
