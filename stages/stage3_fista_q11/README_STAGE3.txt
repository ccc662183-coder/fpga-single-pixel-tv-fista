Stage-3：64x64 Q5.11 TV-FISTA 顶层集成
====================================

本阶段目标
----------
把 Stage-1 的 BRAM TV Prox 与 Stage-2B 的数据一致性计算整合为完整 FISTA
外迭代控制系统。算法计算全部位于 PL；PC 目前只负责加载测量数据和读取结果。

本阶段不是板级顶层，暂不包含 UART/AXI/PS/DDR，也不生成 bitstream。

一、目录
-------
rtl/
  sp_bram_4096x16.v             Stage-1 BRAM 原语
  sdp_bram_4096x16.v            Stage-1 双端口 BRAM 原语
  tv_dual_project_q11.v         Stage-1 对偶变量投影
  tv_prox64_bram_q11.v          Stage-1 TV Prox，原样复用
  fwht_inplace.v                Stage-4/Stage-2A FWHT 核心，原样复用
  fwht_q11_stage2.v              Stage-2A Q5.11 适配层，原样复用
  data_consistency_fista_q11.v   Stage-2B + 精确初始化反投影模式
  tv_fista_top_q11.v             Stage-3 FISTA 顶层控制器
sim/
  tb_fista_top_q11.v             一轮/完整 40 轮测试平台
 data/
  mask_4096_rowmajor.mem         固定 25% low-sequency 掩码
  fista_beta_q15.hex             Stage-0.2 生成的 40 项 UQ0.15 beta ROM
  cat64_measurements_q11_s32.mem cat64 的 1024 个测量值
  cat64_expected_iter1_q11_s16.mem 第一轮输出黄金向量
  cat64_expected_final_q11_s16.mem 完整 40 轮最终黄金向量
  其他文件为初始化、投影及中间结果交叉核对向量

二、关键算法顺序
----------------
初始化：
  x0 = z0 = W^T*y
  通过测量向量按 mask 位置零填充，再做一次完整 FWHT 和 >>>6。

每轮 k=0..39：
  c = (H*z) >>> 6
  r = mask ? (c-y) : 0
  g = (H*r) >>> 6
  v = z-g
  x_new = TVProx_35(v)
  z_new = x_new + (((x_new-x_old)*beta_q15[k]) >>> 15)
  x_old = x_new; z = z_new

最终输出：clip(x_40, 0, 2048)。中间迭代不做额外裁剪。

三、Vivado 2019.2 创建工程
--------------------------
1. 将整个 stage3_fista_q11 文件夹放到：
   <checkout>\stage3_fista_q11
2. 打开 Vivado 2019.2，在 Tcl Console 执行：

   cd "<checkout>/stage3_fista_q11"
   source ./create_vivado_project.tcl

3. Run Simulation -> Run Behavioral Simulation。
4. 默认仿真顶层为 tb_fista_top_q11_one_iter。
5. 在 XSim Tcl Console 执行：

   run all

四、第一步只运行一轮 FISTA
--------------------------
默认 OUTER_ITERS=1，预计运行时间明显短于完整 40 轮。
预期结果：
  PASS: exact initial backprojection W^T*y and one FISTA iteration
  PASS: output pixels 4096/4096 exact; errors=0
  PASS: range_error=0, protocol_error=0
  PASS: outer iterations=1, ...
  ALL TESTS PASSED: Stage-3 TV-FISTA top-level integration

一轮测试通过后，保存：
  stage3_one_iter_pass.png
  stage3_one_iter_console.txt

五、完整 40 轮测试
------------------
一轮测试通过后，再切换仿真顶层：

   set_property top tb_fista_top_q11_full [get_filesets sim_1]
   update_compile_order -fileset sim_1

然后重新 Run Behavioral Simulation -> run all。

完整 40 轮测试会调用 TV Prox 40 次。按 Stage-1 单次仿真耗时估算，
XSim 可能需要数十分钟，请确保电脑电源和 Vivado 运行环境稳定。

预期结果：
  PASS: exact 40-iteration TV-FISTA final reconstruction
  PASS: output pixels 4096/4096 exact; errors=0
  PASS: range_error=0, protocol_error=0
  PASS: outer iterations=40, ...
  PASS: final output range=[81,1526], sum=3930589
  ALL TESTS PASSED: Stage-3 TV-FISTA top-level integration

完整测试通过后保存：
  stage3_full_40iter_pass.png
  stage3_full_40iter_console.txt

六、当前先不要做的事
--------------------
- 不要生成 bitstream。
- 不要上板。
- 不要修改已经冻结的 Stage-1 / Stage-2A / Stage-2B 原工程。
- 一轮测试没有通过前，不运行完整 40 轮测试。

七、注意
--------
本工程由 Stage-0.2 固定点模型及已验证的 Stage-1/Stage-2B RTL 派生。
本环境没有 Vivado/XSim，Stage-3 RTL 尚未在用户的 Vivado 环境实测。
以你运行后的 XSim 结果为准；如果出现编译错误或数值不匹配，先发日志，
不要自行改动已冻结的子模块。
