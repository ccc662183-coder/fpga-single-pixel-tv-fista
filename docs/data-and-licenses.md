# 数据来源与再分发范围

下表身份不是靠文件名猜测：从 scikit-image 0.26.0 取图，按脚本中的灰度/LANCZOS 顺序变换，与工程内保存的输入图逐像素核对。项目中的固定掩码 Hadamard 系数是**模拟测量**；真实的是 FPGA 板端重建和 UART 读回结果。

| 样本 | 对照来源 | 再分发处理 |
| --- | --- | --- |
| cat64 | `skimage.data.chelsea`；摄影 Stefan van der Walt，上游标注 CC0 | 本地重建原图；保留项目的板端输出图。 |
| moon | `skimage.data.moon`；上游样例说明未单独标注明确许可来源 | 不随仓库分发素材 PNG/PGM；示例由本地安装的 scikit-image 获取。保留数值回归/验证必要向量，含可渲染的板端输出；不要默认适用于公开再发布。 |
| rocket | `skimage.data.rocket`，SpaceX Photos，Flickr 图像编号 `16511594820`（DSCOVR 发射）；上游标注 public domain | 本地重建原图；保留项目的板端输出图。 |
| text | `skimage.data.text`，维基媒体 `File:Corner.png`；上游标注 public domain | 本地重建原图；保留项目的板端输出图。 |

来源：scikit-image 的 [`data` API 文档](https://scikit-image.org/docs/0.26.x/api/skimage.data.html)。该项目没有授予第三方素材的独立许可。单独的公开光学数据交付包、论文/手册、往年课程材料、原报告/课件及个人输入图片均未纳入；课程代码也未擅自添加开源许可证。若要改为公开仓库，应先复核课程规定及向量、衍生图像和代码的再分发权。

冻结的 `.mem`、`.hex`、少量 `.bin` 是可复现实验所需的数值夹具，不代表对原始照片或其他第三方素材另行授权。
