// SPDX-License-Identifier: GPL-3.0-or-later
// MacFrame Control Center — Standalone macOS App for controlling IINA frame interpolation

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class MacFrameViewModel: ObservableObject {
    // User Control State
    @Published var enabled: Bool = true
    @Published var fpsMode: Int32 = 0          // 0=Display, 1=Fixed, 2=Double
    @Published var maxFpsCap: Double = 120.0   // 30..240
    @Published var preset: Int32 = 0           // 0=Film, 1=Anime, 2=Sports, 3=Custom
    @Published var backend: Int32 = 1          // 1=MF-Flow, 2=VT-FRC, 0=Auto
    @Published var quality: Float = 1.0
    @Published var artifactGuard: Float = 0.65
    @Published var smoothness: Float = 0.95
    @Published var sceneDetect: Bool = true
    @Published var dedup: Bool = true
    @Published var staticLock: Bool = true
    @Published var letterboxGuard: Bool = true
    @Published var governor: Bool = true
    @Published var debugOsd: Bool = false

    // Live Telemetry State from IINA
    @Published var isPlaybackActive: Bool = false
    @Published var videoWidth: Int32 = 0
    @Published var videoHeight: Int32 = 0
    @Published var sourceFps: Double = 0.0
    @Published var outputFps: Double = 0.0
    @Published var gpuTimeAvgMs: Double = 0.0
    @Published var gpuTimeP99Ms: Double = 0.0
    @Published var currentTier: Int32 = 4
    @Published var meanConfidence: Float = 1.0
    @Published var fallbackRatio: Float = 0.0
    @Published var sceneCuts: UInt64 = 0
    @Published var dedupDrops: UInt64 = 0
    @Published var framesOut: UInt64 = 0

    // IINA Integration Management
    @Published var targetIinaPath: String = "/Applications/IINA.app"
    @Published var iinaInstalledStatus: String = "检测中..."
    @Published var isEngineInstalledInTarget: Bool = false
    @Published var statusLogMessage: String = ""

    private var ipcPtr: UnsafeMutablePointer<mf_ipc_state>?
    private var timer: Timer?
    private var isLoadingInitial = false

    init() {
        let testCopy = NSHomeDirectory() + "/Applications/IINA-MacFrame.app"
        if FileManager.default.fileExists(atPath: testCopy) {
            targetIinaPath = testCopy
        }
        ipcPtr = mf_ipc_open()
        loadFromIPC()
        refreshIinaInstallStatus()

        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollTelemetry()
            }
        }
    }

    func loadFromIPC() {
        guard let st = ipcPtr else { return }
        isLoadingInitial = true
        enabled        = st.pointee.enabled != 0
        fpsMode        = st.pointee.fps_mode
        maxFpsCap      = st.pointee.max_fps_cap >= 24.0 ? st.pointee.max_fps_cap : 120.0
        preset         = st.pointee.preset
        backend        = st.pointee.backend
        quality        = st.pointee.quality
        artifactGuard  = st.pointee.artifact_guard
        smoothness     = st.pointee.smoothness
        sceneDetect    = st.pointee.scene_detect != 0
        dedup          = st.pointee.dedup != 0
        staticLock     = st.pointee.static_lock != 0
        letterboxGuard = st.pointee.letterbox_guard != 0
        governor       = st.pointee.governor != 0
        debugOsd       = st.pointee.debug_osd != 0
        isLoadingInitial = false
        syncToIPC()
    }

    func applyPresetDefaults(_ newPreset: Int32) {
        preset = newPreset
        switch newPreset {
        case 0: // Film / Cinema
            smoothness     = 0.90
            artifactGuard  = 0.60
            quality        = 1.00
            dedup          = false
            sceneDetect    = true
            staticLock     = true
            letterboxGuard = true
        case 1: // Anime (2s/3s Dedup + Line Guard)
            smoothness     = 1.00
            artifactGuard  = 0.82
            quality        = 1.00
            dedup          = true
            sceneDetect    = true
            staticLock     = true
            letterboxGuard = true
        case 2: // Sports / 120Hz High-Speed
            smoothness     = 1.00
            artifactGuard  = 0.65
            quality        = 1.00
            dedup          = false
            sceneDetect    = true
            staticLock     = true
            letterboxGuard = false
        default:
            break
        }
        syncToIPC()
    }

    func syncToIPC() {
        if isLoadingInitial { return }
        guard let st = ipcPtr else { return }
        st.pointee.enabled         = enabled ? 1 : 0
        st.pointee.fps_mode        = fpsMode
        st.pointee.max_fps_cap     = maxFpsCap
        st.pointee.preset          = preset
        st.pointee.backend         = backend
        st.pointee.quality         = quality
        st.pointee.artifact_guard  = artifactGuard
        st.pointee.smoothness      = smoothness
        st.pointee.scene_detect    = sceneDetect ? 1 : 0
        st.pointee.dedup           = dedup ? 1 : 0
        st.pointee.static_lock     = staticLock ? 1 : 0
        st.pointee.letterbox_guard = letterboxGuard ? 1 : 0
        st.pointee.governor        = governor ? 1 : 0
        st.pointee.debug_osd       = debugOsd ? 1 : 0
        st.pointee.config_seq     += 1
        mf_ipc_write_plugin_json(st)
    }

    func pollTelemetry() {
        guard let st = ipcPtr else { return }
        let now = mf_ipc_now_ms()
        let hb = st.pointee.heartbeat_ms
        let active = (hb > 0 && now >= hb && (now - hb) < 2000) && enabled
        isPlaybackActive = active
        if active {
            videoWidth     = st.pointee.video_width
            videoHeight    = st.pointee.video_height
            sourceFps      = st.pointee.source_fps
            outputFps      = st.pointee.output_fps
            gpuTimeAvgMs   = st.pointee.stats.gpu_time_ms_avg
            gpuTimeP99Ms   = st.pointee.stats.gpu_time_ms_p99
            currentTier    = st.pointee.stats.current_tier
            meanConfidence = st.pointee.stats.mean_confidence
            fallbackRatio  = st.pointee.stats.fallback_ratio
            sceneCuts      = st.pointee.stats.scene_cuts
            dedupDrops     = st.pointee.stats.dedup_drops
            framesOut      = st.pointee.stats.frames_out
        }
    }

    func refreshIinaInstallStatus() {
        let dylibPath = targetIinaPath + "/Contents/Frameworks/libmacframe.dylib"
        if FileManager.default.fileExists(atPath: dylibPath) {
            isEngineInstalledInTarget = true
            iinaInstalledStatus = "已安装 MacFrame 零拷贝引擎"
        } else if FileManager.default.fileExists(atPath: targetIinaPath) {
            isEngineInstalledInTarget = false
            iinaInstalledStatus = "未安装补帧引擎（原版 IINA 状态）"
        } else {
            isEngineInstalledInTarget = false
            iinaInstalledStatus = "未找到该路径下的 IINA.app"
        }
    }

    private func repoRootPath() -> String {
        // Resolve repository root relative to bundle or known workspace
        let bundlePath = Bundle.main.bundlePath
        let parent1 = (bundlePath as NSString).deletingLastPathComponent
        let parent2 = (parent1 as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: parent2 + "/installer/macframe-install.sh") {
            return parent2
        }
        if FileManager.default.fileExists(atPath: parent1 + "/installer/macframe-install.sh") {
            return parent1
        }
        return FileManager.default.currentDirectoryPath
    }

    func runInstaller(install: Bool) {
        let root = repoRootPath()
        let script = root + (install ? "/installer/macframe-install.sh" : "/installer/macframe-uninstall.sh")
        statusLogMessage = install ? "正在安装 MacFrame 引擎到 \(targetIinaPath)..." : "正在还原原版 IINA..."

        let target = targetIinaPath
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [script, target]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            var output = ""
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                output = String(data: data, encoding: .utf8) ?? ""
            } catch {
                output = "执行失败: \(error.localizedDescription)"
            }
            let code = proc.terminationStatus
            let finalOutput = output
            await MainActor.run {
                self.refreshIinaInstallStatus()
                if code == 0 {
                    self.statusLogMessage = install
                        ? "✅ 已成功安装到 \(target)"
                        : "✅ 已无损还原 \(target) 为原版状态（含原始签名）"
                } else {
                    self.statusLogMessage = "❌ 操作返回错误 (\(code)): \(finalOutput.suffix(180))"
                }
            }
        }
    }

    func launchTargetIina() {
        let url = URL(fileURLWithPath: targetIinaPath)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct ControlCenterView: View {
    @ObservedObject var vm: MacFrameViewModel

    let fpsCaps: [Double] = [60, 90, 120, 144, 240]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                telemetryBanner
                fpsCapCard
                presetAndBackendCard
                slidersCard
                guardsCard
                iinaIntegrationCard
            }
            .padding(20)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 760)
    }

    private var headerCard: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: vm.enabled ? [Color.cyan, Color.blue] : [Color.gray.opacity(0.4), Color.gray.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)
                Image(systemName: vm.enabled ? "sparkles.tv.fill" : "tv")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("MacFrame Control Center")
                        .font(.system(size: 20, weight: .bold))
                    Text(vm.enabled ? "补帧已启用" : "原生直通模式")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(vm.enabled ? Color.cyan.opacity(0.2) : Color.secondary.opacity(0.2))
                        .foregroundColor(vm.enabled ? .cyan : .secondary)
                        .clipShape(Capsule())
                }
                Text(
                    vm.enabled
                        ? "实时作用于 IINA 硬件解码管线 · 修改任意参数立即生效"
                        : "补帧已关闭 — IINA 当前 100% 按照您原本的播放器设置运行"
                )
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { vm.enabled },
                set: { val in
                    vm.enabled = val
                    vm.syncToIPC()
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .scaleEffect(1.25)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var telemetryBanner: some View {
        HStack(spacing: 14) {
            metricBox(
                title: "实时状态",
                value: !vm.enabled
                    ? "已关闭 (原生设置)"
                    : (vm.isPlaybackActive ? "\(vm.videoWidth)×\(vm.videoHeight)" : "等待播放"),
                subtitle: vm.isPlaybackActive ? String(format: "%.1f → %.1f fps", vm.sourceFps, vm.outputFps) : "IINA 未在播放视频"
            )
            metricBox(
                title: "GPU 合成耗时",
                value: vm.isPlaybackActive ? String(format: "%.2f ms", vm.gpuTimeAvgMs) : "—",
                subtitle: vm.isPlaybackActive ? String(format: "P99: %.2f ms", vm.gpuTimeP99Ms) : "零负载待机"
            )
            metricBox(
                title: "画质档位 & 置信度",
                value: vm.isPlaybackActive ? "Q\(vm.currentTier)" : "Q\(Int(round(vm.quality * 3) + 1))",
                subtitle: vm.isPlaybackActive ? String(format: "置信度 %.0f%% · 修复 %.1f%%", vm.meanConfidence * 100, vm.fallbackRatio * 100) : "自适应调速已就绪"
            )
            metricBox(
                title: "防伪影统计",
                value: vm.isPlaybackActive ? "切镜 \(vm.sceneCuts)" : "0",
                subtitle: vm.isPlaybackActive ? "动画去重 \(vm.dedupDrops) 帧" : "切镜/一拍二监测"
            )
        }
    }

    private func metricBox(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
    }

    private var fpsCapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("帧率上限与目标模式 (Frame Rate Cap)")
                .font(.system(size: 14, weight: .semibold))

            Picker("目标帧率策略", selection: Binding(
                get: { vm.fpsMode },
                set: { val in
                    vm.fpsMode = val
                    vm.syncToIPC()
                }
            )) {
                Text("跟随显示器刷新率 (受上限约束)").tag(Int32(0))
                Text("固定输出至帧率上限").tag(Int32(1))
                Text("2x 倍帧模式 (受上限约束)").tag(Int32(2))
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Text("快捷帧率上限:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                ForEach(fpsCaps, id: \.self) { cap in
                    Button(action: {
                        vm.maxFpsCap = cap
                        vm.syncToIPC()
                    }) {
                        Text("\(Int(cap)) fps")
                            .font(.system(size: 12, weight: vm.maxFpsCap == cap ? .bold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(vm.maxFpsCap == cap ? Color.accentColor : Color.secondary.opacity(0.15))
                            .foregroundColor(vm.maxFpsCap == cap ? .white : .primary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("当前上限: \(Int(vm.maxFpsCap)) fps")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }

            HStack {
                Text("自定义上限滑块")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Slider(
                    value: Binding(
                        get: { vm.maxFpsCap },
                        set: { val in
                            vm.maxFpsCap = round(val)
                            vm.syncToIPC()
                        }
                    ),
                    in: 30...240,
                    step: 1
                )
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
        .disabled(!vm.enabled)
        .opacity(vm.enabled ? 1.0 : 0.55)
    }

    private var presetAndBackendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("内容场景预设与算法后端 (Presets & Engine)")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 10) {
                presetButton(id: 0, title: "🎬 电影 / 剧集", desc: "自然胶片感 · 均衡防光晕")
                presetButton(id: 1, title: "🎨 动漫 / 二次元", desc: "一拍二/三去重 · 线稿防双线")
                presetButton(id: 2, title: "⚡ 体育 / 高速", desc: "满帧丝滑 · 大位移搜索")
                presetButton(id: 3, title: "🛠 自定义参数", desc: "手动微调下方滑块")
            }

            Divider()

            HStack {
                Text("核心算法后端:")
                    .font(.system(size: 12, weight: .medium))
                Picker("", selection: Binding(
                    get: { vm.backend },
                    set: { val in
                        vm.backend = val
                        vm.syncToIPC()
                    }
                )) {
                    Text("MF-Flow (自研 Metal 光流 — 极速零拷贝)").tag(Int32(1))
                    Text("Apple VT-FRC (系统 ML 神经网络 + 伪影防护)").tag(Int32(2))
                    Text("自动选择 (Auto)").tag(Int32(0))
                }
                .labelsHidden()
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
        .disabled(!vm.enabled)
        .opacity(vm.enabled ? 1.0 : 0.55)
    }

    private func presetButton(id: Int32, title: String, desc: String) -> some View {
        Button(action: {
            vm.applyPresetDefaults(id)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundColor(vm.preset == id ? .white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(vm.preset == id ? Color.accentColor : Color.secondary.opacity(0.12))
            .foregroundColor(vm.preset == id ? .white : .primary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private var slidersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("平滑度、伪影修复与画质控制 (Smoothness & Repair)")
                .font(.system(size: 14, weight: .semibold))

            sliderRow(
                title: "运动平滑度 (Smoothness)",
                valueText: "\(Int(round(vm.smoothness * 100)))%",
                hint: "100% 为完全均匀插值；调低可保留部分 24p 电影顿挫感，减轻肥皂剧效应",
                value: Binding(
                    get: { Double(vm.smoothness) },
                    set: { val in
                        vm.smoothness = Float(val)
                        vm.preset = 3
                        vm.syncToIPC()
                    }
                )
            )

            sliderRow(
                title: "伪影修复与边缘保护强度 (Artifact Repair)",
                valueText: "\(Int(round(vm.artifactGuard * 100)))%",
                hint: "控制遮挡区域光晕抑制、果冻扭曲回退以及动漫线稿防重影的保护力度",
                value: Binding(
                    get: { Double(vm.artifactGuard) },
                    set: { val in
                        vm.artifactGuard = Float(val)
                        vm.preset = 3
                        vm.syncToIPC()
                    }
                )
            )

            sliderRow(
                title: "光流搜索精度上限 (Quality Ceiling)",
                valueText: "Q\(Int(round(vm.quality * 3) + 1)) (\(Int(round(vm.quality * 100)))%)",
                hint: "Q4 Ultra 启用 6 层金字塔 + 4 次 DIS 亚像素细化；降低可减少笔记本功耗",
                value: Binding(
                    get: { Double(vm.quality) },
                    set: { val in
                        vm.quality = Float(val)
                        vm.syncToIPC()
                    }
                )
            )
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
        .disabled(!vm.enabled)
        .opacity(vm.enabled ? 1.0 : 0.55)
    }

    private func sliderRow(title: String, valueText: String, hint: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.accentColor)
            }
            Slider(value: value, in: 0.0...1.0)
            Text(hint)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private var guardsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("缺陷规避与专项修复开关 (Artifact Mitigation Guards)")
                .font(.system(size: 14, weight: .semibold))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                guardToggle("镜头切换防鬼影 (Scene Cut Guard)", isOn: $vm.sceneDetect)
                guardToggle("动漫一拍二/三去重重建 (Anime Dedup)", isOn: $vm.dedup)
                guardToggle("静止台标/比分牌/字幕锁定 (HUD Lock)", isOn: $vm.staticLock)
                guardToggle("电影上下黑边防溢出 (Letterbox Guard)", isOn: $vm.letterboxGuard)
                guardToggle("自适应性能调速防掉帧 (Governor)", isOn: $vm.governor)
                guardToggle("画面左上角置信度调试条 (Debug Bar)", isOn: $vm.debugOsd)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
        .disabled(!vm.enabled)
        .opacity(vm.enabled ? 1.0 : 0.55)
    }

    private func guardToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: Binding(
            get: { isOn.wrappedValue },
            set: { val in
                isOn.wrappedValue = val
                vm.syncToIPC()
            }
        ))
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iinaIntegrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("IINA 播放器集成管理")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Circle()
                    .fill(vm.isEngineInstalledInTarget ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(vm.iinaInstalledStatus)
                    .font(.system(size: 12, weight: .medium))
            }

            HStack(spacing: 8) {
                Text("目标 IINA 路径:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: { vm.targetIinaPath },
                    set: { val in
                        vm.targetIinaPath = val
                        vm.refreshIinaInstallStatus()
                    }
                )) {
                    Text("/Applications/IINA.app (系统正式版)").tag("/Applications/IINA.app")
                    Text("~/Applications/IINA-MacFrame.app (测试副本)").tag(NSHomeDirectory() + "/Applications/IINA-MacFrame.app")
                }
                .labelsHidden()
            }

            HStack(spacing: 12) {
                Button("一键安装 / 更新引擎到 IINA") {
                    vm.runInstaller(install: true)
                }
                .buttonStyle(.borderedProminent)

                Button("还原原版 IINA (无损卸载)") {
                    vm.runInstaller(install: false)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("启动此 IINA") {
                    vm.launchTargetIina()
                }
                .buttonStyle(.bordered)
            }

            if !vm.statusLogMessage.isEmpty {
                Text(vm.statusLogMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
    }
}

@main
struct MacFrameControlApp: App {
    @StateObject private var vm = MacFrameViewModel()

    var body: some Scene {
        WindowGroup("MacFrame Control Center") {
            ControlCenterView(vm: vm)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            Toggle(vm.enabled ? "已开启补帧 (点击关闭并恢复 IINA 原生设置)" : "已关闭补帧 (点击开启)", isOn: Binding(
                get: { vm.enabled },
                set: { val in
                    vm.enabled = val
                    vm.syncToIPC()
                }
            ))
            Divider()
            Text(vm.isPlaybackActive
                 ? String(format: "播放中: %.0f→%.0ffps (%.1fms Q%d)", vm.sourceFps, vm.outputFps, vm.gpuTimeAvgMs, vm.currentTier)
                 : "状态: 待机")
            Divider()
            Menu("帧率上限: \(Int(vm.maxFpsCap)) fps") {
                ForEach([60.0, 90.0, 120.0, 144.0, 240.0], id: \.self) { cap in
                    Button("\(Int(cap)) fps") {
                        vm.maxFpsCap = cap
                        vm.syncToIPC()
                    }
                }
            }
            Menu("场景预设") {
                Button("🎬 电影 / 剧集 (Film)") { vm.applyPresetDefaults(0) }
                Button("🎨 动漫 / 二次元 (Anime)") { vm.applyPresetDefaults(1) }
                Button("⚡ 体育 / 高速 (Sports)") { vm.applyPresetDefaults(2) }
            }
            Divider()
            Button("退出 MacFrame") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: vm.enabled ? "sparkles.tv.fill" : "tv")
                Text(vm.enabled ? "\(Int(vm.maxFpsCap))" : "OFF")
            }
        }
    }
}
