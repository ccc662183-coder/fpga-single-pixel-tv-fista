# 实验结果与证据索引

- [核心周期表](../results/core_cycles.csv) 与 [50 MHz 换算图](../results/core_time.png)：对比 `cat64`、40×35、同掩码输入。Stage-3、4B、4C 的完整 PASS 来自 XSim/Vivado 日志摘录；Stage-4A 本地 `simulate.log` 只留下单轮日志，40 轮数据来自原 XSim 截图的 [文字摘录](../results/vivado/stage4a/xsim_full_screenshot_transcript.txt)，去除了本机路径。没有把摘录伪装成完整日志。
- [资源与时序表](../results/resource_timing.csv)：Stage-3 使用布局布线后利用率；Stage-4A 用原 Vivado 资源截图（运行阶段未展示）；Stage-4B、4C 和 5B 使用综合后报表，5B 还含 UART。统计口径有别，不能直接解读为严格同阶段资源消耗差值。时序列来自布局布线后摘要或 Stage-4A 的留存截图。各报表与早期单元 Testbench 摘录见 [Vivado 证据](../results/vivado)。
- [四图板级报告和读回结果](../results/board)：每图一个 JSON 和 `4096 × little-endian int16` 二进制。`cat64`、`rocket`、`text` 提供原板测重建 PNG；`moon` 图像再分发权未单独核实，未纳入 PNG/PGM，保留本次位精确校验必需的 Q5.11 读回样本与黄金向量。用仓库的离线对拍脚本可核对读回与文件哈希，不等同于再次上板。
- Stage-5A 的 JSON 是纯 UART 回环实测。Stage-5B 自带一轮端到端 Testbench，但原工程对应 `simulate.log` 为空；归档的主机自检和真实四图读回不能作为该历史 XSim 测试的 PASS 日志。
- [Stage-5D GUI](../results/gui)：界面图为当前发布副本的实际 Qt 离线渲染，不表示新板测；四份历史 GUI 报告保留匹配数、核心周期、CRC 计数与输出哈希，输出哈希逐图与 Stage-5B CLI 归档相同。源随附 README 关于 GUI 尚待上板的表述为当时编写状态，后续导出记录另行提供证据。
- [Stage-6A 定点软件参数搜索](../results/quality)：归档了扫描 CSV、JSON、汇总及 λ 曲线。相同四图上，固定 λ 整数 20 的平均 PSNR 为 31.2289 dB，候选整数 11 为 31.5231 dB；仅约 +0.2942 dB，且没有独立留出/真实光学数据，不应外推。

原始文件与证据留在本地工程。此目录只收录白名单文件；选录版报告移除了主机名、用户目录或串口/本地输入元数据。原始 `.wdb`、完整日志、生成工程、`.bit`、报告归档包与第三方数据集不随仓库分发。
