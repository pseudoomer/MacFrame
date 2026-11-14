# MacFrame — Apple Silicon 原生开源实时补帧引擎（IINA 插件）

[English (README.md)](./README.md) | [架构设计](./docs/ARCHITECTURE.md) | [算法与伪影防护](./docs/ALGORITHM.md) | [安装指南](./docs/INSTALL.md) | [参数调优](./docs/TUNING.md) | [常见问题](./docs/FAQ.md)

**MacFrame** 是专为 **macOS Apple Silicon（M1 / M2 / M3 / M4）** 与 **IINA** 播放器打造的 **GPL-3.0 开源**实时视频补帧插件（SVP 4 Pro 的原生开源替代方案）。

不同于传统方案需要安装 Homebrew、Python、VapourSynth 并强制关闭硬件解码直通（`hwdec=auto-copy`），MacFrame 直接在 IINA 的 `libavfilter` 硬件帧管线中通过 `CVMetalTextureCache` 原生读写 `CVPixelBuffer`（`IOSurface`），实现 **全程 GPU 零拷贝** 的 120Hz ProMotion 实时插帧。

---

## 核心特性

1. **独立原生控制中心 `MacFrame.app` + 关闭补帧零侵入保证**：
   - 提供原生 macOS 桌面应用 **`MacFrame.app`**（含独立控制面板窗口与系统顶部菜单栏常驻图标），实时控制：
     - **全局补帧开关（Master Enable / Disable）**：关闭补帧时，IINA **100% 按用户原本的设置运行**（自动还原用户原有的 `hwdec`、`video-sync`、`interpolation` 与自定义 `vf` 滤镜，且底层引擎立即进入零开销直通模式，绝不残留任何修改）。
     - **帧率上限与目标模式**：一键选择 `60 / 90 / 120 / 144 / 240 fps` 上限（或 `30..240 fps` 无级滑块），支持「跟随显示器刷新率（受上限约束）」、「固定输出至帧率上限」、「2x 倍帧模式」。
     - **平滑与伪影修复实时调节**：无级调节 **平滑度（Smoothness）**、**伪影修复与回退强度（Artifact Guard）**、**画质档位上限（Quality Ceiling）**，以及 6 项独立特性开关（场景切镜零鬼影、动画一拍二/三去重、静止台标/字幕锁定、电影黑边保护、自适应性能调速器、底部置信度色条），**播放中拖动滑块无需重建滤镜即可逐帧实时生效**。
     - **实时遥测监控与一键安装/还原**：面板内实时显示 IINA 当前分辨率、输入→输出帧率、GPU 单帧耗时（Avg / P99）、光流置信度与切镜/去重计数，并内置一键安装/无损还原 IINA 的图形化按钮。
2. **全程 GPU 零拷贝架构**：
   - 直接接收 VideoToolbox 硬解输出的 `NV12`（8-bit）与 `P010`（10-bit HDR）硬件帧，合成后直接交还 mpv 渲染器，无任何 GPU↔CPU 往返拷贝。
3. **混合双后端引擎**：
   - **MF-Flow（默认，自研 Metal 光流引擎）**：6 层高斯金字塔 + 3D 递归搜索（3DRS）+ 去均值与梯度加权代价函数 + 双边矢量中值滤波 + DIS（Dense Inverse Search）亚像素结构张量细化。
   - **Apple VT-FRC（高质量 ML 后端）**：调用 Apple Silicon 原生 `VTFrameProcessor`（`VTFrameRateConversionConfiguration`）机器学习补帧，并叠加 MacFrame 统一伪影防护层。
4. **全方位伪影防护层（Artifact Guard）**：
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

### 2. 使用独立控制应用 `MacFrame.app`
启动 **`MacFrame.app`**（安装脚本会自动将其安装至 `/Applications/MacFrame.app` 或 `~/Applications/MacFrame.app`，也可从 `build/MacFrame.app` 直接打开）：
- 在主窗口或顶部状态栏图标中随时 **开启 / 关闭补帧**（关闭时 IINA 自动恢复您原本的所有设置）。
- 自由设定 **帧率上限（60 / 90 / 120 / 144 / 240 fps）**、**平滑度**、**伪影修复强度** 以及各项防护特性。
- 同时也可在 IINA 内使用 **Plugin（插件）→ MacFrame** 菜单或快捷键（`⌘⇧M` 开关补帧、`⌘⇧1/2/3` 切换预设、`⌘⇧O` 开关 HUD）。

### 3. 一键卸载还原
双击 **`Uninstall MacFrame.command`** 或运行：
```bash
./installer/macframe-uninstall.sh /Applications/IINA.app
```
卸载器会从备份还原字节级完全一致的原版 `libavfilter.10.dylib` 及 IINA 原始的 Apple Developer ID 签名。

---

## 开源许可

本项目采用 **GPL-3.0-or-later** 许可证开源，详见 [LICENSE](./LICENSE)。
