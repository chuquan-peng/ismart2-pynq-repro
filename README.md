# iSmart2 on PYNQ-Z1 — 复现记录

在 Vivado 2018.2 + PYNQ-Z1 上复现 iSmart2（DAC-SDC 2018 参赛的 MobileNet 目标检测加速器），完成从 HLS 综合到上板推理的完整闭环。

本仓库**只包含复现过程中我自己的产出**：工具链问题的修复、改写的板上 host 代码、构建与运行结果。原工程的 HLS 源码与训练权重不在此处，请向原作者获取。

---

## 结果

| 项目 | 数值 |
|---|---|
| 目标板卡 | PYNQ-Z1（xc7z020clg400-1） |
| 实现频率 | 83.333 MHz |
| 时序 | WNS +0.068 ns，WHS +0.051 ns，0 failing endpoints |
| 单帧延迟 | 198.7 ms |
| 吞吐 | 5.0 FPS |
| PYNQ 镜像 | v3.0.1 |

资源占用（Zynq-7020）：

| 资源 | 用量 | 占比 |
|---|---|---|
| Slice LUTs | 30,710 / 53,200 | 57.73% |
| Slice Registers | 20,370 / 106,400 | 19.14% |
| Block RAM Tile | 132 / 140 | **94.29%** |
| DSPs | 82 / 220 | 37.27% |

> 说明：推理用的是一张合成测试图，**未做精度评估**，不含 mAP 数据，也未与原版在 DAC 数据集上的成绩作对比。本仓库只验证硬件通路可用。

---

## 性能瓶颈分析

把上面两组数字放在一起看，能定位这个设计的瓶颈所在。

### 实测延迟 vs 计算下界

先估一个纯计算的下界 —— 假设数据永远就绪、阵列永不空转：

```
计算下界 = 总 MAC 数 / (并行度 × 频率)
```

- 总 MAC 数：MobileNet 在 320×160 输入下约 1×10⁸ 量级
- 并行度：16（HLS 顶层函数名 `compute_engine_16`，权重数组按 `[N][16][16]` 分块）
- 频率：83.333 MHz

```
1e8 / (16 × 83.3e6) ≈ 75 ms
```

实测 198.7 ms，是下界的约 **2.6 倍**。差出来的 ~120 ms 不在算术单元里，而在数据搬运与层间等待上。

### 资源画像佐证

| 资源 | 占比 | 读法 |
|---|---|---|
| Block RAM | **94.29%** | 几乎用尽 |
| DSP | 37.27% | 还剩近三分之二 |
| LUT | 57.73% | 中等 |

片上存储先于算力耗尽。BRAM 塞满意味着权重与中间特征图无法常驻片上，层与层之间必须反复经 DDR 中转 —— 每一次中转都是算术单元的空转周期。

### 推论

这个设计是**访存受限（memory-bound）**，不是计算受限。两条推论：

1. 单纯提频或增加 DSP 并行度，收益会被访存带宽吃掉。时序上 83 MHz 的 WNS 只有 +0.068 ns，继续提频本身也已接近极限。
2. 有效的方向在片上存储一侧：提高权重与特征图的复用率、改进分块（tiling）策略减少层间往返、或引入数据流调度让搬运与计算重叠。

> 以上为基于本次构建数据的推断，未经进一步实验（如逐层周期拆分、DMA 带宽实测）验证。总 MAC 数为量级估算，非逐层精确统计。

---

## 工具链问题与修复

### 1. `core_revision` 整数溢出 — Vivado 2018.2 `[IMPL 213-28]`

HLS 导出 IP 时，revision 号由系统日期按 `YYMMDDHHMM` 生成。2022 年以后这个数值超出 int32 范围，导出失败。

修复：让 HLS 导出先失败，改 `run_ippack.tcl` 第 64 行的 `set Revision` 为一个 2018 年的固定值（如 `1809132310`），再手动执行

```
vivado -mode batch -source run_ippack.tcl
```

把系统时钟改回 2018 年也能绕过，但会影响其他软件，不推荐。

### 2. 时序不收敛

原工程 `FCLK_CLK0` 设为 142.857 MHz，而 HLS 是按 100 MHz 综合的（`ip/script.tcl` 里 `create_clock -period 10`）。实际可达频率约 83 MHz。

修复：`overlay/design_1_wrapper.tcl` 里时钟改为 `83.333336` / `83`。83 MHz 下时序收敛，WNS +0.068 ns。

### 3. `build_all.tcl` 顶层模块名错误

脚本里写死了 `tutorial_1_wrapper`，应为 `design_1_wrapper`。

### 4. HLS 重复触发

