# iSmart2 on PYNQ-Z1 — Reproduction Notes

*English · [简体中文](README.zh-CN.md)*

Reproducing iSmart2 (a MobileNet object-detection accelerator from the DAC-SDC 2018 contest) on PYNQ-Z1 with Vivado 2018.2, from HLS synthesis all the way to on-board inference.

This repository contains **only my own work**: toolchain fixes, a rewritten on-board host notebook, and build/run results. The original HLS sources and trained weights are not redistributed here — please obtain them from the original authors.

---

## Results

| Item | Value |
|---|---|
| Target board | PYNQ-Z1 (xc7z020clg400-1) |
| Achieved frequency | 83.333 MHz |
| Timing | WNS +0.068 ns, WHS +0.051 ns, 0 failing endpoints |
| Single-frame latency | 198.7 ms |
| Throughput | 5.0 FPS |
| PYNQ image | v3.0.1 |

Resource utilization (Zynq-7020):

| Resource | Used | Utilization |
|---|---|---|
| Slice LUTs | 30,710 / 53,200 | 57.73% |
| Slice Registers | 20,370 / 106,400 | 19.14% |
| Block RAM Tile | 132 / 140 | **94.29%** |
| DSPs | 82 / 220 | 37.27% |

> Note: inference was run on a single synthetic test image. **No accuracy evaluation was performed** — there is no mAP figure here, and no comparison against the original results on the DAC dataset. This repository only verifies that the hardware datapath works.

---

## Bottleneck Analysis

Reading the two tables above together locates where this design is actually limited.

### Measured latency vs. compute lower bound

First, a pure-compute lower bound — assuming data is always ready and the array never stalls:

```
compute lower bound = total MACs / (parallelism × frequency)
```

- Total MACs: roughly 1×10⁸ for MobileNet at 320×160 input
- Parallelism: 16 (the HLS top function is named `compute_engine_16`; weight arrays are tiled as `[N][16][16]`)
- Frequency: 83.333 MHz

```
1e8 / (16 × 83.3e6) ≈ 75 ms
```

Measured latency is 198.7 ms — about **2.6×** the lower bound. The missing ~120 ms is not spent in the arithmetic units; it goes to data movement and inter-layer stalls.

### Resource profile supports this

| Resource | Utilization | Reading |
|---|---|---|
| Block RAM | **94.29%** | nearly exhausted |
| DSP | 37.27% | roughly two thirds still free |
| LUT | 57.73% | moderate |

On-chip storage runs out well before compute does. With BRAM full, weights and intermediate feature maps cannot stay resident on chip, so layers must round-trip through DDR — and every round trip is idle time for the arithmetic units.

### Conclusions

This design is **memory-bound**, not compute-bound. Two implications:

1. Simply raising the clock or adding DSP parallelism would see the gains absorbed by memory bandwidth. Frequency headroom is also nearly gone: WNS at 83 MHz is only +0.068 ns.
2. The productive direction is on the storage side: improve reuse of weights and feature maps, revise the tiling strategy to cut inter-layer round trips, or introduce dataflow scheduling so that transfers overlap with computation.

> The above is inferred from this build's data and has not been verified by further experiments (e.g. per-layer cycle breakdown, measured DMA bandwidth). The MAC count is an order-of-magnitude estimate, not a per-layer tally.

---

## Toolchain Issues and Fixes

### 1. `core_revision` integer overflow — Vivado 2018.2 `[IMPL 213-28]`

When HLS exports the IP, the revision number is generated from the system date as `YYMMDDHHMM`. From 2022 onward this exceeds the int32 range and the export fails.

Fix: let the HLS export fail, edit line 64 of `run_ippack.tcl` (`set Revision`) to a fixed 2018-era value such as `1809132310`, then re-run manually:

```
vivado -mode batch -source run_ippack.tcl
```

Setting the system clock back to 2018 also works around it, but affects everything else on the machine — not recommended.

### 2. Timing not met

The original project sets `FCLK_CLK0` to 142.857 MHz, while the HLS IP was synthesized at 100 MHz (`create_clock -period 10` in `ip/script.tcl`). The actually achievable frequency is around 83 MHz.

Fix: change the clock in `overlay/design_1_wrapper.tcl` to `83.333336` / `83`. Timing closes at 83 MHz with WNS +0.068 ns.

