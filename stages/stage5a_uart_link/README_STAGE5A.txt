Stage-5A：AX7020 / nanoDAP UART 通信链路复用与上板回环
======================================================

阶段定位
--------
本阶段先验证 PC ↔ nanoDAP USB-UART ↔ AX7020（PL）的物理通信，
以免直接接入 4.859 秒/40轮 的 Stage-4C 计算核心后不容易定位错误。
本阶段不是单像素图像重建，不要把 DATA_ECHO 的 PASS 当作 TV-FISTA PASS。

本包直接参考了用户上传的《实验一.docx》和 uart_dynamic_system.zip。
前者记录了 200MHz UART、动态速率、CRC16、256B packet、4096B FIFO 和上板实验。
后者提供了实际的 uart_rx/tx、uart_fifo、uart_packet_rx/tx、
uart_crc16、uart_baud_switch_ctrl、uart_protocol_core RTL。
这 8 个可综合 Verilog 文件按原样复制，未在 Stage-5A 内修改。

适配原则
--------
1. 当前算法核心 Stage-4C 采用 50MHz，所以先使用 AX7020 U18 的原生 50MHz。
2. 不额外使用 Clock Wizard，不引入 200MHz ↔ 50MHz 时钟域跨越。
3. uart_protocol_core 的 CLK_HZ 设置为 50_000_000，波特率设置 1_000_000。
4. 按比例调整动态速率控制器的超时计数（因旧工程使用 200MHz），但本阶段不测试/使用动态速率切换。
5. 串口波特率 1Mbps 对 50MHz 时钟每位约 50 拍，符合原 uart_rx 的16拍/位最低限制。
6. 软件使用旧工程相同的 A5 5A / VERSION / TYPE / SEQ / LEN / PAYLOAD / CRC16 格式。

实物连接（沿用旧实验，用户已实际验证过的引脚）
-----------------------------------------
AX7020 U18  : PL 时钟 50MHz（板内自带，不外接）
AX7020 N15  : 板载 KEY1, rst_n 低有效
AX7020 J10 PIN3 W19 : FPGA uart_rx_i ← nanoDAP U_TX
AX7020 J10 PIN4 W18 : FPGA uart_tx_o → nanoDAP U_RX
两端必须共地。nanoDAP 使用 3.3V TTL，禁止接入 RS-232 ±12V 电平。
原报告中的 COM13 只是当时的端口号，Windows 当前端口号以设备管理器为准。

工程文件说明
------------
rtl/uart_rx.v / uart_tx.v                  来自实验一的 8N1 分数波特率 UART
rtl/uart_fifo.v                            原 4096B BRAM FIFO
rtl/uart_crc16.v                           CRC16/CCITT-FALSE
rtl/uart_packet_rx.v / uart_packet_tx.v   包解析、生成和 CRC 校验
rtl/uart_baud_switch_ctrl.v               原动态速率协议控制（本阶段不使用切换）
rtl/uart_protocol_core.v                  原状态查询、数据回环和协议调度
rtl/stage5a_uart_link_top.v               新的 AX7020 50MHz 板级顶层
sim/tb_stage5a_uart_link.v                串口位级、报文、CRC 的 Stage-5A Testbench
constraints/stage5a_ax7020_50m_uart.xdc   AX7020 U18/N15/W19/W18 管脚
scripts/stage5a_link_test.py              PC 实物测试，status + binary echo + JSON 日志
create_vivado_project.tcl                 Vivado 2019.2 一键建独立工程
reference/stage4c_frozen/                 冻结算法 RTL，暂不加入 Stage-5A 工程

第一步：本机 Python 协议自检（无需串口，也无需开发板）
--------------------------------------------------
cd <checkout>\stage5a_uart_link
python scripts\stage5a_link_test.py --self-test
预期 4 条 PASS，包括 CRC16("123456789")=0x29B1。

