# MacFrame — Apple Silicon 原生开源实时补帧引擎（IINA 插件）

[English (README.md)](./README.md) | [架构设计](./docs/ARCHITECTURE.md) | [算法与伪影防护](./docs/ALGORITHM.md) | [安装指南](./docs/INSTALL.md) | [参数调优](./docs/TUNING.md) | [常见问题](./docs/FAQ.md)

**MacFrame** 是专为 **macOS Apple Silicon（M1 / M2 / M3 / M4）** 与 **IINA** 播放器打造的 **GPL-3.0 开源**实时视频补帧插件（SVP 4 Pro 的原生开源替代方案）。

不同于传统方案需要安装 Homebrew、Python、VapourSynth 并强制关闭硬件解码直通（`hwdec=auto-copy`），MacFrame 直接在 IINA 的 `libavfilter` 硬件帧管线中通过 `CVMetalTextureCache` 原生读写 `CVPixelBuffer`（`IOSurface`），实现 **全程 GPU 零拷贝** 的 120Hz ProMotion 实时插帧。

---

## 核心特性

1. **全程 GPU 零拷贝架构**：
   - 直接接收 VideoToolbox 硬解输出的 `NV12`（8-bit）与 `P010`（10-bit HDR）硬件帧，合成后直接交还 mpv 渲染器，无任何 GPU↔CPU 往返拷贝。
2. **混合双后端引擎**：
   - **MF-Flow（默认，自研 Metal 光流引擎）**：6 层高斯金字塔 + 3D 递归搜索（3DRS）+ 去均值与梯度加权代价函数 + 双边矢量中值滤波 + DIS（Dense Inverse Search）亚像素结构张量细化。
   - **Apple VT-FRC（高质量 ML 后端）**：调用 Apple Silicon 原生 `VTFrameProcessor`（`VTFrameRateConversionConfiguration`）机器学习补帧，并叠加 MacFrame 统一伪影防护层。
3. **全方位伪影防护层（Artifact Guard）**：
   - **遮挡感知双向合成**：通过前向/后向光流一致性误差计算逐像素可见度权重 $(v_0, v_1)$，彻底消除前景物体边缘的半透明光晕与拖影。
   - **场景切换零鬼影（`scene`）**：双直方图 L1 距离 + 块残差检测，镜头切换处自动回退至原始帧。
   - **动画一拍二/一拍三去重与节奏重建（`dedup`）**：自动识别 24fps 动画中的重复帧，按真实绘制时间轴均匀插值至 120Hz，并在低置信度区域优先贴合原始帧以防止线稿出现双线。
   - **静止台标/记分牌/字幕锁定（`static_lock`）**：自动锁定连续静止的高对比度叠加层（体育记分牌、电视台标、游戏 HUD、硬字幕），防止被背景运动拉扯变形。
   - **电影黑边保护（`letterbox`）**：自动检测上下黑边并钳制越界运动矢量，黑边边缘绝不溢出。
   - **自适应性能调速器（`Q4..Q0`）**：实时监控每帧 GPU 耗时，确保 120Hz 播放绝不掉帧卡顿。

---

## 实测性能与质量指标（Apple M4, 1080p）

| 测试项目 | 指标 | 线性混合 (Blend) | Apple VT-FRC | **MacFrame MF-Flow** |
|---|---|---|---|---|
| 合成亚像素平移基准 | 光流端点误差 (EPE) | — | — | **0.021 – 0.066 px** |
| 合成亚像素平移基准 | PSNR / SSIM | 44.79 dB / 0.9968 | 54.74 dB / 0.9990 | **56.46 dB / 0.9992** |
| 遮挡 + 静止台标基准 | 台标区域 PSNR | 31.20 dB | 48.10 dB | **55.65 dB** |
| 电影宽银幕黑边基准 | 黑边区域 PSNR | 99.00 dB | 99.00 dB | **99.00 dB** |
| 真实视频抽帧还原 (*Big Buck Bunny* 1080p60) | 平均 PSNR / SSIM | 44.98 dB / 0.9866 | 47.15 dB / 0.9868 | **47.72 dB / 0.9869** |
| 1080p 24fps → 120fps 实时吞吐 | 等效输出帧率 / 单帧耗时 | >1000 fps | ~105 fps | **468.1 fps (2.47 ms/帧)** |

---

## 快速安装与使用

### 1. 一键安装到 IINA
在终端运行（或直接在 Finder 双击 **`Install MacFrame.command`**）：
```bash
./installer/macframe-install.sh /Applications/IINA.app
```
> 开发/测试也可指定副本路径：`./installer/macframe-install.sh ~/Applications/IINA-MacFrame.app`

### 2. 在 IINA 中控制
打开 IINA 播放任意视频，点击顶部菜单栏 **Plugin（插件）→ MacFrame** 或使用快捷键：
- **⌘⇧M**：开启 / 关闭 MacFrame 补帧
- **⌘⇧1**：切换至 **电影/剧集预设（Film）**
- **⌘⇧2**：切换至 **动画预设（Anime：一拍二/三去重 + 线稿保护）**
- **⌘⇧3**：切换至 **体育/高速运动预设（Sports 120Hz）**
- **⌘⇧O**：显示 / 隐藏实时性能与状态 HUD 浮层

### 3. 一键卸载还原
双击 **`Uninstall MacFrame.command`** 或运行：
```bash
./installer/macframe-uninstall.sh /Applications/IINA.app
```
卸载器会从备份还原字节级完全一致的原版 `libavfilter.10.dylib` 及 IINA 原始的 Apple Developer ID 签名。

---

## 开源许可

本项目采用 **GPL-3.0-or-later** 许可证开源，详见 [LICENSE](./LICENSE)。