### 3. Wrong top module in `build_all.tcl`

The script hardcodes `tutorial_1_wrapper`; it must be `design_1_wrapper`.

### 4. HLS re-triggered on every build

Running `build_all.tcl` after HLS has already completed re-triggers issue 1. `patches/build_nohls.tcl` is a stripped version that skips HLS and goes straight from IP packaging to bitstream.

### 5. Miscellaneous

- The project must live at a short path (e.g. `C:\w\`) to stay under the Windows 260-character path limit
- PYNQ-Z1 board files are not in Digilent's official vivado-boards repo — get them from [cathalmccabe/pynq-z1_board_files](https://github.com/cathalmccabe/pynq-z1_board_files)
- Vivado 2023.1 is unusable: no Zynq-7000 device support and no `vivado_hls`

---

## Rewriting the On-Board Host Code

The original notebook does not run as-is. Three changes were needed:

### `Xlnk` has been removed

From PYNQ v2.7, `pynq.Xlnk` is replaced by `pynq.allocate`. Every `xlnk.cma_array(...)` becomes `allocate(...)`, and deallocation becomes `.freebuffer()`.

### Weight array dimensions do not match

The original notebook declares `1181 / 46 / 123` tiles, but the top-level function in the current HLS source (`net_hls.h`) declares:

```c
FIX_16_1 fix_conv_weight_1x1_all[405][16][16],
FIX_16_1 fix_conv_weight_3x3_all[22][16][3][3],
FIX_16_1 fix_bias_all[67][16],
```

That is 405 / 22 / 67 tiles — 107,920 uint16 values, or 215,840 bytes. The notebook corresponds to a different network configuration and does not match the bitstream built here, so it was rewritten against the hardware interface.

### Contest framework dependency

The original depends on the DAC-SDC `preprocessing.py` (`Agent`, `get_image_batch()`), which is not part of the project package. Replaced with single-image inference, dropping the batch loop and XML output.

`notebook/iSmart2_single.ipynb` is the rewritten version, with full execution output included.

---

## Weight Reordering Pipeline

The weights loaded on board are not the raw trained weights — they must first be tiled for the systolic array:

```
params_384_320_160_v2.bin   (419,448 B, float, raw weights)
        ↓  reorder_weight_fix()  —— triggered by the C simulation in tb.cc
params_384_fix.bin          (215,840 B, uint16, 405/22/67 tiles)
```

The reordering function is part of the HLS testbench and is not compiled standalone. One C simulation run produces it:

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

`main()` in `tb.cc` reads an image `1.bin` (raw RGB, 3×160×320, 153,600 bytes). Since only the reordering output matters, its content is irrelevant — a flat 127 grey image works as a placeholder.

The output lands at `csim_proj/solution1/csim/build/params_384_fix.bin`.

---

## Running on the Board

Register offsets come from the HLS-generated driver header `xmobilenet_hw.h`:

| Offset | Meaning |
|---|---|
| 0x00 | `ap_ctrl` (bit0 = ap_start, bit1 = ap_done, bit2 = ap_idle) |
| 0x10 | image_in_raw_pad |
| 0x18 | conv_weight_1x1_all |
| 0x20 | conv_weight_3x3_all |
| 0x28 | bias_all |
| 0x30 | DDR_pool3_out |
| 0x38 | DDR_pool6_out |
| 0x40 | DDR_buf |
| 0x48 | predict_box |

Four files are needed on the board (`.bit` and `.hwh` must share a base name — `Overlay()` locates the `.hwh` from the bitstream filename):

```
iSmart2.bit
iSmart2.hwh
iSmart2.bin      ← reordered weights
test.jpg
```

When the PYNQ-Z1 is connected directly to a host, the board's fixed IP is `192.168.2.99`; set the host NIC to `192.168.2.1/24` and open `http://192.168.2.99:9090`.

---

## Layout

```
notebook/   rewritten on-board host notebook (with execution output)
patches/    build script fixes
results/    timing and utilization reports
```

---

## Environment

- Vivado 2018.2 WebPACK (Windows)
- PYNQ-Z1 board, PYNQ image v3.0.1
- Original project: iSmart2, DAC-SDC 2018

## Disclaimer

The original HLS sources, trained weights and network design belong to the iSmart2 authors and are not redistributed in this repository. What is here is a record of the reproduction process and the modifications I made.