第二步：Vivado 2019.2 行为仿真
---------------------------
打开 Tcl Console：
cd "<checkout>/stage5a_uart_link"
source ./create_vivado_project.tcl
launch_simulation -simset sim_1 -mode behavioral
run all

预期检查（新的 50MHz RTL 还未由 XSim 实际跑过）：
PASS: Stage-5A GET_STATUS -> 1000000 bps
PASS: Stage-5A binary 8-byte echo incl A5 5A 00 FF
PASS: Stage-5A full 256-byte payload echo, CRC exact
PASS: Stage-5A bad-CRC rejection and recovery
ALL TESTS PASSED: Stage-5A AX7020 UART 50MHz link verification

第三步：综合、布局布线与 Bitstream
------------------------------
在 Vivado 点击 Run Synthesis、Run Implementation，检查时序 WNS>=0、WHS>=0，
且 TNS=0/THS=0；执行 Generate Bitstream，然后 Hardware Manager 下载。
板级 XDC 不要直接引用旧工程 200MHz 的 MMCM 或 J11 数码管约束。

第四步：PC 实物通信验证
---------------------
python -m pip install pyserial
# 若 Windows 设备管理器显示 COM13：
python scripts\stage5a_link_test.py --port COM13 --baud 1000000 --rounds 2

预期显示 FPGA STATUS=1000000 bps，0/8/64/256B 数据包全部回环匹配、
CRC16 / TYPE / SEQ / LEN 全部正确，生成 stage5a_link_results.json。
如果实际串口不是 COM13，请修改 --port；不要同时打开其他串口助手或旧 GUI。

故障排查
--------
1. 端口打不开：检查 nanoDAP 串口驱动/COM 号/旧 GUI 是否占用。
2. 超时：检查 nanoDAP 的 U_TX → AX7020 RX、U_RX ← AX7020 TX，GND 共地。
3. 首包超时：按 KEY1 复位、确认 bitstream、核对 1Mbps 8N1。
4. CRC 错误：核对 payload 是否二进制、波特率、线缆与串口电平。
5. 位级/板级测试未完成前，不要宣称通信已验证通过。

协议边界（供 Stage-5B）
---------------------
A5 5A | VERSION(1B=01) | TYPE(1B) | SEQ(2B LE) | LEN(2B LE)
| PAYLOAD(0..256B) | CRC16(2B LE)
CRC 参数：CCITT-FALSE poly1021 initFFFF，无反射，XOROUT 0000；
CRC 覆盖 VERSION~PAYLOAD，不包括 A5 5A 与 CRC 字段自身。
0x10 GET_STATUS（长度0）→ 0x11 STATUS_RESP（4B active_baud）
0x20 DATA（0..256B）→ 0x21 DATA_ECHO（相同载荷）

下一阶段 Stage-5B 必须修改/扩展协议控制器，增加至少：
LOAD：将 1024x32bit 测量值分16包写入核心；
START：确保1024个测量值完整且校验通过后启动40轮计算；
GET_STATE：查询 ready/busy/done/error/iter/cycles；
READ_RESULT：将4096x16bit像素按每包<=256B读取（至少32包）。
所有新命令/应答类型与数据长度需先制定并用 Testbench 完整覆盖。
不得把 DATA_ECHO 直接当成 Stage-4C 的测量值加载接口。

性能边界
--------
旧实验在 200MHz 核和 1.5Mbps 下完成过文件回环，但不能据此声称
50MHz Stage-5A 在 1Mbps 已实测成功；只有新工程通过 XSim 和上板后才成立。

当前验收状态（创建本包时）
--------------------------
[已验证] 原 UART 实验一（旧工程）此前的板级回环与测试日志。
[已验证] Stage-4C 40轮 RTL 逐像素匹配（独立冻结版本）。
[已验证] 新 Python 协议打包/CRC 自检（本地运行后写入测试记录）。
[待验证] 新 Stage-5A 50MHz XSim、布局布线和实际 AX7020 通信。
