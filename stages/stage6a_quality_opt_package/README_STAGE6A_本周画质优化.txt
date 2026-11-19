Stage-6A | 画质与速度联合优化实验包
====================================

一、这是哪一阶段？
------------------
前期 Stage-4C 已在 50 MHz 下达到 242,929,421 cycles（cat64），核心计算约 4.859s；
Stage-5D 已在真实 AX7020 上完成四图重建和 GUI 展示。现在必须保留原 FPGA 工程，
本包只在 Windows Python 上研究“为什么看起来不够清晰、如何提高 PSNR / SSIM”。
本包所有新参数下的结果都是“PC 定点参考实验”，不是 FPGA 硬件结果。

二、你将拿到哪些文件？
----------------------
run_stage6a_quality_sweep.py   按 lambda_q11 扫描，计算 PSNR、SSIM、边缘 RMSE，逐像素检查冻结的参考基线。
run_additional_probes.py     可选：研究 20/40/60/80 外迭代、15/25/35/50 TV 内迭代、3 种 25% 掩码。
run_stage6a.bat             双击运行第一轮 lambda 扫描（需要先安装 requirements）。
requirements.txt            Python 依赖。
reference/                  从原 Stage0.2 包复制的冻结 Python 参考模型、原始图像、四组 golden。
reports/results.csv         本机已运行的 lambda 扫描结果（可重算）。
reports/summary.json        本机已运行的参数总结、掩码校验和安全警告。
reports/summary.txt         本机已运行的文字总结。
reports/additional_*.csv    迭代/掩码对比实验结果。
reports/lambda_psnr.png     4 图平均 PSNR vs lambda。
reports/*_baseline_candidate.png  原图/当前重建/候选重建三列对照，像素仍是 64x64。

三、开始运行
------------
在 PowerShell 执行：

    cd <checkout>\stage6a_quality_opt_package
    python -m pip install -r requirements.txt
    python run_stage6a_quality_sweep.py --phase lambda
    python run_additional_probes.py

可选的较完整一次运行：
    python run_stage6a_quality_sweep.py --phase all
（此命令会重复第一轮参数扫描，并额外运行更广的外迭代/内迭代/掩码探针；PC 上可能略久。）

不要在 Vivado 中加载本包；不用重新下载 bitstream。

四、已完成的本机实验（重要：只是软件）
-----------------------------------
基线：64x64、1024/4096 个 low-sequency Hadamard 测量；lambda=20/2048；40x35 迭代。
冻结基线与 Stage0.2 的四张图像 golden：四组各 4096/4096 bit-exact。
另外核对了 Stage5D v1.0.2 数据包：测量 mask、四张 golden 与本包完全相同。

固定 40x35、固定 25% 掩码，lambda_q11 测试 8,9,10,11,12,13,14,15,16,20,24,28,32,40,48,64。
8、9、10 在 rocket 图像中出现候选值越出 signed 16-bit 范围，故不应作为可用的跨图像统一参数。
对于四张样例均合法且平均 PSNR 最优的候选：lambda_q11=11（11/2048=0.00537109375）。
原版 20/2048 到候选 11/2048，PSNR 提升分别为：
    cat64   28.4574 -> 28.6305 dB，+0.1731 dB
    moon    36.3411 -> 36.8811 dB，+0.5400 dB
    rocket  33.6420 -> 33.9779 dB，+0.3358 dB
    text    26.4751 -> 26.6031 dB，+0.1280 dB
四张 SSIM 也都有提高，但幅度不大。

保持 lambda_q11=11 时：
    外迭代 20/40/60/80 的四图平均 PSNR 依次约 31.528/31.523/31.523/31.523 dB。
    内迭代 15/25/35/50 的四图平均 PSNR 依次约 31.536/31.526/31.523/31.523 dB。
这些只是这四张样例上的指标差异；不能据此声称“减少迭代必定提高画质”。
固定 25% 时，混合 768 个低序 + 256 随机系数整体未超过现有低序掩码。
随机 1024 掩码（包含 DC 位置）平均 PSNR 明显低于低序掩码。
原因之一是失去大量低序主要结构信息；不是“随机 Hadamard 在所有压缩感知场景都差”。

五、对 FPGA 工程的影响（非常关键）
---------------------------------
1）Stage-4C 的 TV Prox 使用了针对 lambda_q11=20 的除以5快速常数除法结构。
   把 lambda 改成 11，TV 中“div * lambda >> 11”和“gradient * 256 / lambda”都要一起改。
   原 delta=trunc(absgrad*64/5)，候选应变为 delta=trunc(absgrad*256/11)，再恢复符号。
   不允许仅改一个常数、继续使用原 /5 的算术路径。
2）延长 FISTA 外迭代到 60/80，需要扩大 beta ROM 和计数器/控制逻辑；不是仅改 Python。
3）降低 TV 内迭代次数需要改 RTL 配置、重做全图 4096/4096 黄金测试。
4）更换测量掩码不仅需要重算测量值，还要求更换 FPGA 使用的掩码 ROM/测量索引。
5）保留 Stage-5B / Stage-5D 已实测版本和其 bitstream 不变。任何改进都在独立目录验证。

六、建议这一周的后续执行路线
----------------------------
A. 用另外 8～12 张未参与调参的公开图像进行独立测试；对新图还要做 Q5.11 溢出检查。
B. 选定画质最稳、硬件可实现的一组参数，例如 lambda_q11=11 和可选的内迭代 15。
C. 独立创建硬件候选 Stage-6A-Q，不覆盖 Stage-4C/Stage-5B；更改 TV 算术路径、黄金数据。
D. 先做 TV Prox 单元测试，再做单轮 FISTA，最后完整 40 轮，完成 post-route 50MHz 时序。
E. 将新 bitstream 装入 AX7020 实测四图，GUI 展示原版与候选版 PSNR、SSIM、核心时间对比。
F. 第三方公开真实光学测量数据验证与以上“自有模拟测量的画质调参”分开做。

实验验收：画质提升必须来自实际 64x64 数据的 PSNR/SSIM，而不是 GUI 显示插值或锐化。
硬件正确性：必须逐像素与新的软件定点黄金结果匹配，不能直接用原 lambda=20 的 golden。
实验范围：只包含已经提供的四张图片；小样本选出的参数未必适用于任意新图片。
