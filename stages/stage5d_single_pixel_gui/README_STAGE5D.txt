Stage-5D：AX7020 单像素成像 TV-FISTA 图形化上位机
==================================================

1. 当前验证依据
--------------
Stage-5B 已由使用者在真实 AX7020+COM13+1Mbps 上完成四张图像 40 轮实测：
cat64: 242,929,421 cycles；moon:172,124,141；rocket:215,551,083；text:224,908,613。
每张图像均 4096/4096 个输出像素与对应冻结 Stage-0.2 定点黄金向量精确相符。
这些是之前已经实测的项目历史结果；本 Stage-5D GUI 是新的上位机，尚需在
Windows+PySide6 环境中实际运行并完成 GUI→FPGA 的验收，不能把离线 mock 测试
或之前的 CLI 测试自动说成“GUI 已经实物通过”。

2. 安装与启动（不修改 RTL，也不修改 bitstream）
----------------------------------------------
复制 stage5d_single_pixel_gui 文件夹到：
<checkout>\stage5d_single_pixel_gui

在 PowerShell 中：
  cd <checkout>\stage5d_single_pixel_gui
  python -m pip install -r requirements.txt
  python scripts\self_test_stage5d.py
  python stage5d_gui.py

也可以双击 run_stage5d.bat。
需要 Python 3.10+、PySide6、pyserial、Pillow、numpy。
之前已经用于 Stage-5B 的 FPGA bitstream 保持加载状态。关闭旧 UART Studio
和其他占用 COM13 的程序。

3. 正确操作顺序
--------------
  (1) “数据来源”选择 cat64（首次建议），点击“载入/生成测量数据”。
  (2) 左下输入 COM13，点击“测试板级连接”：真实查询 GET_STATUS=1Mbps。
  (3) 点击“运行40轮 FPGA重建”，等待 PL 完成及 32 包结果回读。
  (4) 观察四张图：原始图像、直接反投影、FPGA 实际重建、Stage-0.2 黄金参考。
  (5) 观察核心周期、50MHz换算计算时间、数据装载时间、回读时间、端到端耗时、PSNR。
  (6) 程序在 results/ 自动保存证据文件，也可以点击“导出实验记录”保存副本。
  (7) 其余三张内置图像 moon、rocket、text 可重复操作，不需重新下载 bitstream。

4. 本地图像模式
--------------
  (1) 切换“选择本地图片（生成测量）”并浏览 PNG/JPG/BMP/TIFF。
  (2) 图像经 Pillow LANCZOS 缩放为64×64，再转为灰度 uint8。
  (3) 转 Q5.11：q=(uint8*2048+127)//255。
  (4) 计算 4096 点整数 FWHT、算术右移6位，再按冻结 low-sequency 掩码抽取1024点。
  (5) 上述生成流程与 Stage-0.2 原软件完全一致；四张内置图像 4096 个测量值已回归验证。
  (6) 单击运行后，PC 只发送测量值，40轮 TV-FISTA 必须由 FPGA PL 执行。
注意：任意新图像没有预计算的独立 40轮黄金结果，因此不能声称“4096/4096 bit-exact”，
但仍可统计 40轮完成状态、原图 PSNR、计算周期、CRC和传输耗时。
某些极端图像可能触发 RTL 数值范围保护；此时程序应报错而不是伪造成功。

5. 外部测量数据导入（针对教师要求的第三方研究数据）
------------------------------------------------
支持：
  .mem/.hex：每行一个 32-bit 十六进制补码测量值，无符号形式（例 ffffffe8）
  .txt/.csv：十进制有符号 32-bit 整数，或等价的 uint32 位模式
  .npy/.npz：包含1024个整型 Q5.11 Hadamard 测量值（npz key y/measurements/arr_0）
数据严格要求：1024项，顺序为 64×64 natural Sylvester Hadamard 行主序
固定的 1024索引 low-sequency 掩码，W=H4096/64，算术右移6位，S32.F11 定点值。

