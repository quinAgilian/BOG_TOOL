import SwiftUI
import Charts
import AppKit

private enum LeakTestPhase: String, CaseIterable {
    case pre       // 阶段1：入口阀门操作前
    case between   // 阶段1结束与阶段2开始之间（用户手动操作）
    case post      // 阶段2：入口阀门关闭后的观察
}

private enum LeakTestFlowState: String {
    case idle
    case waitingPipelineReadyConfirm
    case samplingBeforeClose
    case waitingValveCloseConfirm
    case samplingAfterClose
    case completed
    case cancelled
}

private enum LeakTestJudgementSource: String, CaseIterable, Identifiable {
    case closed
    case open

    var id: String { rawValue }
}

private enum LeakTestPrompt: String, Identifiable {
    case pipelineReady
    case valveClosed

    var id: String { rawValue }
}

private enum LeakTestSessionType {
    case continuous
    case guided
}

private enum LeakTestKeys {
    static let judgementSource = "debug_gas_leak_judgement_source"
    static let preCloseDuration = "debug_gas_leak_pre_close_duration_seconds"
    static let postCloseDuration = "debug_gas_leak_post_close_duration_seconds"
    static let interval = "debug_gas_leak_interval_seconds"
    static let dropThresholdMbar = "debug_gas_leak_drop_threshold_mbar"
    static let startPressureMinMbar = "debug_gas_leak_start_pressure_min_mbar"
    static let alarmEnabled = "debug_gas_leak_alarm_enabled"
    static let alarmThresholdBar = "debug_gas_leak_alarm_threshold_bar"
    static let requirePipelineReadyConfirm = "debug_gas_leak_require_pipeline_ready_confirm"
    static let requireValveClosedConfirm = "debug_gas_leak_require_valve_closed_confirm"
}

/// 气体泄漏检测单次采样点（时间秒，关阀/开阀压力 bar，阀门状态与 gas status 用于图中标定）
private struct LeakTestSample: Identifiable {
    let id = UUID()
    let time: Double
    let phase: LeakTestPhase
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
    /// 当前/最近一次压力测试会话类型，用于决定哪个 UI 区域展示图表与结果
    @State private var leakTestSessionType: LeakTestSessionType = .continuous
    /// 原始连续读取：总时长（秒），0 表示无限时长
    @State private var leakTestDurationSeconds: Int = 300
    /// 原始连续读取：总时长输入框
    @State private var leakTestDurationInput: String = "300"
    /// 连续压力测试：判定采用的压力源（关阀/开阀）
    @State private var leakTestJudgementSource: LeakTestJudgementSource = {
        LeakTestJudgementSource(rawValue: UserDefaults.standard.string(forKey: LeakTestKeys.judgementSource) ?? "") ?? .closed
    }()
    /// 阶段1：用户关闭入口阀门前的采样时长（秒）
    @State private var leakTestPreCloseDurationSeconds: Int = {
        UserDefaults.standard.object(forKey: LeakTestKeys.preCloseDuration) as? Int ?? 10
    }()
    /// 阶段2：用户关闭入口阀门后的采样时长（秒）
    @State private var leakTestPostCloseDurationSeconds: Int = {
        UserDefaults.standard.object(forKey: LeakTestKeys.postCloseDuration) as? Int ?? 15
    }()
    /// 连续压力测试：压力读取间隔（秒），0.1～3.0，步长 0.1，默认 0.5 s
    @State private var leakTestIntervalSec: Double = {
        UserDefaults.standard.object(forKey: LeakTestKeys.interval) as? Double ?? 0.5
    }()
    /// 气体泄漏检测：是否正在检测中
    @State private var isLeakTestRunning: Bool = false
    /// 连续压力测试：当前流程状态
    @State private var leakTestFlowState: LeakTestFlowState = .idle
    /// 连续压力测试：当前待显示的用户确认弹窗
    @State private var leakTestPendingPrompt: LeakTestPrompt?
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
    /// 连续压力测试：结果明细（采用压力源、两阶段末值、压降、阈值）
    @State private var leakTestResultDetails: String = ""
    /// 气体泄漏检测：是否启用超过阈值时提示音
    @State private var leakTestAlarmEnabled: Bool = {
        UserDefaults.standard.object(forKey: LeakTestKeys.alarmEnabled) as? Bool ?? true
    }()
    /// 气体泄漏检测：报警阈值 (bar)，压力从该值以下升到以上时响提示音
    @State private var leakTestAlarmThresholdBar: Double = {
        UserDefaults.standard.object(forKey: LeakTestKeys.alarmThresholdBar) as? Double ?? 1.2
    }()
    /// 连续压力测试：判定阈值（mbar），压降大于该值则失败
    @State private var leakTestPressureDropThresholdMbar: Double = {
        UserDefaults.standard.object(forKey: LeakTestKeys.dropThresholdMbar) as? Double ?? 15
    }()
    /// 连续压力测试：起始压力下限（mbar），阶段1平均压力低于该值则直接判定失败
    @State private var leakTestStartPressureMinMbar: Double = {
        UserDefaults.standard.object(forKey: LeakTestKeys.startPressureMinMbar) as? Double ?? 1300
    }()
    /// 连续压力测试：开始前是否需要确认“气路已经连接好”
    @State private var leakTestRequirePipelineReadyConfirm: Bool = {
        UserDefaults.standard.object(forKey: LeakTestKeys.requirePipelineReadyConfirm) as? Bool ?? true
    }()
    /// 连续压力测试：阶段切换前是否需要确认“入口阀门已经关闭”
    @State private var leakTestRequireValveClosedConfirm: Bool = {
        UserDefaults.standard.object(forKey: LeakTestKeys.requireValveClosedConfirm) as? Bool ?? true
    }()
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
    /// 规则参数手动输入文案（与 Stepper 双向同步）
    @State private var leakTestPreCloseDurationInput: String = "\(UserDefaults.standard.object(forKey: LeakTestKeys.preCloseDuration) as? Int ?? 10)"
    @State private var leakTestPostCloseDurationInput: String = "\(UserDefaults.standard.object(forKey: LeakTestKeys.postCloseDuration) as? Int ?? 15)"
    @State private var leakTestIntervalInput: String = String(format: "%.2f", UserDefaults.standard.object(forKey: LeakTestKeys.interval) as? Double ?? 0.5)
    @State private var leakTestPressureDropThresholdInput: String = String(format: "%.1f", UserDefaults.standard.object(forKey: LeakTestKeys.dropThresholdMbar) as? Double ?? 15)
    @State private var leakTestStartPressureMinInput: String = String(format: "%.1f", UserDefaults.standard.object(forKey: LeakTestKeys.startPressureMinMbar) as? Double ?? 1300)
    /// 图表纵轴：是否自动缩放（默认关闭，固定 0～1.5 bar）
    @State private var leakTestAutoYScale: Bool = false
    /// 是否在图上绘制 between 段（phase=between）的曲线
    @State private var leakTestShowBetweenPhase: Bool = true
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
            continuousPressureReadSection
            guidedLeakTestSection
            gasSystemStatusSection
            co2PressureLimitsSection
            disableGasSelfCheckSection
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

