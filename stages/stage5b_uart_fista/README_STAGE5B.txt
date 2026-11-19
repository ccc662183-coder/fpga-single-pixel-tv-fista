Stage-5B：AX7020 PL 侧 UART 数据装载、TV-FISTA 计算和重建结果回传
=================================================================

当前状态与风险
------------
原 Stage-5A 已由用户在真实 AX7020 / COM13 / 1Mbps 下验证通过。
Stage-4C 已由用户完成完整40轮、4096/4096位精确验证，并满足50MHz核心时序。
本 Stage-5B 包把两者集成；但新 RTL 尚未由 Vivado XSim、综合、布局布线或上板验证，
不能将软件自检称为 FPGA 实测。必须按下面顺序逐项验收。

工程与时钟
----------
设备：ALINX AX7020, xc7z020clg400-2，PL外部50MHz时钟 U18。
复位：KEY1 N15 低电平有效，释放同步。UART: J10 PIN3 W19 RX，PIN4 W18 TX。
USB-UART：原实验的 nanoDAP U_TX -> FPGA RX，U_RX <- FPGA TX，GND 共地，3.3V TTL。
主时钟和计算核心、UART 都运行在50MHz同一PL时钟域；UART固定1Mbps 8N1。
没有 PS、DDR、AXI 或软件层面的算法计算。

本包设计结构
------------
rtl/stage5b_uart_fista_top.v  —— 新增协议桥、核心软复位、测量加载、计算控制、结果缓冲
rtl/tv_fista_top_q11.v       —— 冻结 Stage-4C 核心，40轮×35次默认
rtl/其他 Stage-4C 模块      —— 与 Stage-4C 源码SHA256一致，未经修改
rtl/uart_rx/tx/fifo/...     —— 复制自已上板成功的 Stage-5A 通信模块
reference/                 —— 原Stage-5A协议控制器供参考（不参与新工程综合）
sim/tb_stage5b_uart_fista_one_iter.v —— 1轮系统端到端 UART 数据路径测试
scripts/stage5b_reconstruct.py       —— PC 发送、查询、回读、精确比对、生成PGM/PNG和JSON
scripts/stage5a_link_test.py         —— 复用数据帧、CRC16、串口读写函数
constraints/stage5b_ax7020_50m_uart.xdc —— Stage-5A 已验证板级管脚约束
create_vivado_project.tcl           —— Vivado 2019.2独立创建工程

通信报文格式：保持实验一、Stage-5A 不变
-------------------------------------
A5 5A | VER=01 | TYPE(1B) | SEQ_LE16 | LEN_LE16 | PAYLOAD(0..256B) | CRC_LE16
CRC-16/CCITT-FALSE: poly=1021, init=FFFF, refin=false, xorout=0000。
CRC覆盖 VERSION 到 PAYLOAD，不覆盖帧头与CRC字段。
PC采用停等、逐包校验，当前不自动重传，以避免掩盖传输错误。

Stage-5B 命令一览
----------------
0x10 GET_BAUD, 0B -> 0x11 BAUD, 4B; 返回1000000 little-endian
0x20 DATA, 0..256B -> 0x21 DATA_ECHO, 原样返回，通信回归测试
0x48 RESET, 0B -> 0x49 ACK, 1B=00; FPGA计算核心软复位、清空加载计数，但不复位UART
0x40 LOAD, 253B(块0..15)/65B(块16) -> 0x41 LOAD_ACK, 4B
   LOAD.payload = [chunk_index(u8)] + (63/16个 signed S32.F11 测量值，每个LE32)
   分块顺序：chunk 0..16，不允许乱序；16×63+16=1024个数
   ACK.payload = [chunk_index(u8), loaded_count(u16 LE), status(u8=0)]
0x42 START, 0B -> 0x43 ACK, 1B=00; 必须已经正确装载1024个数
0x44 GET_STATE, 0B -> 0x45 STATE, 12B
   byte0 flags: bit0=ready, bit1=busy, bit2=done, bit3=range_error, bit4=protocol_error
   byte1=FISTA outer_iter，byte2..3=loaded_count LE16
   byte4..7=core busy周期计数LE32，byte8..9=UART CRC错误计数低16位
   byte10..11=保留0；此计数是核心忙碌周期，不等于端到端时间
