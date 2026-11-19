# 复现指南

每个阶段在 `stages/` 下保有原来的内部目录关系。`<checkout>` 表示克隆后的仓库根。原阶段说明中的旧绝对路径已去标识，以本文命令为准；COM 口号按设备管理器实际显示填写。没有改动 RTL、Testbench、Tcl、XDC 或冻结 Python 算法。

## 软件与黄金向量

在仓库根目录用 Python 3.11+（本次离线检查用 3.13），建议使用独立虚拟环境：

```powershell
python -m venv .venv
& .\.venv\Scripts\Activate.ps1
python -m pip install -r requirements-examples.txt
python scripts/prepare_test_images.py
python scripts/verify_board_results.py
```

准备示例图后，分别在 `stages/stage0_2_fixedpoint_package` 运行 `python stage0_reference_64.py` 和 `python stage0_2_fixedpoint.py`。后者运行历史向量兼容检查并生成四图定点输出，可能耗时较长。两个参考脚本都会写入阶段输出目录；若需保留仓库内冻结向量，请在一次性工作副本运行，或先备份输出目录。RTL 自带各自的 `.mem` / `.hex`，跑 Vivado 并不依赖图像准备脚本。

## Vivado 2019.2 / XSim

打开 Vivado Tcl Console，以 Stage-4C 为例：

```tcl
cd {<checkout>/stages/stage4c_memory_overlap}
source ./create_vivado_project.tcl
launch_simulation
run all
close_sim
set_property top tb_fista_top_q11_full [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run all
```

- 每个硬件阶段的 `create_vivado_project.tcl` 以脚本位置为根，自动加入本阶段的 HDL、XDC 与所需向量，并在该阶段的 `vivado_project/` 下创建工程。脚本含 `-force`，重新执行前请关闭旧工程并确认目标只是可重建的发布副本。
- Stage-3/4A 默认使用 `tb_fista_top_q11_one_iter`。Stage-4B 默认独立对偶投影单测。Stage-4C 默认 TV Prox A/B；Stage-3 到 4C 的完整版仿真均选 `tb_fista_top_q11_full`，并确保执行 `run all`。完整仿真可能较长。
- Stage-5B 项目顶层 `stage5b_uart_fista_top` 默认 40 轮；`tb_stage5b_uart_fista_one_iter` 只用于一轮端到端仿真。若 `$readmemh` 报错，确认 Tcl 通过 `add_files` 加入了正确的 stage-local 向量，且 XSim 工作目录出现对应文件；不要换成其他阶段的同名文件。

## 上板及 GUI

在 Vivado 为 `stages/stage5b_uart_fista` 执行同样的建工程操作；综合 → 实现 → 查看 50 MHz 时序和 DRC → Generate Bitstream → Hardware Manager 将新生成的 `.bit` 下载到 AX7020。不要使用 Stage-5A 的回环固件代替。选择正确串口，关闭其他占用该端口的程序。

```powershell
Set-Location stages/stage5b_uart_fista
python -m pip install pyserial Pillow
python scripts/verify_package.py
# COM3 只是示例，替换为实际端口
python scripts/stage5b_reconstruct.py --port COM3 --dataset cat64
```

在 `stages/stage5d_single_pixel_gui` 安装其 `requirements.txt`，运行 `python scripts/self_test_stage5d.py`（离线），再运行 `python stage5d_gui.py`。首次选择预设后先载入测量，接着测试板级连接，再点击 40 轮 FPGA 重建。预设的 1024 个测量值和 4096 个黄金输出是冻结文件。GUI 自动导出到自己的 `results/`，默认不入 Git。外部测量应为固定掩码/归一化/顺序下的 1024 个 signed S32.F11 值；光学来源需要额外标定与来源核验。

## Stage-6A（仅软件）

准备图像后，进入 `stages/stage6a_quality_opt_package`：

```powershell
python -m pip install -r requirements.txt
python run_stage6a_quality_sweep.py --phase lambda --out local_reports
python run_additional_probes.py
```

第一条实验只扫 λ，`--phase all` 另含迭代数与掩码敏感性。补充探针写入该阶段的本地 `reports/`；归档数据位于仓库顶层 `results/quality/`，不会被这些命令覆盖。保留该阶段工作目录下的冻结 Python 参考和黄金向量，结果不是 RTL 数值变更的验收依据。

## 后续同步

首发通过审核并设置远程后，从仓库根运行 `git status --short`、`git add -- <明确要提交的路径>`、`git diff --cached --stat`、`git commit -m "Add Stage-6A experiment"`、`git push`。不要用 `git add -f` 把本地数据或烧录文件绕过忽略规则。