    private var leakTestConfiguredTotalDurationSeconds: Int {
        let base = max(0, leakTestPreCloseDurationSeconds) + max(0, leakTestPostCloseDurationSeconds)
        var extra = 0
        if leakTestRequirePipelineReadyConfirm {
            extra += 10
        }
        if leakTestRequireValveClosedConfirm {
            extra += 10
        }
        return base + extra
    }

    private var isLeakTestWorkflowActive: Bool {
        leakTestSessionType == .guided && (isLeakTestRunning || leakTestPendingPrompt != nil || leakTestFlowState == .waitingPipelineReadyConfirm || leakTestFlowState == .waitingValveCloseConfirm)
    }

    private var isContinuousPressureReadActive: Bool {
        leakTestSessionType == .continuous && isLeakTestRunning
    }

    private func leakTestPhaseTitle(_ phase: LeakTestPhase) -> String {
        switch phase {
        case .pre:
            return appLanguage.string("debug.gas_leak_phase_before_close")
        case .between:
            return appLanguage.string("debug.gas_leak_phase_between")
        case .post:
            return appLanguage.string("debug.gas_leak_phase_after_close")
        }
    }

    private func leakTestPressureSourceLabel(_ source: LeakTestJudgementSource) -> String {
        switch source {
        case .closed:
            return appLanguage.string("debug.gas_leak_pressure_source_closed")
        case .open:
            return appLanguage.string("debug.gas_leak_pressure_source_open")
        }
    }

    private func leakTestSamples(for phase: LeakTestPhase) -> [LeakTestSample] {
        leakTestSamples.filter { $0.phase == phase }
    }

    private func leakTestPressureValue(for sample: LeakTestSample, source: LeakTestJudgementSource) -> Double? {
        switch source {
        case .closed:
            return sample.pressure
        case .open:
            return sample.pressureOpen
        }
    }

    private func leakTestPhasePressureValues(for phase: LeakTestPhase, source: LeakTestJudgementSource) -> [Double] {
        leakTestSamples(for: phase).compactMap { leakTestPressureValue(for: $0, source: source) }
    }

