import SwiftUI
import Charts
import AppKit

/// 气体泄漏检测单次采样点（时间秒，关阀/开阀压力 bar，阀门状态与 gas status 用于图中标定）
struct LeakTestSample: Identifiable {
    let id = UUID()
    let time: Double
    /// 关阀压力 (bar)
    let pressure: Double
    /// 开阀压力 (bar)，可选
    let pressureOpen: Double?
    /// 阀门状态，如 "open" / "closed"，用于图中标定变化
    let valveState: String?
    /// Gas system status 原文或短标签，如 "ok" / "leak"，用于图中标定
    let gasSystemStatus: String?
}

/// 产测 / Debug 区域内操作按钮统一宽度，并右对齐
/// 已迁移到 UIDesignSystem.Component.actionButtonWidth
/// 注意：此文件中的 actionButtonWidth 仅用于向后兼容，新代码应直接使用 UIDesignSystem.Component.actionButtonWidth
private let actionButtonWidth: CGFloat = UIDesignSystem.Component.actionButtonWidth

/// Debug 模式：RTC / 阀门 / 压力 区域 + 原有电磁阀与设备 RTC
struct DebugModeView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    @ObservedObject var firmwareManager: FirmwareManager
    /// 手动模式复选框状态（false=auto, true=manual）
    @State private var isManualMode: Bool = false
    /// 是否正在设置阀门（用于阻塞UI）
    @State private var isSettingValve: Bool = false
    /// 气体泄漏检测：持续时间（秒），可调，默认 5 分钟
    @State private var leakTestDurationSeconds: Int = 300
    /// 气体泄漏检测：压力读取间隔（秒），0.1～3.0，步长 0.1，默认 0.5 s
    @State private var leakTestIntervalSec: Double = 0.5
    /// 气体泄漏检测：是否正在检测中
    @State private var isLeakTestRunning: Bool = false
    /// 气体泄漏检测：已采样的 (时间 s, 压力 bar) 点，用于绘图
    @State private var leakTestSamples: [LeakTestSample] = []
    /// 气体泄漏检测：周期读取任务的取消句柄
    @State private var leakTestTask: Task<Void, Never>?
    /// 气体泄漏检测：已运行秒数（检测中时更新，支持小数）
    @State private var leakTestElapsedSec: Double = 0
    /// 气体泄漏检测：当前关阀压力 bar（检测中时更新）
    @State private var leakTestCurrentPressureBar: Double?
    /// 气体泄漏检测：当前开阀压力 bar（检测中时更新）
    @State private var leakTestCurrentPressureOpenBar: Double?
    /// 气体泄漏检测：结果文案（"--" / "检测中" / "无泄漏" / "泄漏" 等，公式可后续替换）
    @State private var leakTestResultMessage: String = ""
    /// 气体泄漏检测：是否启用超过阈值时提示音
    @State private var leakTestAlarmEnabled: Bool = true
    /// 气体泄漏检测：报警阈值 (bar)，压力从该值以下升到以上时响提示音
    @State private var leakTestAlarmThresholdBar: Double = 1.2
    /// 气体泄漏检测：上一拍关阀压力，用于检测“从低于阈值升到高于阈值”
    @State private var leakTestLastPressureForAlarm: Double?
    /// 图表横轴：nil = 显示全部，否则仅显示最后 N 秒
    @State private var leakTestVisibleWindowSeconds: Int? = nil
    /// 图表横轴：是否锁定当前视图（锁定后不再随新数据滚动）
    @State private var leakTestChartLocked: Bool = false
    /// 锁定时的横轴范围 [min, max]（秒）
    @State private var leakTestLockedXMin: Double = 0
    @State private var leakTestLockedXMax: Double = 300
    /// 锁定视图时的窗口长度（秒），用于滑块拖动时保持区间长度不变
    @State private var leakTestLockedWindowLength: Double = 0
    /// 总时长、读取间隔的手动输入文案（与 Stepper 双向同步）
    @State private var leakTestDurationInput: String = "300"
    @State private var leakTestIntervalInput: String = "0.5"
    /// 图表纵轴：是否自动缩放（默认关闭，固定 0～1.5 bar）
    @State private var leakTestAutoYScale: Bool = false
    /// 图表 hover 高亮的样本点与位置（用于鼠标悬停时显示时间、压力与状态）
    @State private var leakTestHoverSample: LeakTestSample?
    @State private var leakTestHoverPosition: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.md) {
            Text(appLanguage.string("debug.title"))
                .font(UIDesignSystem.Typography.sectionTitle)
            
            // 连接/断开按钮区域
            connectionSection

            // 设备操作：恢复出厂（擦除 NVM）、重启（仅 UI，逻辑后续实现）
            deviceActionsSection

            rtcSection
            valveSection
            pressureSection
            gasLeakDetectionSection
            gasSystemStatusSection
            co2PressureLimitsSection
            // 谁调用的 OTA 谁管理：产测 OTA 进行中时 Debug 区不随动，仅提示切回产测
            if ble.isOTAInProgress && ble.otaInitiatedByProductionTest {
                productionTestOTAInProgressHint
            } else {
                OTASectionView(ble: ble, firmwareManager: firmwareManager)
            }
            UUIDDebugView(ble: ble)
        }
        .padding(UIDesignSystem.Padding.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UIDesignSystem.Background.subtle)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
    }
    
    /// 产测 OTA 进行中时在 Debug 区仅显示提示，不随动、不管理（谁调用谁管理）
    private var productionTestOTAInProgressHint: some View {
        HStack(spacing: UIDesignSystem.Spacing.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text(appLanguage.string("debug.ota_production_test_in_progress"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
        }
        .padding(UIDesignSystem.Padding.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(UIDesignSystem.CornerRadius.sm)
    }
    
    // MARK: - 连接区域
    
    /// 获取当前选中的设备
    private var selectedDevice: BLEDevice? {
        guard let deviceId = ble.selectedDeviceId else { return nil }
        return ble.discoveredDevices.first(where: { $0.id == deviceId })
    }
    
    private var connectionSection: some View {
        HStack(spacing: UIDesignSystem.Spacing.md) {
            if ble.isConnected {
                HStack(spacing: UIDesignSystem.Spacing.sm) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text(ble.connectedDeviceName ?? appLanguage.string("device_list.connected"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
                Spacer()
                Button {
                    ble.disconnect()
                } label: {
                    Text(appLanguage.string("device_list.disconnect"))
                        .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                }
                .buttonStyle(.bordered)
                .disabled(ble.isOTAInProgress)
            } else {
                Text(appLanguage.string("debug.connect_first"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Spacer()
                if let device = selectedDevice {
                    Button {
                        ble.connect(to: device)
                    } label: {
                        Text(appLanguage.string("device_list.connect"))
                            .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ble.isOTAInProgress)
                } else {
                    Text(appLanguage.string("device_list.select_device_first"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.sm)
    }
    
    // MARK: - 设备操作（恢复出厂 / 重启）

    private var deviceActionsSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            Text(appLanguage.string("debug.device_actions"))
                .font(UIDesignSystem.Typography.subsectionTitle)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)

            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                Text(appLanguage.string("debug.factory_reset_hint"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Spacer(minLength: UIDesignSystem.Spacing.lg)
                Button {
                    Task { _ = await ble.sendTestingFactoryResetCommand() }
                } label: {
                    Text(appLanguage.string("debug.factory_reset"))
                        .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || !ble.areCharacteristicsReady || ble.isOTAInProgress)
            }

            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                Text(appLanguage.string("debug.reboot_hint"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Spacer(minLength: UIDesignSystem.Spacing.lg)
                Button {
                    Task { _ = await ble.sendTestingRebootCommand() }
                } label: {
                    Text(appLanguage.string("debug.reboot"))
                        .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || !ble.areCharacteristicsReady || ble.isOTAInProgress)
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
    }
    
    // MARK: - RTC 区域（仅 UI）
    
    private var rtcSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            Text(appLanguage.string("debug.rtc"))
                .font(UIDesignSystem.Typography.subsectionTitle)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)

            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                HStack(spacing: UIDesignSystem.Spacing.sm) {
                    Text(appLanguage.string("debug.system_time"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text(ble.lastSystemTimeAtRTCRead)
                        .font(UIDesignSystem.Typography.monospacedCaption)
                }
                .padding(.horizontal, UIDesignSystem.Padding.md)
                .padding(.vertical, UIDesignSystem.Padding.xs)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(UIDesignSystem.CornerRadius.sm)
                Spacer(minLength: UIDesignSystem.Spacing.lg)
                Button {
                    ble.writeRTCTime()
                } label: {
                    Text(appLanguage.string("debug.write_rtc"))
                        .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || !ble.hasRTCRetrievedSuccessfully || ble.isOTAInProgress)
            }

            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                HStack(spacing: UIDesignSystem.Spacing.sm) {
                    Text(appLanguage.string("debug.device_time"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text(ble.lastRTCValue)
                        .font(UIDesignSystem.Typography.monospacedCaption)
                }
                .padding(.horizontal, UIDesignSystem.Padding.md)
                .padding(.vertical, UIDesignSystem.Padding.xs)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(UIDesignSystem.CornerRadius.sm)

                HStack(spacing: UIDesignSystem.Spacing.sm) {
                    Text(appLanguage.string("debug.time_diff"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text(ble.lastTimeDiffFromRTCRead)
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
                Spacer(minLength: UIDesignSystem.Spacing.lg)
                Button {
                    ble.readRTCWithUnlock()
                } label: {
                    Text(appLanguage.string("debug.read_rtc"))
                        .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || !ble.areCharacteristicsReady || ble.isOTAInProgress)
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
    }
    
    // MARK: - 阀门区域
    
    private var valveModeDisplay: String {
        switch ble.lastValveModeValue {
        case "auto": return appLanguage.string("debug.valve_mode_auto")
        case "open": return appLanguage.string("debug.valve_open")
        case "closed": return appLanguage.string("debug.valve_close")
        default: return ble.lastValveModeValue
        }
    }
    
    private var valveStateDisplay: String {
        switch ble.lastValveStateValue {
        case "open": return appLanguage.string("debug.valve_open")
        case "closed": return appLanguage.string("debug.valve_close")
        default: return ble.lastValveStateValue
        }
    }
    
    /// 电磁阀开关：仅在手动模式下使能，操作时阻塞UI直到确认成功
    private var valveSwitchBinding: Binding<Bool> {
        Binding(
            get: { ble.lastValveStateValue == "open" },
            set: { newValue in
                guard isManualMode && !isSettingValve else { return }
                setValveWithBlocking(open: newValue) { _ in }
            }
        )
    }
    
    /// 手动模式复选框绑定：选中时进入手动模式，失败则维持自动
    private var manualModeBinding: Binding<Bool> {
        Binding(
            get: { isManualMode },
            set: { newValue in
                guard !isSettingValve else { return }
                isManualMode = newValue
                if newValue {
                    // 进入手动模式：按当前阀门状态写入开或关，使设备进入手动并保持当前状态
                    let open = (ble.lastValveStateValue != "closed")
                    setValveWithBlocking(open: open) { success in
                        if !success {
                            // 失败则维持自动模式
                            isManualMode = false
                            ble.setValveModeAuto()
                        }
                    }
                } else {
                    // 退出手动模式，设为自动
                    ble.setValveModeAuto()
                }
            }
        )
    }
    
    /// 设置阀门并阻塞UI，直到确认成功或超时3s
    private func setValveWithBlocking(open: Bool, completion: @escaping (Bool) -> Void) {
        guard !isSettingValve else { return }
        isSettingValve = true
        
        // 记录目标状态
        let targetState = open ? "open" : "closed"
        let startTime = Date()
        
        // 设置阀门
        ble.setValve(open: open)
        
        // 使用 Task 监听状态变化，最多等待3秒
        Task { @MainActor in
            var checkCount = 0
            let maxChecks = 30 // 3秒 / 0.1秒 = 30次检查
            
            while checkCount < maxChecks {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
                checkCount += 1
                
                // 检查是否达到目标状态
                if ble.lastValveStateValue == targetState {
                    isSettingValve = false
                    completion(true) // 成功
                    return
                }
                
                // 检查超时
                if Date().timeIntervalSince(startTime) >= 3.0 {
                    isSettingValve = false
                    completion(false) // 超时失败
                    return
                }
            }
            
            // 超时
            isSettingValve = false
            completion(false)
        }
    }
    
    private var valveSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            Text(appLanguage.string("debug.valve"))
                .font(UIDesignSystem.Typography.subsectionTitle)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)

            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                HStack(spacing: UIDesignSystem.Spacing.md) {
                    HStack(spacing: UIDesignSystem.Spacing.sm) {
                        Text(appLanguage.string("debug.valve_mode"))
                            .font(UIDesignSystem.Typography.caption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                        Text(valveModeDisplay)
                            .font(UIDesignSystem.Typography.monospacedCaption)
                    }
                    .padding(.horizontal, UIDesignSystem.Padding.md)
                    .padding(.vertical, UIDesignSystem.Padding.xs)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(UIDesignSystem.CornerRadius.sm)
                    HStack(spacing: UIDesignSystem.Spacing.sm) {
                        Text(appLanguage.string("debug.valve_state"))
                            .font(UIDesignSystem.Typography.caption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                        Text(valveStateDisplay)
                            .font(UIDesignSystem.Typography.monospacedCaption)
                    }
                    .padding(.horizontal, UIDesignSystem.Padding.md)
                    .padding(.vertical, UIDesignSystem.Padding.xs)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(UIDesignSystem.CornerRadius.sm)
                }
                Spacer(minLength: UIDesignSystem.Spacing.lg)
                Button {
                    ble.readValveMode()
                    ble.readValveState()
                } label: {
                    Text(appLanguage.string("debug.read"))
                        .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || !ble.areCharacteristicsReady || ble.isOTAInProgress)
            }
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                Text(appLanguage.string("debug.valve_control_manual"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Spacer()
                HStack(spacing: UIDesignSystem.Spacing.sm) {
                    Toggle("", isOn: manualModeBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    if isSettingValve {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .disabled(!ble.isConnected || !ble.areCharacteristicsReady || ble.isOTAInProgress || isSettingValve)
            }
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                Text(appLanguage.string("debug.valve_switch"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                if let key = ble.valveOperationWarning, !key.isEmpty {
                    Text(appLanguage.string(key))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                HStack(spacing: UIDesignSystem.Spacing.sm) {
                    Toggle("", isOn: valveSwitchBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    if isSettingValve {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .disabled(!ble.isConnected || !ble.areCharacteristicsReady || ble.isOTAInProgress || isSettingValve || !isManualMode)
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
        .onAppear {
            // 连接设备后获取电磁阀状态
            if ble.isConnected && ble.areCharacteristicsReady {
                ble.readValveMode()
                ble.readValveState()
            }
        }
        .onChange(of: ble.isConnected) { connected in
            if connected && ble.areCharacteristicsReady {
                ble.readValveMode()
                ble.readValveState()
            }
        }
        .onChange(of: ble.areCharacteristicsReady) { ready in
            if ready && ble.isConnected {
                ble.readValveMode()
                ble.readValveState()
            }
        }
        .onReceive(ble.$lastValveModeValue) { newValue in
            // 根据设备返回的模式值更新复选框状态
            if newValue == "auto" {
                isManualMode = false
            } else if newValue == "open" || newValue == "closed" {
                isManualMode = true
            }
        }
    }
    
    // MARK: - 压力区域（仅 UI）
    
    private var pressureSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            Text(appLanguage.string("debug.pressure"))
                .font(UIDesignSystem.Typography.subsectionTitle)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)

            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                HStack(spacing: UIDesignSystem.Spacing.md) {
                    HStack(spacing: UIDesignSystem.Spacing.sm) {
                        Text(appLanguage.string("debug.open_pressure"))
                            .font(UIDesignSystem.Typography.caption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                        Text(ble.lastPressureOpenValue)
                            .font(UIDesignSystem.Typography.monospacedCaption)
                    }
                    .padding(.horizontal, UIDesignSystem.Padding.md)
                    .padding(.vertical, UIDesignSystem.Padding.xs)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(UIDesignSystem.CornerRadius.sm)

                    HStack(spacing: UIDesignSystem.Spacing.sm) {
                        Text(appLanguage.string("debug.close_pressure"))
                            .font(UIDesignSystem.Typography.caption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                        Text(ble.lastPressureValue)
                            .font(UIDesignSystem.Typography.monospacedCaption)
                    }
                    .padding(.horizontal, UIDesignSystem.Padding.md)
                    .padding(.vertical, UIDesignSystem.Padding.xs)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(UIDesignSystem.CornerRadius.sm)
                }
                Spacer(minLength: UIDesignSystem.Spacing.lg)
                Button {
                    ble.readPressure()
                    ble.readPressureOpen()
                } label: {
                    Text(appLanguage.string("debug.read"))
                        .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || ble.isOTAInProgress)
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
    }
    
    // MARK: - 气体泄漏检测

    /// 压力超过阈值时播放系统提示音（在检测中由主线程调用），连响两次更明显
    private static func playAlarmSound() {
        guard let sound = NSSound(named: "Glass") else {
            NSSound(named: "Tink")?.play()
            return
        }
        sound.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            sound.stop()
            sound.play()
        }
    }

    /// 从 BLE 压力显示字符串解析 bar 值（如 "0.123 bar" → 0.123，"Error: ..." → nil）
    private static func parseBarFromPressureString(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("Error") else { return nil }
        let parts = t.split(separator: " ")
        guard let first = parts.first else { return nil }
        return Double(first)
    }

    /// 横轴时间刻度步长（秒），根据所选时长取整到 10/15/20/30/60/120
    private static func leakChartTimeStride(durationSeconds: Int) -> Double {
        let d = Double(durationSeconds)
        guard d > 0 else { return 10 }
        let raw = d / 5
        if raw <= 12 { return 10 }
        if raw <= 18 { return 15 }
        if raw <= 25 { return 20 }
        if raw <= 45 { return 30 }
        if raw <= 90 { return 60 }
        return 120
    }

    /// 阀门 / Gas system status 在采样序列中的变化时刻，用于在压力图上标竖线
    private struct LeakTestChangeEvent: Identifiable {
        let id = UUID()
        let time: Double
        /// "valve" | "gas"
        let kind: String
    }

    private var leakTestChangeEvents: [LeakTestChangeEvent] {
        var out: [LeakTestChangeEvent] = []
        var lastValve: String?
        var lastGas: String?
        for s in leakTestSamples {
            if let v = s.valveState, v != lastValve {
                lastValve = v
                out.append(LeakTestChangeEvent(time: s.time, kind: "valve"))
            }
            if let g = s.gasSystemStatus, g != lastGas {
                lastGas = g
                out.append(LeakTestChangeEvent(time: s.time, kind: "gas"))
            }
        }
        return out
    }

    /// 图表横轴范围（秒）。ignoreLock: true 时按未锁定计算，用于按下「锁定」时写入 locked 范围
    private func leakTestChartDomain(ignoreLock: Bool) -> (min: Double, max: Double) {
        if !ignoreLock && leakTestChartLocked {
            return (leakTestLockedXMin, leakTestLockedXMax)
        }
        let duration = Double(leakTestDurationSeconds)
        let currentEnd: Double = isLeakTestRunning
            ? leakTestElapsedSec
            : (leakTestSamples.last?.time ?? duration)
        if let n = leakTestVisibleWindowSeconds, n > 0 {
            let start = max(0, currentEnd - Double(n))
            return (start, max(start + 1, currentEnd))
        }
        // leakTestDurationSeconds == 0 表示「不限制时长」，此时按当前最大时间决定横轴上限
        let baseMax: Double
        if leakTestDurationSeconds <= 0 {
            baseMax = max(currentEnd, 1)
        } else {
            baseMax = max(duration, 1)
        }
        return (0, baseMax)
    }

    /// 当前图表横轴刻度步长（秒），随可见范围长度变化
    private var leakTestChartXStride: Double {
        let (xMin, xMax) = leakTestChartDomain(ignoreLock: false)
        let span = xMax - xMin
        if span <= 0 { return 60 }
        if span <= 30 { return 5 }
        if span <= 60 { return 10 }
        if span <= 120 { return 20 }
        if span <= 300 { return 60 }
        if span <= 600 { return 120 }
        if span <= 3600 { return 300 }
        return 600
    }

    /// 查找与给定时间最近的采样点
    private func nearestLeakTestSample(to time: Double) -> LeakTestSample? {
        guard !leakTestSamples.isEmpty else { return nil }
        var best = leakTestSamples[0]
        var bestDiff = abs(best.time - time)
        for s in leakTestSamples.dropFirst() {
            let d = abs(s.time - time)
            if d < bestDiff {
                bestDiff = d
                best = s
            }
        }
        return best
    }

    /// 锁定视图时可回放的总时间上限（秒）
    private func leakTestLockedTotalMax() -> Double {
        let lastSample = leakTestSamples.last?.time ?? 0
        let elapsed = leakTestElapsedSec
        let configured = Double(max(leakTestDurationSeconds, 0))
        let lockedMax = leakTestLockedXMax
        return max(lastSample, elapsed, configured, lockedMax, 1)
    }

    /// 锁定视图时滑块可用的起始位置上限（秒）
    private var leakTestLockedSliderMaxStart: Double {
        let totalMax = leakTestLockedTotalMax()
        let window = max(leakTestLockedWindowLength, 0)
        return max(0, totalMax - window)
    }

    /// 锁定视图时滑块绑定：控制当前显示区间起点
    private var leakTestLockedSliderBinding: Binding<Double> {
        Binding(
            get: { leakTestLockedXMin },
            set: { newValue in
                let maxStart = leakTestLockedSliderMaxStart
                guard maxStart > 0 else { return }
                let clamped = min(max(0, newValue), maxStart)
                leakTestLockedXMin = clamped
                leakTestLockedXMax = clamped + leakTestLockedWindowLength
            }
        )
    }

    private var gasLeakChart: some View {
        let (xMin, xMax) = leakTestChartDomain(ignoreLock: false)
        let step = leakTestChartXStride
        let timeKey = appLanguage.string("debug.gas_leak_chart_time")
        let closeKey = appLanguage.string("debug.gas_leak_chart_pressure_close")
        let openKey = appLanguage.string("debug.gas_leak_chart_pressure_open")
        
        // 纵轴范围：默认固定 0～1.5 bar；开启自动缩放时按当前采样数据计算包络
        let yDomain: ClosedRange<Double>
        if leakTestAutoYScale, !leakTestSamples.isEmpty {
            var minP = leakTestSamples.first!.pressure
            var maxP = leakTestSamples.first!.pressure
            for s in leakTestSamples {
                minP = min(minP, s.pressure)
                maxP = max(maxP, s.pressure)
                if let o = s.pressureOpen {
                    minP = min(minP, o)
                    maxP = max(maxP, o)
                }
            }
            if minP == maxP {
                // 单点时给一个小范围，避免 flat 线导致纵轴为常数
                minP -= 0.05
                maxP += 0.05
            }
            let padding = (maxP - minP) * 0.1
            let lo = max(0, minP - padding)
            let hi = max(lo + 0.1, maxP + padding)
            yDomain = lo...hi
        } else {
            yDomain = 0...1.5
        }
        
        let baseChart = Chart {
            ForEach(leakTestSamples) { sample in
                LineMark(
                    x: .value(timeKey, sample.time),
                    y: .value(closeKey, sample.pressure)
                )
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(by: .value("", closeKey))
                PointMark(
                    x: .value(timeKey, sample.time),
                    y: .value(closeKey, sample.pressure)
                )
                .foregroundStyle(by: .value("", closeKey))
                .symbolSize(leakTestSamples.count > 50 ? 0 : 20)
                if let open = sample.pressureOpen {
                    LineMark(
                        x: .value(timeKey, sample.time),
                        y: .value(openKey, open)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(by: .value("", openKey))
                    PointMark(
                        x: .value(timeKey, sample.time),
                        y: .value(openKey, open)
                    )
                    .foregroundStyle(by: .value("", openKey))
                    .symbolSize(leakTestSamples.count > 50 ? 0 : 20)
                }
            }
            ForEach(leakTestChangeEvents) { ev in
                RuleMark(x: .value(timeKey, ev.time))
                    .foregroundStyle(ev.kind == "valve" ? Color.blue.opacity(0.5) : Color.orange.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: ev.kind == "valve" ? [] : [4, 2]))
            }
        }
        
        return baseChart
            .chartForegroundStyleScale([
                closeKey: Color.blue,
                openKey: Color.green
            ])
            .chartLegend(position: .top, alignment: .leading, spacing: 8)
            .chartXScale(domain: xMin ... xMax)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: step)) { value in
                    AxisGridLine()
                    if let v = value.as(Double.self) {
                        AxisValueLabel("\(Int(v))")
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: [0, 0.5, 1.0, 1.5]) { value in
                    AxisGridLine()
                    if let v = value.as(Double.self) {
                        let label = v == 0 ? "0 bar" : (v == 1 ? "1 bar" : String(format: "%.1f bar", v))
                        AxisValueLabel(label)
                    }
                }
            }
            .chartYAxisLabel { Text(appLanguage.string("debug.gas_leak_chart_pressure_label")) }
            .chartXAxisLabel { Text(appLanguage.string("debug.gas_leak_chart_time_label")) }
            .chartOverlay { proxy in
                gasLeakHoverOverlay(proxy: proxy, timeKey: timeKey, closeKey: closeKey, openKey: openKey)
            }
    }

    @ViewBuilder
    private func gasLeakHoverOverlay(proxy: ChartProxy, timeKey: String, closeKey: String, openKey: String) -> some View {
        GeometryReader { geo in
            let plotFrame = geo[proxy.plotAreaFrame]

            // 鼠标悬停时，根据 X 坐标反查时间与最近采样点
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard plotFrame.contains(location) else {
                            leakTestHoverSample = nil
                            leakTestHoverPosition = nil
                            return
                        }
                        guard let t: Double = proxy.value(atX: location.x, as: Double.self),
                              let sample = nearestLeakTestSample(to: t) else {
                            leakTestHoverSample = nil
                            leakTestHoverPosition = nil
                            return
                        }
                        leakTestHoverSample = sample
                        if let xInPlot = proxy.position(forX: sample.time) {
                            // Charts 1.0 返回的是横坐标 CGFloat，而非 CGPoint；纵坐标用绘图区上方固定位置
                            let x = xInPlot + plotFrame.origin.x
                            let y = plotFrame.minY + 24
                            leakTestHoverPosition = CGPoint(x: x, y: y)
                        } else {
                            leakTestHoverPosition = nil
                        }
                    case .ended:
                        leakTestHoverSample = nil
                        leakTestHoverPosition = nil
                    }
                }

            if let sample = leakTestHoverSample,
               let pt = leakTestHoverPosition {
                // 垂直参考线
                Path { path in
                    path.move(to: CGPoint(x: pt.x, y: plotFrame.minY))
                    path.addLine(to: CGPoint(x: pt.x, y: plotFrame.maxY))
                }
                .stroke(Color.gray.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))

                // tooltip 尺寸与位置，尽量保持在绘图区内
                let tooltipWidth: CGFloat = 210
                let tooltipHeight: CGFloat = 80
                let halfW = tooltipWidth / 2
                let halfH = tooltipHeight / 2
                let rawX = pt.x + 10
                let rawY = pt.y - halfH - 8
                let clampedX = min(max(plotFrame.minX + halfW + 4, rawX), plotFrame.maxX - halfW - 4)
                let clampedY = min(max(plotFrame.minY + halfH + 4, rawY), plotFrame.maxY - halfH - 4)

                let valveLabel: String = {
                    guard let v = sample.valveState else {
                        return "--"
                    }
                    switch v {
                    case "open":
                        return appLanguage.string("debug.valve_open")
                    case "closed":
                        return appLanguage.string("debug.valve_close")
                    default:
                        return v
                    }
                }()

                let gasLabel = sample.gasSystemStatus?.isEmpty == false ? sample.gasSystemStatus! : "--"
                let timeText = String(format: "%.2f s", sample.time)
                let closeText = String(format: "%.4f bar", sample.pressure)
                let openText = sample.pressureOpen.map { String(format: "%.4f bar", $0) } ?? "--"

                VStack(alignment: .leading, spacing: 4) {
                    Text(timeKey + ": " + timeText)
                        .font(UIDesignSystem.Typography.monospacedCaption)
                    Text(closeKey + ": " + closeText)
                        .font(UIDesignSystem.Typography.monospacedCaption)
                    Text(openKey + ": " + openText)
                        .font(UIDesignSystem.Typography.monospacedCaption)
                    HStack(spacing: 8) {
                        Text(appLanguage.string("debug.valve_state") + ": " + valveLabel)
                        Text("Gas: " + gasLabel)
                    }
                    .font(UIDesignSystem.Typography.monospacedCaption)
                }
                .padding(8)
                .background(.thinMaterial)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                )
                .position(x: clampedX, y: clampedY)
            }
        }
    }

    /// 启动气体泄漏检测：轮询在后台执行，仅 BLE 与状态更新上主线程，避免连续读取时主线程被占导致手动改时长等操作卡死
    private func startLeakTestPolling() {
        let duration = Double(leakTestDurationSeconds)
        let infinite = leakTestDurationSeconds == 0
        let interval = leakTestIntervalSec
        let afterReadWaitNs: UInt64 = 600_000_000
        leakTestTask = Task {
            var elapsed: Double = 0
            while !Task.isCancelled && (infinite || elapsed <= duration) {
                let connected: Bool = await MainActor.run { ble.isConnected && ble.areCharacteristicsReady }
                if !connected { break }
                await MainActor.run { leakTestElapsedSec = elapsed }
                await MainActor.run {
                    ble.readPressure(silent: true)
                    ble.readPressureOpen(silent: true)
                    ble.readValveMode()
                    ble.readValveState()
                    ble.readGasSystemStatus(silent: true)
                }
                try? await Task.sleep(nanoseconds: afterReadWaitNs)
                if Task.isCancelled { break }
                let (closeBar, openBar, valveStr, gasStr): (Double?, Double?, String?, String?) = await MainActor.run {
                    (
                        Self.parseBarFromPressureString(ble.lastPressureValue),
                        Self.parseBarFromPressureString(ble.lastPressureOpenValue),
                        ble.lastValveStateValue.isEmpty ? nil : ble.lastValveStateValue,
                        ble.lastGasSystemStatusValue.isEmpty ? nil : ble.lastGasSystemStatusValue
                    )
                }
                await MainActor.run {
                    leakTestCurrentPressureBar = closeBar
                    leakTestCurrentPressureOpenBar = openBar
                    if let bar = closeBar {
                        if leakTestAlarmEnabled, let last = leakTestLastPressureForAlarm,
                           last < leakTestAlarmThresholdBar, bar >= leakTestAlarmThresholdBar {
                            Self.playAlarmSound()
                        }
                        leakTestLastPressureForAlarm = bar
                        leakTestSamples.append(LeakTestSample(
                            time: elapsed,
                            pressure: bar,
                            pressureOpen: openBar,
                            valveState: valveStr,
                            gasSystemStatus: gasStr
                        ))
                    }
                }
                elapsed += interval
                if !Task.isCancelled && !infinite && elapsed <= duration {
                    let remainingSec = interval - 0.6
                    let remainingNs = UInt64(max(0, remainingSec) * 1_000_000_000)
                    if remainingNs > 0 { try? await Task.sleep(nanoseconds: remainingNs) }
                }
            }
            if !Task.isCancelled {
                await MainActor.run {
                    isLeakTestRunning = false
                    leakTestTask = nil
                    evaluateLeakResultFromSamples()
                }
            }
        }
    }

    /// 连接断开时停止气体泄漏检测，避免反复打「未连接或特征不可用」日志
    private func stopLeakTestIfDisconnected() {
        guard isLeakTestRunning, (!ble.isConnected || !ble.areCharacteristicsReady) else { return }
        leakTestTask?.cancel()
        leakTestTask = nil
        isLeakTestRunning = false
        evaluateLeakResultFromSamples()
    }

    /// 根据采样点计算泄漏结果（占位：简单压差；可替换为你的公式）
    private func evaluateLeakResultFromSamples() {
        guard leakTestSamples.count >= 2 else {
            leakTestResultMessage = appLanguage.string("debug.gas_leak_result_insufficient")
            return
        }
        let first = leakTestSamples.first!.pressure
        let last = leakTestSamples.last!.pressure
        let delta = first - last
        // 占位判定：压差 > 0.05 bar 视为可能泄漏；你可在此替换为自己的公式
        if delta > 0.05 {
            leakTestResultMessage = appLanguage.string("debug.gas_leak_result_leak") + " (Δ\(String(format: "%.3f", delta)) bar)"
        } else {
            leakTestResultMessage = appLanguage.string("debug.gas_leak_result_ok") + " (Δ\(String(format: "%.3f", delta)) bar)"
        }
    }

    /// 导出当前泄漏检测的采样数据为 CSV：time, close/open 压力, 阀门状态, Gas system status
    @MainActor
    private func exportLeakTestCSV() {
        guard !leakTestSamples.isEmpty else { return }
        var csv = "time_s,pressure_close_bar,pressure_open_bar,valve_state,gas_system_status\n"
        for s in leakTestSamples {
            let t = String(format: "%.3f", s.time)
            let closeStr = String(format: "%.5f", s.pressure)
            let openStr = s.pressureOpen.map { String(format: "%.5f", $0) } ?? ""
            let valve = s.valveState ?? ""
            let gas = s.gasSystemStatus ?? ""
            // 简单转义双引号
            let escapedValve = valve.replacingOccurrences(of: "\"", with: "\"\"")
            let escapedGas = gas.replacingOccurrences(of: "\"", with: "\"\"")
            csv.append("\(t),\(closeStr),\(openStr),\"\(escapedValve)\",\"\(escapedGas)\"\n")
        }

        let panel = NSSavePanel()
        panel.allowedFileTypes = ["csv"]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let ts = formatter.string(from: Date())
        panel.nameFieldStringValue = "gas_leak_\(ts).csv"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try csv.data(using: .utf8)?.write(to: url)
            } catch {
                // 简单处理：在日志中记录错误
                ble.appendLog("[DBG][GasLeak] 导出 CSV 失败: \(error.localizedDescription)", level: .error)
            }
        }
    }
    
    private var gasLeakDetectionSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
            // 标题 + 开始/停止 同一行
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.sm) {
                Text(appLanguage.string("debug.gas_leak_detection"))
                    .font(UIDesignSystem.Typography.subsectionTitle)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Spacer(minLength: UIDesignSystem.Spacing.sm)
                Group {
                    if isLeakTestRunning {
                        Button {
                            leakTestTask?.cancel()
                            leakTestTask = nil
                            isLeakTestRunning = false
                            evaluateLeakResultFromSamples()
                        } label: {
                            Text(appLanguage.string("debug.gas_leak_stop"))
                                .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            leakTestSamples = []
                            leakTestElapsedSec = 0
                            leakTestCurrentPressureBar = nil
                            leakTestCurrentPressureOpenBar = nil
                            leakTestLastPressureForAlarm = nil
                            leakTestResultMessage = ""
                            leakTestChartLocked = false
                            isLeakTestRunning = true
                            startLeakTestPolling()
                        } label: {
                            Text(appLanguage.string("debug.gas_leak_start"))
                                .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .disabled(!ble.isConnected || ble.isOTAInProgress)
            }

            // 持续时间 | 读取间隔 | 报警阈值 同一行（总时长、读取间隔可手动输入）
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
                    Text(appLanguage.string("debug.gas_leak_duration"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    TextField("", text: $leakTestDurationInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 44, maxWidth: 56)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            let v = Int(leakTestDurationInput.trimmingCharacters(in: .whitespaces)) ?? leakTestDurationSeconds
                            // 0 表示“无限时长”，允许 0～3600
                            let clamped = min(3600, max(0, v))
                            leakTestDurationSeconds = clamped
                            leakTestDurationInput = "\(clamped)"
                        }
                    Text(appLanguage.string("debug.gas_leak_duration_unit"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Stepper("", value: $leakTestDurationSeconds, in: 0...3600, step: 10)
                        .labelsHidden()
                        .onChange(of: leakTestDurationSeconds, perform: { leakTestDurationInput = "\($0)" })
                }
                .disabled(isLeakTestRunning)
                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
                    Text(appLanguage.string("debug.gas_leak_interval"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    TextField("", text: $leakTestIntervalInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 40, maxWidth: 52)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            let v = Double(leakTestIntervalInput.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? leakTestIntervalSec
                            let clamped = min(3.0, max(0.1, v))
                            leakTestIntervalSec = clamped
                            leakTestIntervalInput = String(format: "%.2f", clamped)
                        }
                    Stepper("", value: $leakTestIntervalSec, in: 0.1...3.0, step: 0.1)
                        .labelsHidden()
                        .onChange(of: leakTestIntervalSec, perform: { leakTestIntervalInput = String(format: "%.2f", $0) })
                }
                .disabled(isLeakTestRunning)
                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
                    Toggle("", isOn: $leakTestAlarmEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    Text(appLanguage.string("debug.gas_leak_alarm_threshold"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text(String(format: "%.1f", leakTestAlarmThresholdBar))
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .frame(minWidth: 28, alignment: .trailing)
                    Stepper("", value: $leakTestAlarmThresholdBar, in: 0.5...1.5, step: 0.1)
                        .labelsHidden()
                }
                .disabled(isLeakTestRunning)
            }

            // 显示范围 + 锁定 + 纵轴缩放 同一行
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.sm) {
                Text(appLanguage.string("debug.gas_leak_chart_show"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Picker("", selection: $leakTestVisibleWindowSeconds) {
                    Text(appLanguage.string("debug.gas_leak_chart_show_full")).tag(nil as Int?)
                    Text(appLanguage.string("debug.gas_leak_chart_show_last_10s")).tag(10 as Int?)
                    Text(appLanguage.string("debug.gas_leak_chart_show_last_30s")).tag(30 as Int?)
                    Text(appLanguage.string("debug.gas_leak_chart_show_last_60s")).tag(60 as Int?)
                    Text(appLanguage.string("debug.gas_leak_chart_show_last_120s")).tag(120 as Int?)
                    Text(appLanguage.string("debug.gas_leak_chart_show_last_300s")).tag(300 as Int?)
                    Text(appLanguage.string("debug.gas_leak_chart_show_last_600s")).tag(600 as Int?)
                }
                .labelsHidden()
                .frame(maxWidth: 140)
                .disabled(leakTestChartLocked)
                Button {
                    if leakTestChartLocked {
                        leakTestChartLocked = false
                    } else {
                        let d = leakTestChartDomain(ignoreLock: true)
                        leakTestLockedXMin = d.min
                        leakTestLockedXMax = d.max
                        leakTestLockedWindowLength = max(d.max - d.min, 1)
                        leakTestChartLocked = true
                    }
                } label: {
                    Text(leakTestChartLocked ? appLanguage.string("debug.gas_leak_chart_unlock") : appLanguage.string("debug.gas_leak_chart_lock"))
                        .font(UIDesignSystem.Typography.caption)
                }
                .buttonStyle(.bordered)
                Spacer()
                Toggle("", isOn: $leakTestAutoYScale)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text(appLanguage.string("debug.gas_leak_chart_auto_y"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
            }

            gasLeakChart
                .frame(height: 200)
                .padding(.vertical, UIDesignSystem.Padding.xs)
            
            // 锁定视图时，在底部显示滑块用于拖动当前可见时间区间
            if leakTestChartLocked && leakTestLockedWindowLength > 0 && leakTestLockedSliderMaxStart > 0 {
                HStack(spacing: UIDesignSystem.Spacing.sm) {
                    Text(appLanguage.string("debug.gas_leak_chart_locked_range"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Slider(value: leakTestLockedSliderBinding, in: 0...leakTestLockedSliderMaxStart)
                    Text(String(format: "%.1f–%.1f s", leakTestLockedXMin, leakTestLockedXMax))
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .frame(width: 120, alignment: .trailing)
                }
            }
            HStack(spacing: UIDesignSystem.Spacing.sm) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.blue.opacity(0.5)).frame(width: 8, height: 8)
                    Text(appLanguage.string("debug.gas_leak_chart_legend_valve"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.orange.opacity(0.6)).frame(width: 8, height: 8)
                    Text(appLanguage.string("debug.gas_leak_chart_legend_gas"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
                Spacer()
                Button(appLanguage.string("debug.gas_leak_export_csv")) {
                    exportLeakTestCSV()
                }
                .buttonStyle(.bordered)
                .font(UIDesignSystem.Typography.caption)
                .disabled(leakTestSamples.isEmpty)
            }

            // 已运行 · 关阀 · 开阀 · 结果 同一行
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                Text("\(appLanguage.string("debug.gas_leak_elapsed")) \(isLeakTestRunning ? String(format: "%.1f s", leakTestElapsedSec) : (leakTestSamples.isEmpty ? "--" : String(format: "%.1f s", leakTestElapsedSec)))")
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Text("·")
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Text("\(appLanguage.string("debug.close_pressure")) \(leakTestCurrentPressureBar != nil ? String(format: "%.3f bar", leakTestCurrentPressureBar!) : "--")")
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Text("·")
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Text("\(appLanguage.string("debug.open_pressure")) \(leakTestCurrentPressureOpenBar != nil ? String(format: "%.3f bar", leakTestCurrentPressureOpenBar!) : "--")")
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Text("·")
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Text("\(appLanguage.string("debug.gas_leak_result")) \(leakTestResultMessage.isEmpty ? "--" : leakTestResultMessage)")
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
            }
            .padding(.horizontal, UIDesignSystem.Padding.sm)
            .padding(.vertical, UIDesignSystem.Padding.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(UIDesignSystem.CornerRadius.sm)
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
        .onChange(of: ble.isConnected) { _ in stopLeakTestIfDisconnected() }
        .onChange(of: ble.areCharacteristicsReady) { _ in stopLeakTestIfDisconnected() }
    }
    
    // MARK: - Gas system status 与 CO2 Pressure Limits 区域（仅读，同卡紧凑布局）
    
    private var gasSystemStatusSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            Text(appLanguage.string("debug.gas_system_status"))
                .font(UIDesignSystem.Typography.subsectionTitle)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)

            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                HStack(spacing: UIDesignSystem.Spacing.sm) {
                    Text(ble.lastGasSystemStatusValue)
                        .font(UIDesignSystem.Typography.monospacedCaption)
                }
                .padding(.horizontal, UIDesignSystem.Padding.md)
                .padding(.vertical, UIDesignSystem.Padding.xs)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(UIDesignSystem.CornerRadius.sm)
                Spacer(minLength: UIDesignSystem.Spacing.lg)
                Button {
                    ble.readGasSystemStatus()
                } label: {
                    Text(appLanguage.string("debug.read"))
                        .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || ble.isOTAInProgress)
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
    }
    
    /// CO2 Pressure Limits：6 个 mbar 值，2×3 网格 + 读取按钮
    private var co2PressureLimitsSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            Text(appLanguage.string("debug.co2_pressure_limits"))
                .font(UIDesignSystem.Typography.subsectionTitle)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)

            let lines = ble.lastPressureLimitsValue.isEmpty || ble.lastPressureLimitsValue == "--"
                ? [String]()
                : ble.lastPressureLimitsValue.components(separatedBy: "\n").filter { !$0.isEmpty }
            
            if lines.isEmpty {
                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                    Text("--")
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Spacer(minLength: UIDesignSystem.Spacing.lg)
                    Button {
                        ble.readPressureLimits()
                    } label: {
                        Text(appLanguage.string("debug.read"))
                            .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ble.isConnected || ble.isOTAInProgress)
                }
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading)
                ], spacing: UIDesignSystem.Spacing.xs) {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(UIDesignSystem.Typography.monospacedCaption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, UIDesignSystem.Padding.sm)
                            .padding(.vertical, UIDesignSystem.Padding.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(UIDesignSystem.CornerRadius.sm)
                    }
                }
                HStack {
                    Spacer(minLength: UIDesignSystem.Spacing.lg)
                    Button {
                        ble.readPressureLimits()
                    } label: {
                        Text(appLanguage.string("debug.read"))
                            .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ble.isConnected || ble.isOTAInProgress)
                }
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
    }
}