HLS 跑完之后再执行 `build_all.tcl` 会重新触发问题 1。`patches/build_nohls.tcl` 是去掉 HLS 步骤的精简版，直接从 IP 打包走到比特流。

### 5. 其他

- 工程必须放在短路径（如 `C:\w\`），否则触碰 Windows 260 字符路径上限
- PYNQ-Z1 的 board files 不在 Digilent 官方 vivado-boards 仓库，需从 [cathalmccabe/pynq-z1_board_files](https://github.com/cathalmccabe/pynq-z1_board_files) 获取
- Vivado 2023.1 不可用：无 Zynq-7000 器件支持，且不含 `vivado_hls`

---

## 板上 host 代码的改写

原版 notebook 跑不起来，三处要改：

### `Xlnk` 已被移除

PYNQ v2.7 起 `pynq.Xlnk` 被 `pynq.allocate` 取代。所有 `xlnk.cma_array(...)` 改为 `allocate(...)`，释放改为 `.freebuffer()`。

### 权重数组尺寸不匹配

原版 notebook 声明的是 `1181 / 46 / 123` 块，但当前 HLS 源码的顶层函数（`net_hls.h`）声明的是：

```c
FIX_16_1 fix_conv_weight_1x1_all[405][16][16],
FIX_16_1 fix_conv_weight_3x3_all[22][16][3][3],
FIX_16_1 fix_bias_all[67][16],
```

即 405 / 22 / 67，合计 107,920 个 uint16 = 215,840 字节。notebook 对应的是另一版网络配置，与本仓库构建出的 bitstream 不配套，故按硬件接口改写。

### 竞赛框架依赖

原版依赖 DAC-SDC 的 `preprocessing.py`（`Agent`、`get_image_batch()`），该文件不在工程包内。改为读单张图片，去掉批处理与 XML 输出。

`notebook/iSmart2_single.ipynb` 是改写后的版本，含完整运行输出。

---

## 权重重排链路

板上加载的权重不是原始训练权重，需经脉动阵列的分块重排：

```
params_384_320_160_v2.bin   (419,448 B, float, 原始权重)
        ↓  reorder_weight_fix()  —— 经 tb.cc 的 C 仿真触发
params_384_fix.bin          (215,840 B, uint16, 405/22/67 块)
```

重排函数是 HLS testbench 的一部分，不单独编译。跑一次 C 仿真即可产出：

```tcl
open_project -reset csim_proj
set_top mobilenet
add_files net_hls.cc
add_files conv_1x1_fl.cc
add_files conv_3x3_group_fl.cc
add_files -tb tb.cc
add_files -tb reorder_weight.cc
add_files -tb output_verify.cc
add_files -tb 1.bin
add_files -tb params_384_320_160_v2.bin
open_solution -reset solution1
set_part {xc7z020clg400-1}
create_clock -period 10 -name default
csim_design
exit
```

`tb.cc` 的 `main()` 会读一张 `1.bin`（3×160×320 的裸 RGB，153,600 字节）。只要重排结果，内容无所谓，可以用全 127 的灰图占位。

产物在 `csim_proj/solution1/csim/build/params_384_fix.bin`。

---

## 板上运行

寄存器地址来自 HLS 生成的驱动头 `xmobilenet_hw.h`：

| 偏移 | 含义 |
|---|---|
| 0x00 | `ap_ctrl`（bit0 = ap_start，bit1 = ap_done，bit2 = ap_idle） |
| 0x10 | image_in_raw_pad |
| 0x18 | conv_weight_1x1_all |
| 0x20 | conv_weight_3x3_all |
| 0x28 | bias_all |
| 0x30 | DDR_pool3_out |
| 0x38 | DDR_pool6_out |
| 0x40 | DDR_buf |
| 0x48 | predict_box |

板上需要四个文件（`.bit` 与 `.hwh` 必须同名，`Overlay()` 按 bit 文件名去找 hwh）：

```
iSmart2.bit
iSmart2.hwh
iSmart2.bin      ← 重排后的权重
test.jpg
```

PYNQ-Z1 直连电脑时板子固定 IP 为 `192.168.2.99`，主机网卡配 `192.168.2.1/24`，浏览器访问 `http://192.168.2.99:9090`。

---

## 目录

```
notebook/   改写后的板上 host notebook（含运行输出）
patches/    构建脚本的修复
results/    时序与资源报告
```

---

## 环境

- Vivado 2018.2 WebPACK（Windows）
- PYNQ-Z1 板卡，PYNQ 镜像 v3.0.1
- 原工程：iSmart2，DAC-SDC 2018

## 声明

原始 HLS 源码、训练权重与网络设计归 iSmart2 原作者所有，不在本仓库内分发。此处仅为复现过程记录与我自己所做修改。