    private func leakTestAveragePressure(for phase: LeakTestPhase, source: LeakTestJudgementSource) -> Double? {
        let values = leakTestPhasePressureValues(for: phase, source: source)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func leakTestMinimumPressure(for phase: LeakTestPhase, source: LeakTestJudgementSource) -> Double? {
        leakTestPhasePressureValues(for: phase, source: source).min()
    }

    private var leakTestShouldShowReferenceLines: Bool {
        guard leakTestSessionType == .guided else { return false }
        guard leakTestPressureDropThresholdMbar > 0 else { return false }
        guard leakTestAveragePressure(for: .pre, source: leakTestJudgementSource) != nil else { return false }
        return leakTestElapsedSec >= Double(leakTestPreCloseDurationSeconds)
    }

    private var leakTestAverageLineBar: Double? {
        guard leakTestShouldShowReferenceLines else { return nil }
        return leakTestAveragePressure(for: .pre, source: leakTestJudgementSource)
    }

    private var leakTestFailureLineBar: Double? {
        guard leakTestShouldShowReferenceLines,
              let phaseOneAverage = leakTestAveragePressure(for: .pre, source: leakTestJudgementSource)
        else { return nil }
        return phaseOneAverage - leakTestPressureDropThresholdMbar / 1000.0
    }

    private var leakTestAverageLineColor: Color {
        switch leakTestJudgementSource {
        case .closed:
            return .blue
        case .open:
            return .green
        }
    }

    private func appendLeakTestStepLog(_ step: Int, _ message: String, level: BLEManager.LogLevel = .info) {
        ble.appendLog("[DBG][GasLeak][Step \(step)] \(message)", level: level)
    }

    private func persistLeakTestRuleValues() {
        UserDefaults.standard.set(leakTestJudgementSource.rawValue, forKey: LeakTestKeys.judgementSource)
        UserDefaults.standard.set(leakTestPreCloseDurationSeconds, forKey: LeakTestKeys.preCloseDuration)
        UserDefaults.standard.set(leakTestPostCloseDurationSeconds, forKey: LeakTestKeys.postCloseDuration)
        UserDefaults.standard.set(leakTestIntervalSec, forKey: LeakTestKeys.interval)
        UserDefaults.standard.set(leakTestPressureDropThresholdMbar, forKey: LeakTestKeys.dropThresholdMbar)
        UserDefaults.standard.set(leakTestStartPressureMinMbar, forKey: LeakTestKeys.startPressureMinMbar)
        UserDefaults.standard.set(leakTestAlarmEnabled, forKey: LeakTestKeys.alarmEnabled)
        UserDefaults.standard.set(leakTestAlarmThresholdBar, forKey: LeakTestKeys.alarmThresholdBar)
        UserDefaults.standard.set(leakTestRequirePipelineReadyConfirm, forKey: LeakTestKeys.requirePipelineReadyConfirm)
        UserDefaults.standard.set(leakTestRequireValveClosedConfirm, forKey: LeakTestKeys.requireValveClosedConfirm)
    }

    private func syncValveStateForLeakJudgementSource(reason: String, completion: @escaping (Bool) -> Void = { _ in }) {
        let targetOpen = leakTestJudgementSource == .open
        let targetState = targetOpen ? "open" : "closed"
        let targetLabel = targetOpen ? appLanguage.string("debug.valve_open") : appLanguage.string("debug.valve_close")

        guard ble.isConnected, ble.areCharacteristicsReady, !ble.isOTAInProgress else {
            ble.appendLog("[DBG][GasLeak] \(reason)：设备未就绪，暂不切换电磁阀到\(targetLabel)", level: .info)
            completion(false)
            return
        }

        if ble.lastValveStateValue == targetState {
            ble.appendLog("[DBG][GasLeak] \(reason)：电磁阀已是\(targetLabel)状态", level: .info)
            completion(true)
            return
        }

        ble.appendLog("[DBG][GasLeak] \(reason)：正在将电磁阀切换为\(targetLabel)", level: .info)
        setValveWithBlocking(open: targetOpen) { success in
            if success {
                ble.appendLog("[DBG][GasLeak] \(reason)：已确认电磁阀为\(targetLabel)状态", level: .info)
            } else {
                ble.appendLog("[DBG][GasLeak] \(reason)：电磁阀未能确认切换为\(targetLabel)状态", level: .error)
            }
            completion(success)
        }
    }

    private func performLeakTestStartupValveProbe(completion: @escaping (Bool) -> Void) {
        let targetOpen = leakTestJudgementSource == .open
        let targetState = targetOpen ? "open" : "closed"
        let targetLabel = targetOpen ? appLanguage.string("debug.valve_open") : appLanguage.string("debug.valve_close")
        let pressureLabel = leakTestPressureSourceLabel(leakTestJudgementSource)

        guard ble.isConnected, ble.areCharacteristicsReady, !ble.isOTAInProgress else {
            appendLeakTestStepLog(1, "Start 预动作失败：设备未就绪，无法执行电磁阀动作与回读", level: .error)
            completion(false)
            return
        }

        appendLeakTestStepLog(1, "执行 Start 预动作：切换电磁阀到\(targetLabel)，等待 1 秒后回读阀门状态和压力")
        ble.setValve(open: targetOpen)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            guard ble.isConnected, ble.areCharacteristicsReady else {
                appendLeakTestStepLog(1, "Start 预动作失败：回读前连接已断开", level: .error)
                completion(false)
                return
            }

            ble.readValveState()
            ble.readPressure(silent: true)
            ble.readPressureOpen(silent: true)

            try? await Task.sleep(nanoseconds: 700_000_000)

            let closeBar = Self.parseBarFromPressureString(ble.lastPressureValue)
            let openBar = Self.parseBarFromPressureString(ble.lastPressureOpenValue)
            leakTestCurrentPressureBar = closeBar
            leakTestCurrentPressureOpenBar = openBar

            let actualState = ble.lastValveStateValue
            let targetPressure = targetOpen ? openBar : closeBar
            let pressureText = targetPressure.map { String(format: "%.3f bar", $0) } ?? "--"

            if actualState == targetState {
                appendLeakTestStepLog(1, "Start 预动作完成：阀门状态=\(actualState)，\(pressureLabel)=\(pressureText)")
                completion(true)
            } else {
                appendLeakTestStepLog(1, "Start 预动作失败：期望阀门=\(targetLabel)，实际=\(actualState)，\(pressureLabel)=\(pressureText)", level: .error)
                completion(false)
            }
        }
    }

    private func resetLeakTestSession() {
        leakTestSamples = []
        leakTestElapsedSec = 0
        leakTestCurrentPressureBar = nil
        leakTestCurrentPressureOpenBar = nil
        leakTestLastPressureForAlarm = nil
        leakTestResultMessage = ""
        leakTestResultDetails = ""
        leakTestChartLocked = false
        leakTestPendingPrompt = nil
        leakTestFlowState = .idle
        ble.suppressGattLogs = false
    }

    private func startContinuousPressureRead() {
        leakTestSessionType = .continuous
        resetLeakTestSession()
        let clampedDuration = max(0, leakTestDurationSeconds)
        leakTestDurationSeconds = clampedDuration
        leakTestDurationInput = "\(clampedDuration)"
        ble.appendLog(
            "[DBG][Continuous] 开始连续读取：时长=\(clampedDuration == 0 ? "无限" : "\(clampedDuration)s")，间隔=\(String(format: "%.2f", leakTestIntervalSec))s",
            level: .info
        )
        ble.suppressGattLogs = true
        isLeakTestRunning = true
        startContinuousPressureReadPolling()
    }

    private func startGuidedLeakTest() {
        leakTestSessionType = .guided
        resetLeakTestSession()
        persistLeakTestRuleValues()
        appendLeakTestStepLog(
            0,
            "开始连续压力测试：判定压力=\(leakTestPressureSourceLabel(leakTestJudgementSource))，阶段1=\(leakTestPreCloseDurationSeconds)s，阶段2=\(leakTestPostCloseDurationSeconds)s，阈值=\(String(format: "%.1f", leakTestPressureDropThresholdMbar)) mbar"
        )
        ble.suppressGattLogs = true
        performLeakTestStartupValveProbe { success in
            guard success else {
                finishLeakTest(reason: appLanguage.string("debug.gas_leak_stop_reason_valve_sync_failed"))
                return
            }
            if leakTestRequirePipelineReadyConfirm {
                leakTestFlowState = .waitingPipelineReadyConfirm
                leakTestPendingPrompt = .pipelineReady
                appendLeakTestStepLog(2, "等待用户确认气路已连接")
            } else {
                appendLeakTestStepLog(2, "跳过气路确认，直接进入阶段1采样")
                beginLeakTestPhase(.pre, startOffset: 0)
            }
        }
    }