0x46 READ_RESULT, 1B [block_index=0..31] -> 0x47 RESULT, 256B
   每包128个像素×signed Q5.11 LE16，共32包得到4096像素
   仅done后允许读取; 输出由Stage-4C自身裁剪到[0,2048]
0x7F ERROR, 2B [request_type, error_code]
   code1=非法命令/长度；code2=LOAD顺序、长度或状态错误
   code3=START/READ未就绪；code4=测量加载阶段核心拒绝

约束与正确性
----------
* 每条LOAD经CRC校验后，按严格chunk序号和地址顺序装入核心，无需在FPGA侧存一套完整的1024x32 FIFO。
* 一次LOAD请求仅在前一请求已完整ACK后发送，防止UART状态机忙时收到新请求。
* 软件重启一张图之前先发送RESET；复位仅针对计算核心，UART串口始终维持连接。
* 运算由PL中的40轮Stage-4C RTL完成；PC只用于选择已有测量向量、编码/发送和显示/对比。
* Host 计算时只轮询状态，不在软件中执行 TV-FISTA。
* 严格检查所有4096个像素是否逐项与该图的Stage-0.2黄金向量一致。

第一步：本机Python自检（不需要Vivado或板子）
---------------------------------------------
cd <checkout>\stage5b_uart_fista
python scripts\stage5b_reconstruct.py --self-test

第二步：Vivado 2019.2 系统仿真（新RTL必须跑）
--------------------------------------------
cd "<checkout>/stage5b_uart_fista"
source ./create_vivado_project.tcl
launch_simulation -simset sim_1 -mode behavioral
run all

默认TB为tb_stage5b_uart_fista_one_iter，仅实例化OUTER_ITERS=1。
真实经UART发送17个CRC16包（1024个测量值），START一次FISTA，
然后经UART读回32个256B结果包（4096像素），并与单轮Stage-0.2黄金输出比较。
同时检查载荷乱序拒绝、LOAD_ACK、状态查询、核心复位、旧GET_BAUD接口。
计算和串口位级都在XSim验证，预计耗时高于Stage-5A单纯回环。
预期末尾：
PASS: Stage-5B UART 17 frames -> 1024x32-bit measurements, CRC/order exact
PASS: Stage-5B START and busy state visible over real UART frames
PASS: Stage-5B 4096/4096 one-iteration golden pixels through 32 UART result frames
PASS: Stage-5B restart/reset leaves serial link active
ALL TESTS PASSED: Stage-5B UART -> TV-FISTA -> UART single iteration

第三步：综合、布局布线和bitstream
--------------------------------
通过仿真后：Run Synthesis、Run Implementation，检查 WNS/WHS非负、TNS/THS=0，
确认 50MHz 核心时序及资源，Generate Bitstream，并下载板级顶层。
注意：板级顶层默认OUTER_ITERS=40、TV_INNER_STEPS=35；仿真TB参数1不改变板级综合参数。
板级集成可能使50MHz布局布线劣化，必须重新检查；不复用Stage-4C的时序结论代替。

第四步：cat64真实上板重建
------------------------
关闭旧UART Studio/串口终端，运行：
python scripts\stage5b_reconstruct.py --port COM13 --baud 1000000 --dataset cat64
程序按 STOP-WAIT发送17块1024个S32.F11测量值，等待FPGA计算，分32块回传4096个Q5.11像素，
严格逐项比较原Stage-0.2黄金结果，保存bin、PGM/可选PNG、JSON性能日志。
注意：此命令只能在新Stage-5B bitstream下载成功后使用；Stage-5A固件只支持回环，不能运行重建。

cat64 板级通过后，可以另做 moon、rocket、text 数据集实测：
python scripts\stage5b_reconstruct.py --port COM13 --dataset moon
这些图像的软件黄金数据存在，但此前未经过4图的40轮RTL完整验证，属于额外验证。

保留证据：Stage-5B XSim末尾PASS、routed资源报告、routed时序报告、
上位机日志JSON、输出图片与开发板实物连接/下载截图。

对性能的解释
------------
Stage-4C原单独核心仿真40轮为242,929,421周期=4.85858842秒（50MHz）。
本工程STATE返回的core_busy计数可能与原TB“compute_cycles”口径略有不同，
应以板级实测和同一口径对照为准。UART发送/回读、USB驱动/应用层会增加端到端时间。
板级整体计时要分开记录 LOAD耗时、PL计算耗时、READ耗时、总耗时。
