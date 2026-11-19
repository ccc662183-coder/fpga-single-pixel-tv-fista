单像素成像硬件 MVP 第五阶段 B：TV 双变量等向投影定点 RTL

目标：验证 TV-FISTA 内部的非线性操作：对于输入向量 v=(vx,vy)，执行
 p = v / max(1, sqrt(vx*vx+vy*vy))。

这项操作对应第二阶段 Python prox_tv_isotropic() 里的 unit=np.maximum(1,np.hypot(nr,nc)) 及 pr=nr/unit,pc=nc/unit。
它还不是完整 TV 近端迭代，更没有实现 FISTA 外层。

接口约定：16 位 signed Q5.11，1.0 = 2048；输入覆盖约 -16 到 +16。
使用两次 16 位乘法、逐位整数开方和串行除法。
对于向量长度 <= 1，原样输出；对于 >1，按 sqrt 整数向下取整后计算投影，并舍入到整数。
此定点算法是 Python 浮点投影的近似，而不是逐位等价的浮点实现。
测试向量 128 组，包含零、单位边界、极值和随机数。与独立生成的整数参考值严格核对。
组合整数计算模型的最大分量误差（相对于连续浮点投影）：0.00027082

使用步骤：
1. 解压整个 ZIP 到 <checkout>\single_pixel\stage5b_tv_proj
2. Vivado 2019.2 Tcl Console：
   cd "<checkout>/single_pixel/stage5b_tv_proj"
   source ./create_vivado_project.tcl
3. Run Behavioral Simulation，输入：run all
4. 应显示：
   PASS: isotropic TV dual projection 128 / 128 (Q5.11 integer reference)
   PASS: zero vector, unit boundary, overflow-edge and random inputs
   ALL TESTS PASSED: Stage-5B serial TV dual projection RTL
5. 仿真 PASS 后运行 Run Synthesis，检查 LUT、FF、DSP 占用。

主要限制：
- 该 RTL 是单点投影处理核，不包含 128×128 图片缓存、梯度散度的数据通路和 TV 迭代控制。
- 当前平方运算会使用 DSP 或 LUT；时钟资源与后布线时序须由 Vivado 验证。
- 若发现大量 LUT、极差时序或匹配失败，请上传日志，不要随意改关键位宽。
- 由于只比较这一步的整数参考，尚不代表完整定点 TV-FISTA 最终重建图与浮点算法一致。
- 正式项目还需要真实的 PS/PL 上板验证。