    private func startContinuousPressureReadPolling() {
        let duration = Double(leakTestDurationSeconds)
        let infinite = leakTestDurationSeconds == 0
        let interval = leakTestIntervalSec
        let afterReadWaitNs: UInt64 = 600_000_000
        leakTestTask = Task {
            var elapsed: Double = 0
            var stopReason = "任务结束"
            while !Task.isCancelled && (infinite || elapsed <= duration) {
                let connected: Bool = await MainActor.run { ble.isConnected && ble.areCharacteristicsReady }
                if !connected {
                    stopReason = await MainActor.run {
                        if !ble.isConnected {
                            return appLanguage.string("debug.gas_leak_stop_reason_disconnected")
                        }
                        if !ble.areCharacteristicsReady {
                            return appLanguage.string("debug.gas_leak_stop_reason_gatt_not_ready")
                        }
                        return appLanguage.string("debug.gas_leak_stop_reason_state_invalid")
                    }
                    break
                }
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
                            phase: .pre,
                            pressure: bar,
                            pressureOpen: openBar,
                            valveState: valveStr,
                            gasSystemStatus: gasStr
                        ))
                    }
                }
                elapsed += interval
                if !Task.isCancelled && (infinite || elapsed <= duration) {
                    let remainingSec = interval - 0.6
                    let remainingNs = UInt64(max(0, remainingSec) * 1_000_000_000)
                    if remainingNs > 0 { try? await Task.sleep(nanoseconds: remainingNs) }
                }
            }
            if !Task.isCancelled {
                await MainActor.run {
                    if !infinite && elapsed > duration {
                        stopReason = String(
                            format: appLanguage.string("debug.continuous_pressure_stop_reason_duration"),
                            Int(duration)
                        )
                    }
                    finishLeakTest(reason: stopReason)
                }
            }
        }
    }

    private func continueLeakTestAfterPrompt(_ prompt: LeakTestPrompt) {
        leakTestPendingPrompt = nil
        switch prompt {
        case .pipelineReady:
            appendLeakTestStepLog(2, "用户已确认气路连接完成")
            beginLeakTestPhase(.pre, startOffset: 0)
        case .valveClosed:
            appendLeakTestStepLog(4, "用户已确认入口阀门关闭")
            let startOffset = max(leakTestElapsedSec, Double(leakTestPreCloseDurationSeconds))
            beginLeakTestPhase(.post, startOffset: startOffset)
        }
    }

    private func cancelLeakTestPrompt(_ prompt: LeakTestPrompt) {
        leakTestPendingPrompt = nil
        switch prompt {
        case .pipelineReady:
            appendLeakTestStepLog(2, "用户取消：未确认气路已连接", level: .error)
            finishLeakTest(reason: appLanguage.string("debug.gas_leak_stop_reason_pipeline_not_confirmed"))
        case .valveClosed:
            appendLeakTestStepLog(4, "用户取消：未确认入口阀门已关闭", level: .error)
            finishLeakTest(reason: appLanguage.string("debug.gas_leak_stop_reason_valve_not_confirmed"))
        }
    }

    private func beginLeakTestPhase(_ phase: LeakTestPhase, startOffset: Double) {
        let duration = phase == .pre ? Double(leakTestPreCloseDurationSeconds) : Double(leakTestPostCloseDurationSeconds)
        leakTestFlowState = phase == .pre ? .samplingBeforeClose : .samplingAfterClose
        isLeakTestRunning = true
        let step = phase == .pre ? 3 : 5
        appendLeakTestStepLog(step, "开始\(leakTestPhaseTitle(phase))采样，持续 \(Int(duration)) 秒")
        startLeakTestPolling(phase: phase, startOffset: startOffset, duration: duration)
    }

    private func handleLeakTestPhaseCompletion(_ phase: LeakTestPhase, stopReason: String, reachedDuration: Bool, endElapsed: Double) {
        isLeakTestRunning = false
        leakTestElapsedSec = endElapsed
        if !reachedDuration {
            finishLeakTest(reason: stopReason)
            return
        }
        switch phase {
        case .pre:
            appendLeakTestStepLog(3, "\(leakTestPhaseTitle(phase))采样完成")
            if leakTestRequireValveClosedConfirm {
                leakTestFlowState = .waitingValveCloseConfirm
                leakTestPendingPrompt = .valveClosed
                appendLeakTestStepLog(4, "等待用户确认入口阀门已关闭")
            } else {
                appendLeakTestStepLog(4, "跳过关阀确认，直接进入阶段2采样")
                beginLeakTestPhase(.post, startOffset: endElapsed)
            }
        case .between:
            // between 段在 Debug 模式中由图表逻辑自行决定是否采样/展示，这里不作为独立阶段结束点
            break
        case .post:
            leakTestFlowState = .completed
            appendLeakTestStepLog(5, "\(leakTestPhaseTitle(phase))采样完成")
            finishLeakTest(reason: appLanguage.string("debug.gas_leak_stop_reason_completed"))
        }
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
        let duration = Double(leakTestConfiguredTotalDurationSeconds)
        let currentEnd: Double = isLeakTestRunning
            ? leakTestElapsedSec
            : (leakTestSamples.last?.time ?? duration)
        if let n = leakTestVisibleWindowSeconds, n > 0 {
            let start = max(0, currentEnd - Double(n))
            return (start, max(start + 1, currentEnd))
        }
        let baseMax = max(duration, currentEnd, 1)
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
        let configured = Double(max(leakTestConfiguredTotalDurationSeconds, 0))
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
            if let avgLine = leakTestAverageLineBar {
                minP = min(minP, avgLine)
                maxP = max(maxP, avgLine)
            }
            if let failLine = leakTestFailureLineBar {
                minP = min(minP, failLine)
                maxP = max(maxP, failLine)
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
            if let avgLine = leakTestAverageLineBar {
                RuleMark(y: .value(appLanguage.string("debug.gas_leak_chart_average_line"), avgLine))
                    .foregroundStyle(leakTestAverageLineColor.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [8, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(appLanguage.string("debug.gas_leak_chart_average_line"))
                            .font(UIDesignSystem.Typography.caption)
                            .foregroundStyle(leakTestAverageLineColor)
                    }
            }
            if let failLine = leakTestFailureLineBar {
                RuleMark(y: .value(appLanguage.string("debug.gas_leak_chart_fail_line"), failLine))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
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
                gasLeakHoverOverlay(
                    proxy: proxy,
                    timeKey: timeKey,
                    closeKey: closeKey,
                    openKey: openKey,
                    failLine: leakTestFailureLineBar
                )
            }
    }

    @ViewBuilder
    private func gasLeakHoverOverlay(
        proxy: ChartProxy,
        timeKey: String,
        closeKey: String,
        openKey: String,
        failLine: Double?
    ) -> some View {
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

            if let failLine,
               let yInPlot = proxy.position(forY: failLine) {
                let labelWidth: CGFloat = 72
                let labelHeight: CGFloat = 20
                let x = plotFrame.maxX - labelWidth / 2 - 8
                let y = min(
                    max(plotFrame.minY + labelHeight / 2 + 4, yInPlot + plotFrame.origin.y),
                    plotFrame.maxY - labelHeight / 2 - 4
                )

                Text(appLanguage.string("debug.gas_leak_chart_fail_line"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.red.opacity(0.7), lineWidth: 1)
                    )
                    .cornerRadius(6)
                    .position(x: x, y: y)
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

    /// 启动连续压力测试的单个采样阶段：轮询在后台执行，仅 BLE 与状态更新上主线程
    private func startLeakTestPolling(phase: LeakTestPhase, startOffset: Double, duration: Double) {
        let interval = leakTestIntervalSec
        let afterReadWaitNs: UInt64 = 600_000_000
        leakTestTask = Task {
            var phaseElapsed: Double = 0
            var stopReason = "任务结束"
            while !Task.isCancelled && phaseElapsed <= duration {
                let connected: Bool = await MainActor.run { ble.isConnected && ble.areCharacteristicsReady }
                if !connected {
                    stopReason = await MainActor.run {
                        if !ble.isConnected {
                            return appLanguage.string("debug.gas_leak_stop_reason_disconnected")
                        }
                        if !ble.areCharacteristicsReady {
                            return appLanguage.string("debug.gas_leak_stop_reason_gatt_not_ready")
                        }
                        return appLanguage.string("debug.gas_leak_stop_reason_state_invalid")
                    }
                    break
                }
                await MainActor.run { leakTestElapsedSec = startOffset + phaseElapsed }
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
                            time: startOffset + phaseElapsed,
                            phase: phase,
                            pressure: bar,
                            pressureOpen: openBar,
                            valveState: valveStr,
                            gasSystemStatus: gasStr
                        ))
                    }
                }
                phaseElapsed += interval
                if !Task.isCancelled && phaseElapsed <= duration {
                    let remainingSec = interval - 0.6
                    let remainingNs = UInt64(max(0, remainingSec) * 1_000_000_000)
                    if remainingNs > 0 { try? await Task.sleep(nanoseconds: remainingNs) }
                }
            }
            if !Task.isCancelled {
                await MainActor.run {
                    let reachedDuration = phaseElapsed > duration
                    handleLeakTestPhaseCompletion(
                        phase,
                        stopReason: stopReason,
                        reachedDuration: reachedDuration,
                        endElapsed: startOffset + min(phaseElapsed, duration)
                    )
                }
            }
        }
    }

    /// 统一结束泄漏检测并输出停止原因，避免不同退出路径日志不一致
    @MainActor
    private func finishLeakTest(reason: String) {
        leakTestTask?.cancel()
        leakTestTask = nil
        isLeakTestRunning = false
        leakTestPendingPrompt = nil
        ble.suppressGattLogs = false
        if leakTestSessionType == .guided {
            if leakTestFlowState != .completed {
                leakTestFlowState = .cancelled
            }
            appendLeakTestStepLog(7, "流程结束：\(reason)")
            evaluateLeakResultFromSamples()
        } else {
            leakTestFlowState = .idle
            ble.appendLog("[DBG][Continuous] 连续读取已停止：\(reason)", level: .info)
            evaluateContinuousPressureReadResult()
        }
    }

    /// 连接断开时停止气体泄漏检测，避免反复打「未连接或特征不可用」日志
    private func stopLeakTestIfDisconnected() {
        guard isLeakTestRunning, (!ble.isConnected || !ble.areCharacteristicsReady) else { return }
        let reason: String
        if !ble.isConnected {
            reason = appLanguage.string("debug.gas_leak_stop_reason_disconnected")
        } else if !ble.areCharacteristicsReady {
            reason = appLanguage.string("debug.gas_leak_stop_reason_gatt_not_ready")
        } else {
            reason = appLanguage.string("debug.gas_leak_stop_reason_state_invalid")
        }
        finishLeakTest(reason: reason)
    }

    private func evaluateContinuousPressureReadResult() {
        guard leakTestSamples.count >= 2 else {
            leakTestResultMessage = appLanguage.string("debug.gas_leak_result_insufficient")
            leakTestResultDetails = ""
            return
        }
        let first = leakTestSamples.first!.pressure
        let last = leakTestSamples.last!.pressure
        let delta = first - last
        if delta > 0.05 {
            leakTestResultMessage = appLanguage.string("debug.gas_leak_result_leak") + " (Δ\(String(format: "%.3f", delta)) bar)"
        } else {
            leakTestResultMessage = appLanguage.string("debug.gas_leak_result_ok") + " (Δ\(String(format: "%.3f", delta)) bar)"
        }
        leakTestResultDetails = ""
    }

    /// 根据两阶段采样点计算连续压力测试结果：阶段1与阶段2末值的压降大于阈值即失败
    private func evaluateLeakResultFromSamples() {
        let source = leakTestJudgementSource
        let sourceLabel = leakTestPressureSourceLabel(source)
        guard let beforeAverage = leakTestAveragePressure(for: .pre, source: source),
              let afterMinimum = leakTestMinimumPressure(for: .post, source: source) else {
            leakTestResultMessage = appLanguage.string("debug.gas_leak_result_insufficient")
            leakTestResultDetails = String(
                format: appLanguage.string("debug.gas_leak_result_details_insufficient"),
                sourceLabel
            )
            return
        }
        let startPressureMbar = beforeAverage * 1000.0
        // 起始压力下限判定：若不足则直接失败
        if startPressureMbar < leakTestStartPressureMinMbar {
            leakTestResultMessage = String(
                format: appLanguage.string("debug.gas_leak_result_start_pressure_low"),
                startPressureMbar,
                leakTestStartPressureMinMbar
            )
            // 仍然计算一次细节用于日志（使用当前 drop 阈值）
            let thresholdLineTmp = beforeAverage - leakTestPressureDropThresholdMbar / 1000.0
            let lowestDropTmp = (beforeAverage - afterMinimum) * 1000.0
            leakTestResultDetails = String(
                format: appLanguage.string("debug.gas_leak_result_details_format"),
                sourceLabel,
                beforeAverage,
                thresholdLineTmp,
                afterMinimum,
                lowestDropTmp,
                leakTestPressureDropThresholdMbar
            )
            appendLeakTestStepLog(6, "结果判定：\(leakTestResultMessage)")
            appendLeakTestStepLog(6, leakTestResultDetails)
            return
        }

        let thresholdLine = beforeAverage - leakTestPressureDropThresholdMbar / 1000.0
        let lowestDropMbar = (beforeAverage - afterMinimum) * 1000.0
        leakTestResultDetails = String(
            format: appLanguage.string("debug.gas_leak_result_details_format"),
            sourceLabel,
            beforeAverage,
            thresholdLine,
            afterMinimum,
            lowestDropMbar,
            leakTestPressureDropThresholdMbar
        )
        if afterMinimum < thresholdLine {
            leakTestResultMessage = String(
                format: appLanguage.string("debug.gas_leak_result_leak_with_threshold"),
                afterMinimum,
                thresholdLine
            )
        } else {
            leakTestResultMessage = String(
                format: appLanguage.string("debug.gas_leak_result_ok_with_threshold"),
                afterMinimum,
                thresholdLine
            )
        }
        appendLeakTestStepLog(6, "结果判定：\(leakTestResultMessage)")
        appendLeakTestStepLog(6, leakTestResultDetails)
    }

    /// 导出当前泄漏检测的采样数据为 CSV：time, close/open 压力, 阀门状态, Gas system status
    @MainActor
    private func exportLeakTestCSV() {
        guard !leakTestSamples.isEmpty else { return }
        var csv = "time_s,phase,pressure_close_bar,pressure_open_bar,valve_state,gas_system_status\n"
        for s in leakTestSamples {
            let t = String(format: "%.3f", s.time)
            let phase = s.phase.rawValue
            let closeStr = String(format: "%.5f", s.pressure)
            let openStr = s.pressureOpen.map { String(format: "%.5f", $0) } ?? ""
            let valve = s.valveState ?? ""
            let gas = s.gasSystemStatus ?? ""
            // 简单转义双引号
            let escapedValve = valve.replacingOccurrences(of: "\"", with: "\"\"")
            let escapedGas = gas.replacingOccurrences(of: "\"", with: "\"\"")
            csv.append("\(t),\(phase),\(closeStr),\(openStr),\"\(escapedValve)\",\"\(escapedGas)\"\n")
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
    
    private var continuousPressureReadSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.sm) {
                Text(appLanguage.string("debug.continuous_pressure_read"))
                    .font(UIDesignSystem.Typography.subsectionTitle)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Spacer(minLength: UIDesignSystem.Spacing.sm)
                Group {
                    if isContinuousPressureReadActive {
                        Button {
                            finishLeakTest(reason: appLanguage.string("debug.gas_leak_stop_reason_user"))
                        } label: {
                            Text(appLanguage.string("debug.gas_leak_stop"))
                                .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            startContinuousPressureRead()
                        } label: {
                            Text(appLanguage.string("debug.gas_leak_start"))
                                .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .disabled(!ble.isConnected || ble.isOTAInProgress || isLeakTestWorkflowActive)
            }

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
                            let clamped = min(3600, max(0, v))
                            leakTestDurationSeconds = clamped
                            leakTestDurationInput = "\(clamped)"
                        }
                    Text(appLanguage.string("debug.gas_leak_duration_unit"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Stepper("", value: $leakTestDurationSeconds, in: 0...3600, step: 10)
                        .labelsHidden()
                        .onChange(of: leakTestDurationSeconds) { leakTestDurationInput = "\($0)" }
                }
                .disabled(isContinuousPressureReadActive)
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
                            persistLeakTestRuleValues()
                        }
                    Stepper("", value: $leakTestIntervalSec, in: 0.1...3.0, step: 0.1)
                        .labelsHidden()
                        .onChange(of: leakTestIntervalSec) {
                            leakTestIntervalInput = String(format: "%.2f", $0)
                            persistLeakTestRuleValues()
                        }
                }
                .disabled(isContinuousPressureReadActive)
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
                .disabled(isContinuousPressureReadActive)
            }

            if leakTestSessionType == .continuous {
                leakTestChartDisplay(showPhase: false)
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
    }

    private var guidedLeakTestSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
            // 标题 + 开始/停止 同一行
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.sm) {
                Text(appLanguage.string("debug.gas_leak_rule_test"))
                    .font(UIDesignSystem.Typography.subsectionTitle)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                Spacer(minLength: UIDesignSystem.Spacing.sm)
                Group {
                    if isLeakTestWorkflowActive {
                        Button {
                            finishLeakTest(reason: appLanguage.string("debug.gas_leak_stop_reason_user"))
                        } label: {
                            Text(appLanguage.string("debug.gas_leak_stop"))
                                .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
                            startGuidedLeakTest()
                        } label: {
                            Text(appLanguage.string("debug.gas_leak_start"))
                                .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .disabled(!ble.isConnected || ble.isOTAInProgress || isContinuousPressureReadActive)
            }

            // guided 模式进度条与剩余时间
            if leakTestSessionType == .guided && (isLeakTestWorkflowActive || !leakTestSamples.isEmpty) && leakTestConfiguredTotalDurationSeconds > 0 {
                let total = Double(leakTestConfiguredTotalDurationSeconds)
                let clampedElapsed = min(max(leakTestElapsedSec, 0), total)
                let remaining = max(total - clampedElapsed, 0)
                VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
                    ProgressView(value: clampedElapsed, total: total)
                        .progressViewStyle(.linear)
                    HStack(spacing: UIDesignSystem.Spacing.sm) {
                        Text(String(format: "%@ %.1f / %.0f s",
                                    appLanguage.string("debug.gas_leak_elapsed"),
                                    clampedElapsed,
                                    total))
                            .font(UIDesignSystem.Typography.caption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                        Text("·")
                            .font(UIDesignSystem.Typography.caption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                        Text(String(format: "%@ %.0f s",
                                    appLanguage.string("debug.gas_leak_remaining"),
                                    remaining))
                            .font(UIDesignSystem.Typography.caption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    }
                }
            }

            // 规则参数：两阶段时长、读取间隔、判定压力源、压降阈值、确认开关、是否绘制 between 段
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
                    Text(appLanguage.string("debug.gas_leak_pre_close_duration"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    TextField("", text: $leakTestPreCloseDurationInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 44, maxWidth: 56)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            let v = Int(leakTestPreCloseDurationInput.trimmingCharacters(in: .whitespaces)) ?? leakTestPreCloseDurationSeconds
                            let clamped = min(3600, max(0, v))
                            leakTestPreCloseDurationSeconds = clamped
                            leakTestPreCloseDurationInput = "\(clamped)"
                            persistLeakTestRuleValues()
                        }
                    Text(appLanguage.string("debug.gas_leak_duration_unit"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Stepper("", value: $leakTestPreCloseDurationSeconds, in: 0...3600, step: 1)
                        .labelsHidden()
                        .onChange(of: leakTestPreCloseDurationSeconds, perform: {
                            leakTestPreCloseDurationInput = "\($0)"
                            persistLeakTestRuleValues()
                        })
                }
                .disabled(isLeakTestWorkflowActive)
                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
                    Text(appLanguage.string("debug.gas_leak_post_close_duration"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    TextField("", text: $leakTestPostCloseDurationInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 44, maxWidth: 56)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            let v = Int(leakTestPostCloseDurationInput.trimmingCharacters(in: .whitespaces)) ?? leakTestPostCloseDurationSeconds
                            let clamped = min(3600, max(0, v))
                            leakTestPostCloseDurationSeconds = clamped
                            leakTestPostCloseDurationInput = "\(clamped)"
                            persistLeakTestRuleValues()
                        }
                    Text(appLanguage.string("debug.gas_leak_duration_unit"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Stepper("", value: $leakTestPostCloseDurationSeconds, in: 0...3600, step: 1)
                        .labelsHidden()
                        .onChange(of: leakTestPostCloseDurationSeconds, perform: {
                            leakTestPostCloseDurationInput = "\($0)"
                            persistLeakTestRuleValues()
                        })
                }
                .disabled(isLeakTestWorkflowActive)
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
                            persistLeakTestRuleValues()
                        }
                    Stepper("", value: $leakTestIntervalSec, in: 0.1...3.0, step: 0.1)
                        .labelsHidden()
                        .onChange(of: leakTestIntervalSec, perform: {
                            leakTestIntervalInput = String(format: "%.2f", $0)
                            persistLeakTestRuleValues()
                        })
                }
                .disabled(isLeakTestWorkflowActive)

                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
                    Toggle("", isOn: $leakTestShowBetweenPhase)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    Text(appLanguage.string("debug.gas_leak_show_between_phase"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
                .disabled(isLeakTestWorkflowActive)
            }

            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
                    Text(appLanguage.string("debug.gas_leak_pressure_source"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Picker("", selection: $leakTestJudgementSource) {
                        Text(appLanguage.string("debug.gas_leak_pressure_source_closed")).tag(LeakTestJudgementSource.closed)
                        Text(appLanguage.string("debug.gas_leak_pressure_source_open")).tag(LeakTestJudgementSource.open)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 120)
                    .onChange(of: leakTestJudgementSource) { _ in
                        persistLeakTestRuleValues()
                        syncValveStateForLeakJudgementSource(reason: "切换判定压力源")
                    }
                }
                .disabled(isLeakTestWorkflowActive)

                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
                    Text(appLanguage.string("debug.gas_leak_drop_threshold"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    TextField("", text: $leakTestPressureDropThresholdInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 48, maxWidth: 60)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            let raw = leakTestPressureDropThresholdInput.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                            let v = Double(raw) ?? leakTestPressureDropThresholdMbar
                            let clamped = min(10_000, max(0, v))
                            leakTestPressureDropThresholdMbar = clamped
                            leakTestPressureDropThresholdInput = String(format: "%.1f", clamped)
                            persistLeakTestRuleValues()
                        }
                    Text("mbar")
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Stepper("", value: $leakTestPressureDropThresholdMbar, in: 0...10_000, step: 1)
                        .labelsHidden()
                        .onChange(of: leakTestPressureDropThresholdMbar) {
                            leakTestPressureDropThresholdInput = String(format: "%.1f", $0)
                            persistLeakTestRuleValues()
                        }
                }
                .disabled(isLeakTestWorkflowActive)

                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
                    Text(appLanguage.string("debug.gas_leak_start_pressure_min"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    TextField("", text: $leakTestStartPressureMinInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 48, maxWidth: 70)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            let raw = leakTestStartPressureMinInput.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                            let v = Double(raw) ?? leakTestStartPressureMinMbar
                            let clamped = min(1_000_000, max(0, v))
                            leakTestStartPressureMinMbar = clamped
                            leakTestStartPressureMinInput = String(format: "%.1f", clamped)
                            persistLeakTestRuleValues()
                        }
                    Text("mbar")
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Stepper("", value: $leakTestStartPressureMinMbar, in: 0...1_000_000, step: 10)
                        .labelsHidden()
                        .onChange(of: leakTestStartPressureMinMbar) {
                            leakTestStartPressureMinInput = String(format: "%.1f", $0)
                            persistLeakTestRuleValues()
                        }
                }
                .disabled(isLeakTestWorkflowActive)

                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.xs) {
                    Toggle("", isOn: $leakTestAlarmEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: leakTestAlarmEnabled) { _ in persistLeakTestRuleValues() }
                    Text(appLanguage.string("debug.gas_leak_alarm_threshold"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text(String(format: "%.1f", leakTestAlarmThresholdBar))
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .frame(minWidth: 28, alignment: .trailing)
                    Stepper("", value: $leakTestAlarmThresholdBar, in: 0.5...1.5, step: 0.1)
                        .labelsHidden()
                        .onChange(of: leakTestAlarmThresholdBar) { _ in persistLeakTestRuleValues() }
                }
                .disabled(isLeakTestWorkflowActive)
            }

            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                Toggle(appLanguage.string("debug.gas_leak_require_pipeline_ready_confirm"), isOn: $leakTestRequirePipelineReadyConfirm)
                    .toggleStyle(.checkbox)
                    .onChange(of: leakTestRequirePipelineReadyConfirm) { _ in persistLeakTestRuleValues() }
                    .disabled(isLeakTestWorkflowActive)
                Toggle(appLanguage.string("debug.gas_leak_require_valve_closed_confirm"), isOn: $leakTestRequireValveClosedConfirm)
                    .toggleStyle(.checkbox)
                    .onChange(of: leakTestRequireValveClosedConfirm) { _ in persistLeakTestRuleValues() }
                    .disabled(isLeakTestWorkflowActive)
                Spacer()
                Text("\(appLanguage.string("debug.gas_leak_total_duration")) \(leakTestConfiguredTotalDurationSeconds) s")
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
            }

            if leakTestSessionType == .guided {
                leakTestChartDisplay(showPhase: true)
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
        .onChange(of: ble.isConnected) { _ in stopLeakTestIfDisconnected() }
        .onChange(of: ble.areCharacteristicsReady) { _ in stopLeakTestIfDisconnected() }
        .alert(item: $leakTestPendingPrompt) { prompt in
            switch prompt {
            case .pipelineReady:
                return Alert(
                    title: Text(appLanguage.string("debug.gas_leak_pipeline_ready_title")),
                    message: Text(appLanguage.string("debug.gas_leak_pipeline_ready_message")),
                    primaryButton: .default(Text(appLanguage.string("debug.gas_leak_confirm_action"))) {
                        continueLeakTestAfterPrompt(.pipelineReady)
                    },
                    secondaryButton: .cancel(Text(appLanguage.string("debug.gas_leak_cancel_action"))) {
                        cancelLeakTestPrompt(.pipelineReady)
                    }
                )
            case .valveClosed:
                return Alert(
                    title: Text(appLanguage.string("debug.gas_leak_valve_closed_title")),
                    message: Text(appLanguage.string("debug.gas_leak_valve_closed_message")),
                    primaryButton: .default(Text(appLanguage.string("debug.gas_leak_confirm_action"))) {
                        continueLeakTestAfterPrompt(.valveClosed)
                    },
                    secondaryButton: .cancel(Text(appLanguage.string("debug.gas_leak_cancel_action"))) {
                        cancelLeakTestPrompt(.valveClosed)
                    }
                )
            }
        }
    }

    private func leakTestChartDisplay(showPhase: Bool) -> some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
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
                if leakTestAverageLineBar != nil {
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(leakTestAverageLineColor.opacity(0.85))
                            .frame(width: 12, height: 2)
                            .overlay(
                                Rectangle()
                                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 2]))
                                    .foregroundStyle(leakTestAverageLineColor.opacity(0.85))
                            )
                        Text(appLanguage.string("debug.gas_leak_chart_legend_average_line"))
                            .font(UIDesignSystem.Typography.caption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    }
                }
                if leakTestFailureLineBar != nil {
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(Color.red.opacity(0.9))
                            .frame(width: 12, height: 2)
                            .overlay(
                                Rectangle()
                                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                                    .foregroundStyle(Color.red.opacity(0.9))
                            )
                        Text(appLanguage.string("debug.gas_leak_chart_legend_fail_line"))
                            .font(UIDesignSystem.Typography.caption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    }
                }
                Spacer()
                Button(appLanguage.string("debug.gas_leak_export_csv")) {
                    exportLeakTestCSV()
                }
                .buttonStyle(.bordered)
                .font(UIDesignSystem.Typography.caption)
                .disabled(leakTestSamples.isEmpty)
            }

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
                if showPhase {
                    Text("·")
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text("\(appLanguage.string("debug.gas_leak_current_phase")) \(appLanguage.string("debug.gas_leak_state_\(leakTestFlowState.rawValue)"))")
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
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

            if showPhase, !leakTestResultDetails.isEmpty {
                Text(leakTestResultDetails)
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    .padding(.horizontal, UIDesignSystem.Padding.sm)
                    .padding(.vertical, UIDesignSystem.Padding.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(UIDesignSystem.CornerRadius.sm)
            }

            if showPhase, (leakTestAverageLineBar != nil || leakTestFailureLineBar != nil) {
                Text(appLanguage.string("debug.gas_leak_fail_line_formula"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
            }
        }
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
    
    /// 屏蔽系统气体自检：向 co2PressureLimits 写入 12 个 0x00
    private var disableGasSelfCheckSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            Text(appLanguage.string("debug.disable_gas_self_check"))
                .font(UIDesignSystem.Typography.subsectionTitle)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            Text(appLanguage.string("debug.disable_gas_self_check_hint"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            HStack {
                Spacer(minLength: UIDesignSystem.Spacing.lg)
                Button {
                    ble.writeCo2PressureLimitsZeros()
                } label: {
                    Text(appLanguage.string("debug.disable_gas_self_check_action"))
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
}