注意：外部数据来自真实 DMD 采集时，常需转换图案顺序、正负差分、暗电流标定、
灰度尺度及归一化；数据长度与格式一致不说明物理/数学意义一致！
必须先由研究数据提供的编码矩阵/图案和 calibration 说明核对，再勾选兼容性确认。
保留原始数据、来源 DOI/URL、采集类型、原始测量文件和转换脚本，报告中如实
标注实测/仿真来源；软件无法自动验证论文数据真实性。
可关联第三方原始/参考图，计算 PSNR，但未提供独立黄金重建时不得宣称 bit-exact。

6. 协议与硬件分工
----------------
不依赖 PS/DDR/AXI；重建由 PL 执行，PC不执行TV-FISTA：
A5 5A | VER=01 | TYPE | SEQ_LE16 | LEN_LE16 | PAYLOAD | CRC_LE16
CRC-16/CCITT-FALSE poly1021 initFFFF，帧载荷最多256B，停等逐包应答。
0x10 GET_STATUS / 0x11 STATUS
0x48 RESET / 0x49 RESET_ACK
0x40 LOAD / 0x41 LOAD_ACK (17包：16x63 +16个 32-bit 测量值)
0x42 START / 0x43 START_ACK
0x44 GET_STATE / 0x45 STATE (40轮结束后原始索引39)
0x46 READ / 0x47 READ_RESP (32包：128个 16-bit 像素/包)
0x7F ERROR

同一板级计算核心，50MHz；UART固定1Mbps 8N1。必须使用 Stage-5B 已验证的 bitstream，
Stage-5A 纯回环固件不支持重建指令。

7. 导出资料
-----------
程序自动创建 results/YYYYMMDD_HHMMSS_name/，包含：
  fpga_board_report.json              实测配置、原始状态与核心/端到端性能
  gui_console_log.txt                GUI 运行日志
  metrics.csv                        汇报及绘图用指标表
  fpga_reconstruction.png            实际 FPGA 读回结果的可视化
  fpga_pixels_q11_le.bin             真实板级像素字节（LE uint16 Q5.11）
  fpga_pixels_q11_s16.mem            RTL 可复查 HEX 数据
  measurements_q11_s32.mem           输入1024个 HEX 数据
  direct_backprojection.png          PC 直接反投影对照
  input_or_reference.png             若有原图
  fixedpoint_golden.png              内置四图才有；软件参考、非硬件测量
  golden_absolute_error_visualization.png   有黄金结果时显示误差；0代表完全一致
  README_证据说明.txt
  SHA256SUMS.txt                      导出各文件 SHA-256 记录

图像色阶是 0..2048 的 Q5.11 映射到 0..255，仅用于显示。
PSNR 采用原始8位图像按 Q11 量化后的幅值，和FPGA Q11输出比较；
这是 64×64 重建精度，不是原始高清图像的 PSNR。
计算时间=FPGA core_cycles/50,000,000；端到端时间包括主机通信和状态轮询。
Windows下GUI Qt主线程不阻塞，串口与FPGA计算在后台QThread执行；
这里的“线程”是程序运行期间的实时处理，不是服务器后台任务。

8. 测试证据等级
--------------
已完成：
  Python离线回归（四图 Hadamard 1024/1024严格匹配）、协议mock和错误注入。
  Stage-5B原CLI四图真实AX7020硬件回读4096/4096。
尚需用户执行：
  Windows PySide6 GUI真正启动、cat64完整硬件通信、图像及指标显示、导出文件。
验证通过后保存GUI截图、真实硬件运行状态和导出 JSON/图片用于最终报告。

9. 目录
-------
stage5d_gui.py               PySide6图形主程序
run_stage5d.bat              Windows启动器
scripts/image_pipeline.py    数值契约、生成/导入测量、直接反投影、PSNR
scripts/board_session.py     Stage-5B硬件协议的统一任务执行与记录
scripts/stage5b_reconstruct.py  已通过四图板级验证的冻结上位机协议副本
scripts/stage5a_link_test.py    原CRC16、打包、解析与字节收发
scripts/self_test_stage5d.py  无设备离线回归测试
input_images/ 等              原始图与实际黄金/测量文件（在data/目录）
tests/                      MOCK测试代码（只检验PC侧协议流程）

重要：不要把模拟串口测试结果与真实 FPGA 上板实验结果混写。
