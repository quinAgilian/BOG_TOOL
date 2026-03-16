import SwiftUI
import Combine

/// 步骤测试状态
enum StepTestStatus {
    case pending      // 待测试
    case running      // 进行中
    case passed       // 通过
    case failed       // 失败
    case skipped      // 跳过（未启用）
    
    var color: Color {
        switch self {
        case .pending: return .gray.opacity(0.3)
        case .running: return .blue
        case .passed: return .green
        case .failed: return .red
        case .skipped: return .gray.opacity(0.2)
        }
    }
    
    var icon: String {
        switch self {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }
    
    var text: String {
        switch self {
        case .pending: return "待测试"
        case .running: return "进行中"
        case .passed: return "通过"
        case .failed: return "失败"
        case .skipped: return "已跳过"
        }
    }
}

/// 测试结果状态
enum TestResultStatus {
    case notStarted    // 未开始
    case running       // 进行中
    case allPassed     // 全部通过
    case partialPassed // 部分通过
    case allFailed     // 全部失败
}

/// 漏气 limit 计算基准：phase1_avg = Phase 1 平均，phase3_first = Phase 3 首个值
let kGasLeakLimitSourcePhase1Avg = "phase1_avg"
let kGasLeakLimitSourcePhase3First = "phase3_first"

/// 产测气体泄漏检测步骤的配置（从 UserDefaults 按 keyPrefix 加载）
struct ProductionGasLeakConfig {
    var preCloseDurationSeconds: Int
    var postCloseDurationSeconds: Int
    var intervalSeconds: Double
    var dropThresholdMbar: Double
    var startPressureMinMbar: Double
    var requirePipelineReadyConfirm: Bool
    var requireValveClosedConfirm: Bool
    /// limit 计算基准：phase1_avg 或 phase3_first
    var limitSource: String
    /// 判定线不得低于该值（bar）；不论基准选哪个，有效 limit = max(计算出的 limit, limitFloorBar)，且 limitFloorBar 自身不得低于 0
    var limitFloorBar: Double
}

/// 产测模式：连接后执行 开→关→开，并在开前/开后/关后各读一次压力
struct ProductionTestView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @EnvironmentObject private var serverSettings: ServerSettings
    @EnvironmentObject private var serverClient: ServerClient
    @EnvironmentObject private var productionState: ProductionTestState
    @ObservedObject var ble: BLEManager
    @ObservedObject var firmwareManager: FirmwareManager
    @State private var isRunning = false
    @State private var testLog: [String] = []
    @State private var stepIndex = 0
    
    // 步骤状态跟踪
    @State private var stepStatuses: [String: StepTestStatus] = [:]
    @State private var currentStepId: String? = nil
    @State private var stepResults: [String: String] = [:] // 步骤结果信息
    
    @State private var testRules: TestRules = TestRules()
    // 存储当前测试步骤列表，用于响应规则变化
    @State private var currentTestSteps: [TestStep] = []
    // 展开的步骤ID集合
    @State private var expandedSteps: Set<String> = []
    // 步骤日志映射（步骤ID -> 日志行索引范围）
    @State private var stepLogRanges: [String: (start: Int, end: Int)] = [:]
    // 测试结果状态
    @State private var testResultStatus: TestResultStatus = .notStarted
    /// 是否已在本次程序启动时清理过测试结果摘要（仅清理一次）
    private static var hasClearedResultSummaryAtLaunch = false
    /// 连接后蓝牙权限/配对确认弹窗：显示时产测暂停，用户点击「继续」或回车后继续
    @State private var showBluetoothPermissionConfirmation = false
    @State private var bluetoothPermissionContinuation: (() -> Void)? = nil
    /// 产测结束后是否显示结果 overlay（绿/红弹窗报表）
    @State private var showResultOverlay = false
    /// 本次产测因「当前固件不支持恢复出厂/重启」而在 OTA 后发送了 reboot，报表需提示需要重测
    @State private var needRetestAfterOtaReboot = false
    /// 最近一次产测结束时间（用于 overlay 报表显示）
    @State private var lastTestEndTime: Date?
    /// 本次产测是否已调用过 finish，避免 onChange 与 run loop guard 重复调用导致报表/上传两次
    @State private var didFinishThisRun = false
    /// 是否正在「步骤失败提前终止」路径中执行恢复出厂（runFactoryResetIfEnabledBeforeExit）。为 true 时 lastConnectFailureWasPairingRemoved 来自我们自己的 reset，onChange 不应把当前步骤原因改写为「对方删除配对」
    @State private var isRunningFactoryResetBeforeExit = false
    /// 本次产测开始时间（用于上传 durationSeconds）
    @State private var lastTestStartTime: Date?
    /// 本次产测过程中缓存的设备信息（步骤 2 通过时写入），用于结束后上传，与是否仍连接无关
    @State private var capturedDeviceSN: String?
    @State private var capturedDeviceName: String?
    @State private var capturedFirmwareVersion: String?
    @State private var capturedBootloaderVersion: String?
    @State private var capturedHardwareRevision: String?
    /// 本次产测关键测试数据（各步骤通过时缓存），用于上传结构化详情
    @State private var capturedRtcDeviceTime: String?
    @State private var capturedRtcSystemTime: String?
    @State private var capturedRtcTimeDiffSeconds: Double?
    @State private var capturedPressureClosedMbar: Double?
    @State private var capturedPressureOpenMbar: Double?
    @State private var capturedGasSystemStatus: String?
    @State private var capturedValveState: String?
    @State private var capturedGasLeakOpenDeltaMbar: Double?
    @State private var capturedGasLeakClosedDeltaMbar: Double?
    @State private var capturedGasLeakOpenDurationSeconds: Double?
    @State private var capturedGasLeakClosedDurationSeconds: Double?
    @State private var capturedGasLeakOpenPhase1AvgBar: Double?
    @State private var capturedGasLeakClosedPhase1AvgBar: Double?
    @State private var capturedGasLeakOpenThresholdMbar: Double?
    @State private var capturedGasLeakClosedThresholdMbar: Double?
    @State private var capturedGasLeakOpenLimitBar: Double?
    @State private var capturedGasLeakClosedLimitBar: Double?
    @State private var capturedGasLeakOpenLimitSource: String?
    @State private var capturedGasLeakClosedLimitSource: String?
    @State private var capturedGasLeakOpenPhase3FirstBar: Double?
    @State private var capturedGasLeakClosedPhase3FirstBar: Double?
    @State private var capturedGasLeakOpenUserActionSeconds: Double?
    @State private var capturedGasLeakClosedUserActionSeconds: Double?
    @State private var capturedGasLeakOpenSamples: [[String: Any]]?
    @State private var capturedGasLeakClosedSamples: [[String: Any]]?
    
    /// 本次产测唯一 ID（用于本地记录文件名与跟踪）
    @State private var currentTestId: String?
    /// 本次产测执行过程流水账（步骤开始/结束等），结束时与 summary 一起写入本地文件
    @State private var journalEntries: [[String: Any]] = []
    
    /// 气体泄漏检测步骤中的用户确认弹窗（Phase 1 前气路确认 / Phase 2 前关阀确认）
    @State private var showGasLeakConfirmAlert = false
    @State private var gasLeakConfirmTitle = ""
    @State private var gasLeakConfirmMessage = ""
    @State private var gasLeakConfirmResume: ((Bool) -> Void)?

    /// 压力读取失败时是否弹窗确认重测（由产测规则开关控制）；弹窗回调
    @State private var showPressureRetryAlert = false
    @State private var pressureRetryResume: ((Bool) -> Void)?

    /// 产测提示音：弹窗提示用户做动作时播放，提升可见性
    private func playProductionHintSound() {
        if let sound = NSSound(named: "Glass") {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
    
    /// 按需从服务器拉取产线可见固件，并返回目标版本对应条目
    private func productionFirmwareItem(for version: String) async -> ServerFirmwareItem? {
        if let item = firmwareManager.serverItemsForProduction.first(where: { $0.version == version }) {
            return item
        }
        await firmwareManager.fetchServerFirmware(serverClient: serverClient, channel: "production")
        return firmwareManager.serverItemsForProduction.first(where: { $0.version == version })
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.md) {
            // 标题区域 - 带渐变背景
            HStack(spacing: UIDesignSystem.Spacing.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .font(.title2)
                
                Text(appLanguage.string("production_test.title"))
                    .font(UIDesignSystem.Typography.sectionTitle)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.primary, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                
                Spacer()
                
                // 规则状态指示器
                HStack(spacing: 4) {
                    Circle()
                        .fill(testRules.enabledStepsCount > 0 ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text("\(testRules.enabledStepsCount) \(appLanguage.string("production_test.steps"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, UIDesignSystem.Padding.xs)

            // 控制按钮区域：未运行时点击开始，运行中显示 TESTING. / TESTING.. / TESTING... 且点击即终止
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                Spacer(minLength: UIDesignSystem.Spacing.lg)
                Button(action: {
                    if isRunning {
                        stopProductionTest()
                    } else {
                        runProductionTest()
                    }
                }) {
                    HStack(spacing: UIDesignSystem.Spacing.sm) {
                        if !isRunning {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                        } else {
                            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                                let dots = (Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 3) + 1
                                Text("TESTING" + String(repeating: ".", count: dots))
                                    .fontWeight(.semibold)
                            }
                        }
                        if !isRunning {
                            Text(appLanguage.string("production_test.start"))
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                    .foregroundColor(.white)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(ble.isOTAInProgress || ble.selectedDeviceId == nil)
                .shadow(color: .blue.opacity(0.3), radius: 4, x: 0, y: 2)
                
                Button(action: { openProductionTestRecordsDirectory() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.gearshape")
                        Text(appLanguage.string("production_test.open_records_folder"))
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            
            // 产测 OTA 由主窗口 overlay 接管时不再在此处显示 inline 区域（避免重复）
            if (ble.isOTAInProgress || ble.isOTACompletedWaitingReboot || ble.isOTAFailed || ble.isOTACancelled || ble.isOTARebootDisconnected) && !ble.otaInitiatedByProductionTest {
                productionTestOTAArea
            }
            
            // 测试步骤功能区 - 垂直滚动布局，占满下方空间
            VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
                HStack {
                    Image(systemName: "list.number")
                        .foregroundStyle(.blue)
                    Text(appLanguage.string("production_test.steps_title"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, UIDesignSystem.Padding.xs)
                
                ScrollViewReader { _ in
                    ScrollView {
                        testStepsSection
                            .padding(.horizontal, UIDesignSystem.Padding.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 320, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
            .padding(UIDesignSystem.Padding.sm)
            .background(
                LinearGradient(
                    colors: [Color.secondary.opacity(0.05), Color.secondary.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(UIDesignSystem.CornerRadius.sm)

        }
        .padding(UIDesignSystem.Padding.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    UIDesignSystem.Background.subtle,
                    UIDesignSystem.Background.subtle.opacity(0.8)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .cornerRadius(UIDesignSystem.CornerRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: UIDesignSystem.CornerRadius.md)
                .stroke(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
        .onChange(of: isRunning) { running in
            productionState.isRunning = running
        }
        .onAppear {
            updateTestRules()
            updateTestSteps()
            // 程序启动时清理测试结果摘要与日志，仅执行一次
            if !Self.hasClearedResultSummaryAtLaunch {
                clearTestResultSummaryAndLog()
                Self.hasClearedResultSummaryAtLaunch = true
            }
            initializeStepStatuses()
            updateTestResultStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .productionTestRulesDidChange)) { _ in
            // 当规则变化时，立即更新步骤列表和规则摘要
            updateTestRules()
            updateTestSteps()
            initializeStepStatuses()
            updateTestResultStatus()
        }
        .onChange(of: stepStatuses) { _ in
            // 当步骤状态变化时，更新测试结果状态
            updateTestResultStatus()
        }
        .onChange(of: isRunning) { running in
            if running {
                testResultStatus = .running
            } else {
                updateTestResultStatus()
            }
        }
        .onChange(of: ble.lastConnectFailureWasPairingRemoved) { pairingRemoved in
            guard pairingRemoved, isRunning else { return }
            // 若「配对移除」是因为步骤失败提前终止时我们执行的恢复出厂导致的，不要覆盖已记录的真实失败原因
            if isRunningFactoryResetBeforeExit { return }
            // Peer removed pairing 时立即终止当前产测（系统蓝牙设置已在 BLEManager 中自动弹出）
            // 若当前步骤正是「恢复出厂」，则视为恢复出厂成功（设备已清除配对），该步记为通过；报表由 run loop 在 reconnectAfterTestingReboot 返回后统一出具，保证「测试完毕后再出报表」
            let enabledSteps = currentTestSteps.filter { $0.enabled }
            if let stepId = currentStepId {
                let logStartIndex = testLog.count
                let isFactoryResetStep = (stepId == TestStep.factoryReset.id)
                if isFactoryResetStep {
                    log("检测到设备已清除配对，判定恢复出厂成功", level: .info)
                    stepResults[stepId] = appLanguage.string("production_test_rules.step_factory_reset_confirmed_pairing_removed")
                    stepStatuses[stepId] = .passed
                    stepResults[TestStep.disconnectDevice.id] = appLanguage.string("production_test.step_disconnect_after_factory_reset_ok")
                    stepStatuses[TestStep.disconnectDevice.id] = .passed
                } else {
                    log("[FQC] 蓝牙连接失败：Peer removed pairing information，当前测试终止，请在系统「蓝牙」设置中删除该设备（忘记设备）后重测", level: .error)
                    stepResults[stepId] = appLanguage.string("production_test.connect_fail_pairing_removed")
                    stepStatuses[stepId] = .failed
                    currentStepId = nil
                    isRunning = false
                    updateTestResultStatus()
                    Task { @MainActor in
                        finishProductionTestRunWithReportAndUpload(enabledSteps: enabledSteps)
                    }
                }
                stepLogRanges[stepId] = (start: logStartIndex, end: testLog.count)
                expandedSteps.remove(stepId)
            }
            if currentStepId != nil {
                currentStepId = nil
                isRunning = false
                updateTestResultStatus()
            }
        }
        .sheet(isPresented: $showBluetoothPermissionConfirmation) {
            BluetoothPermissionConfirmSheet(
                onContinue: {
                    bluetoothPermissionContinuation?()
                    bluetoothPermissionContinuation = nil
                    showBluetoothPermissionConfirmation = false
                }
            )
            .environmentObject(appLanguage)
        }
        .alert(gasLeakConfirmTitle, isPresented: $showGasLeakConfirmAlert) {
            Button(appLanguage.string("debug.gas_leak_confirm_action")) {
                gasLeakConfirmResume?(true)
                gasLeakConfirmResume = nil
                showGasLeakConfirmAlert = false
            }
            Button(appLanguage.string("debug.gas_leak_cancel_action"), role: .cancel) {
                gasLeakConfirmResume?(false)
                gasLeakConfirmResume = nil
                showGasLeakConfirmAlert = false
            }
        } message: {
            Text(gasLeakConfirmMessage)
        }
        .alert(appLanguage.string("production_test.pressure_fail_retry_alert_title"), isPresented: $showPressureRetryAlert) {
            Button(appLanguage.string("production_test.pressure_fail_retry_retry_action")) {
                pressureRetryResume?(true)
                pressureRetryResume = nil
                showPressureRetryAlert = false
            }
            Button(appLanguage.string("production_test.pressure_fail_retry_continue_action"), role: .cancel) {
                pressureRetryResume?(false)
                pressureRetryResume = nil
                showPressureRetryAlert = false
            }
        } message: {
            Text(appLanguage.string("production_test.pressure_fail_retry_alert_message"))
        }
        .overlay {
            if showResultOverlay {
                ProductionTestResultOverlay(
                    passed: overallTestPassed,
                    criteria: overallTestCriteria,
                    timeString: productionTestEndTimeString,
                    needRetest: needRetestAfterOtaReboot,
                    onDismiss: { showResultOverlay = false }
                )
                .environmentObject(appLanguage)
            }
        }
    }
    
    /// 清理测试结果摘要与日志区（程序启动时调用一次）
    private func clearTestResultSummaryAndLog() {
        stepResults.removeAll()
        stepStatuses.removeAll()
        stepLogRanges.removeAll()
        testLog.removeAll()
        stepIndex = 0
        currentStepId = nil
        testResultStatus = .notStarted
        capturedDeviceSN = nil
        capturedDeviceName = nil
        capturedFirmwareVersion = nil
        capturedBootloaderVersion = nil
        capturedHardwareRevision = nil
        capturedRtcDeviceTime = nil
        capturedRtcSystemTime = nil
        capturedRtcTimeDiffSeconds = nil
        capturedPressureClosedMbar = nil
        capturedPressureOpenMbar = nil
        capturedGasSystemStatus = nil
        capturedValveState = nil
        capturedGasLeakOpenDeltaMbar = nil
        capturedGasLeakClosedDeltaMbar = nil
        capturedGasLeakOpenDurationSeconds = nil
        capturedGasLeakClosedDurationSeconds = nil
        capturedGasLeakOpenPhase1AvgBar = nil
        capturedGasLeakClosedPhase1AvgBar = nil
        capturedGasLeakOpenThresholdMbar = nil
        capturedGasLeakClosedThresholdMbar = nil
        capturedGasLeakOpenLimitBar = nil
        capturedGasLeakClosedLimitBar = nil
        capturedGasLeakOpenLimitSource = nil
        capturedGasLeakClosedLimitSource = nil
        capturedGasLeakOpenPhase3FirstBar = nil
        capturedGasLeakClosedPhase3FirstBar = nil
        capturedGasLeakOpenUserActionSeconds = nil
        capturedGasLeakClosedUserActionSeconds = nil
        capturedGasLeakOpenSamples = nil
        capturedGasLeakClosedSamples = nil
        capturedGasLeakOpenPhase1AvgBar = nil
        capturedGasLeakClosedPhase1AvgBar = nil
        capturedGasLeakOpenThresholdMbar = nil
        capturedGasLeakClosedThresholdMbar = nil
        capturedGasLeakOpenLimitBar = nil
        capturedGasLeakClosedLimitBar = nil
        capturedGasLeakOpenLimitSource = nil
        capturedGasLeakClosedLimitSource = nil
        capturedGasLeakOpenPhase3FirstBar = nil
        capturedGasLeakClosedPhase3FirstBar = nil
        capturedGasLeakOpenUserActionSeconds = nil
        capturedGasLeakClosedUserActionSeconds = nil
        capturedGasLeakOpenSamples = nil
        capturedGasLeakClosedSamples = nil
        lastTestStartTime = nil
        lastTestEndTime = nil
    }
    
    /// 初始化步骤状态
    private func initializeStepStatuses() {
        for step in currentTestSteps {
            if step.enabled {
                stepStatuses[step.id] = .pending
            } else {
                stepStatuses[step.id] = .skipped
            }
        }
    }
    
    /// 更新测试步骤列表（从UserDefaults加载）
    private func updateTestSteps() {
        let rules = loadTestRules()
        currentTestSteps = rules.steps
    }
    
    /// 测试步骤功能区 - 垂直布局，每行一个步骤
    private var testStepsSection: some View {
        let enabledSteps = currentTestSteps.filter { $0.enabled }
        
        return VStack(spacing: UIDesignSystem.Spacing.xs) {
            ForEach(Array(enabledSteps.enumerated()), id: \.element.id) { index, step in
                stepRow(step: step, stepNumber: index + 1)
                    .id(step.id)
            }
        }
    }
    
    /// 步骤行 - 水平布局，对号在最右侧，支持展开/折叠
    private func stepRow(step: TestStep, stepNumber: Int) -> some View {
        let status = stepStatuses[step.id] ?? .pending
        let isCurrent = currentStepId == step.id
        let result = stepResults[step.id] ?? ""
        let isExpanded = expandedSteps.contains(step.id)
        
        return VStack(alignment: .leading, spacing: 0) {
            // 主行：可点击展开/折叠
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                // 左侧：步骤编号圆圈
                ZStack {
                    Circle()
                        .fill(status.color.opacity(0.2))
                        .frame(width: 28, height: 28)
                    
                    if status == .running {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Text("\(stepNumber)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(status.color)
                    }
                }
                
                // 中间：步骤标题和结果信息
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(appLanguage.string("production_test_rules.\(step.key)_title"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        
                        // 展开/折叠图标（任意时刻可点击切换）
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    if !result.isEmpty {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 1)
                    } else {
                        Text(statusText(status))
                            .font(.caption2)
                            .foregroundStyle(status.color)
                    }
                }
                
                Spacer()
                
                // 最右侧：状态图标/对号
                HStack(spacing: UIDesignSystem.Spacing.xs) {
                    // 进度条（仅在运行中时显示）
                    if status == .running {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16)
                    }
                    
                    // 状态图标（对号在最右侧）
                    Image(systemName: status.icon)
                        .foregroundStyle(status.color)
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .frame(minWidth: 40, alignment: .trailing)
            }
            .padding(.horizontal, UIDesignSystem.Padding.sm)
            .padding(.vertical, UIDesignSystem.Padding.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                // 任意时刻点击均可展开/折叠该步骤
                if isExpanded {
                    expandedSteps.remove(step.id)
                } else {
                    expandedSteps.insert(step.id)
                }
            }
            .background(
                Group {
                    if isCurrent {
                        LinearGradient(
                            colors: [status.color.opacity(0.15), status.color.opacity(0.05)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    } else {
                        LinearGradient(
                            colors: [Color.secondary.opacity(0.05), Color.secondary.opacity(0.02)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                }
            )
            .cornerRadius(UIDesignSystem.CornerRadius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: UIDesignSystem.CornerRadius.sm)
                    .stroke(
                        isCurrent ? status.color.opacity(0.5) : Color.clear,
                        lineWidth: 2
                    )
            )
            .shadow(
                color: isCurrent ? status.color.opacity(0.2) : .clear,
                radius: 4,
                x: 0,
                y: 2
            )
            
            // 展开的详细信息区域
            if isExpanded {
                stepDetailView(step: step, status: status, result: result)
                    .padding(.leading, UIDesignSystem.Padding.md + 28 + UIDesignSystem.Spacing.md) // 对齐到内容
                    .padding(.top, UIDesignSystem.Padding.xs)
                    .padding(.bottom, UIDesignSystem.Padding.sm)
            }
        }
    }
    
    /// 步骤详细信息视图（展开时显示）
    private func stepDetailView(step: TestStep, status: StepTestStatus, result: String) -> some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            Divider()
            
            // 详细结果信息
            if !result.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLanguage.string("production_test.test_result"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, UIDesignSystem.Padding.xs)
            }
            
            // 相关日志（注意保护下标范围，防止 testLog 被清空后 stepLogRanges 仍然存在）
            if let logRange = stepLogRanges[step.id], !testLog.isEmpty {
                // 将区间裁剪到当前 testLog 的合法范围内
                let clampedStart = max(0, min(logRange.start, testLog.count))
                let clampedEnd = max(clampedStart, min(logRange.end, testLog.count))
                
                if clampedStart < clampedEnd {
                    let stepLogs = Array(testLog[clampedStart..<clampedEnd])
                    if !stepLogs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appLanguage.string("production_test.execution_log"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(stepLogs.enumerated()), id: \.offset) { _, logLine in
                                        Text(logLine)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .frame(maxHeight: 150)
                        }
                        .padding(.vertical, UIDesignSystem.Padding.xs)
                    }
                }
            }
        }
        .padding(.horizontal, UIDesignSystem.Padding.sm)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(UIDesignSystem.CornerRadius.sm)
    }
    
    /// 状态文本
    private func statusText(_ status: StepTestStatus) -> String {
        switch status {
        case .pending: return appLanguage.string("production_test.status_pending")
        case .running: return appLanguage.string("production_test.status_running")
        case .passed: return appLanguage.string("production_test.status_passed")
        case .failed: return appLanguage.string("production_test.status_failed")
        case .skipped: return appLanguage.string("production_test.status_skipped")
        }
    }
    
    /// 更新测试规则
    private func updateTestRules() {
        let rules = loadTestRules()
        testRules = TestRules(
            enabledStepsCount: rules.steps.filter { $0.enabled }.count,
            firmwareVersion: rules.firmwareVersion,
            hardwareVersion: rules.hardwareVersion
        )
    }

    /// 启动前规则校验：FW/HW 必须在产测规则中明确填写，不能为空
    private func validateRequiredRulesBeforeStart() -> String? {
        let rules = loadTestRules()
        let missing: [String] = [
            rules.firmwareVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "FW" : nil,
            rules.hardwareVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "HW" : nil,
        ]
        .compactMap { $0 }
        guard !missing.isEmpty else { return nil }
        return String(format: appLanguage.string("production_test.required_rules_missing"), missing.joined(separator: "/"))
    }
    
    // MARK: - 整体通过判定（连接、RTC、固件、压力、屏蔽自检、Gas 状态、气体泄漏、待定、电磁阀、恢复出厂、重启、断开）
    
    /// 步骤启用时：passed 或 skipped 均视为该步满足（用于 disable_diag、gas_leak、tbd、disconnect 等）
    private func stepOkForOverall(stepId: String, enabled: [TestStep]) -> Bool {
        guard enabled.contains(where: { $0.id == stepId }) else { return true }
        let status = stepStatuses[stepId] ?? .pending
        return status == .passed || status == .skipped
    }
    
    /// 产测整体是否通过：所有纳入判定的步骤在启用时须为通过或跳过，未启用或跳过标定为满足。
    private var overallTestPassed: Bool {
        let enabled = currentTestSteps.filter { $0.enabled }
        guard !enabled.isEmpty else { return false }
        // 需要重测 = 本次未执行恢复出厂/重启（如因旧固件不支持），视为产测未通过
        if needRetestAfterOtaReboot { return false }
        let connectOk = !enabled.contains(where: { $0.id == TestStep.connectDevice.id }) || stepStatuses[TestStep.connectDevice.id] == .passed
        let rtcOk = !enabled.contains(where: { $0.id == TestStep.readRTC.id }) || stepStatuses[TestStep.readRTC.id] == .passed
        let fwStepEnabled = enabled.contains(where: { $0.id == TestStep.verifyFirmware.id })
        let otaStepEnabled = enabled.contains(where: { $0.id == TestStep.otaBeforeDisconnect.id })
        let fwOk: Bool
        if !fwStepEnabled {
            fwOk = true
        } else if stepStatuses[TestStep.verifyFirmware.id] != .passed {
            fwOk = false
        } else if otaStepEnabled {
            // 步骤2 已通过时，若启用了 OTA 步骤，则必须 OTA 步骤也通过（未触发/已跳过/完成均可），否则整体不通过
            fwOk = (stepStatuses[TestStep.otaBeforeDisconnect.id] == .passed)
        } else {
            fwOk = true
        }
        let pressureOk = !enabled.contains(where: { $0.id == TestStep.readPressure.id }) || stepStatuses[TestStep.readPressure.id] == .passed
        let disableDiagOk = stepOkForOverall(stepId: TestStep.disableDiag.id, enabled: enabled)
        let gasSystemStatusOk = !enabled.contains(where: { $0.id == TestStep.readGasSystemStatus.id }) || stepStatuses[TestStep.readGasSystemStatus.id] == .passed
        let gasLeakOpenOk = stepOkForOverall(stepId: TestStep.gasLeakOpen.id, enabled: enabled)
        let gasLeakClosedOk = stepOkForOverall(stepId: TestStep.gasLeakClosed.id, enabled: enabled)
        let tbdOk = stepOkForOverall(stepId: TestStep.tbd.id, enabled: enabled)
        let valveOk = !enabled.contains(where: { $0.id == TestStep.ensureValveOpen.id }) || stepStatuses[TestStep.ensureValveOpen.id] == .passed
        // 恢复出厂 / 重启：若步骤启用则必须真正执行通过，未执行（如版本不支持而跳过）则整体判失败
        let factoryResetOk = !enabled.contains(where: { $0.id == TestStep.factoryReset.id }) || stepStatuses[TestStep.factoryReset.id] == .passed
        let resetOk = !enabled.contains(where: { $0.id == TestStep.reset.id }) || stepStatuses[TestStep.reset.id] == .passed
        let disconnectOk = stepOkForOverall(stepId: TestStep.disconnectDevice.id, enabled: enabled)
        return connectOk && rtcOk && fwOk && pressureOk && disableDiagOk && gasSystemStatusOk && gasLeakOpenOk && gasLeakClosedOk && tbdOk && valveOk && factoryResetOk && resetOk && disconnectOk
    }
    
    /// 用于 overlay 报表的判定项列表：(名称, 是否通过, 是否仅警告通过, 测试数据备注)。禁用的步骤也保留，标记为警告并注明「测试跳过」。
    private var overallTestCriteria: [(name: String, ok: Bool, isWarning: Bool, detail: String?)] {
        let enabled = currentTestSteps.filter { $0.enabled }
        let skippedDetail = appLanguage.string("production_test.overlay_step_skipped")
        func detail(for stepId: String) -> String? {
            let s = (stepResults[stepId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        var list: [(String, Bool, Bool, String?)] = []
        // 连接设备
        if enabled.contains(where: { $0.id == TestStep.connectDevice.id }) {
            list.append((appLanguage.string("production_test_rules.step1_title"), stepStatuses[TestStep.connectDevice.id] == .passed, false, detail(for: TestStep.connectDevice.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.connectDevice.id }) {
            list.append((appLanguage.string("production_test_rules.step1_title"), true, true, skippedDetail))
        }
        // RTC
        if enabled.contains(where: { $0.id == TestStep.readRTC.id }) {
            list.append((appLanguage.string("production_test_rules.step3_title"), stepStatuses[TestStep.readRTC.id] == .passed, false, detail(for: TestStep.readRTC.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.readRTC.id }) {
            list.append((appLanguage.string("production_test_rules.step3_title"), true, true, skippedDetail))
        }
        // 固件（一致或 OTA 成功）
        if enabled.contains(where: { $0.id == TestStep.verifyFirmware.id }) {
            let fwPass = stepStatuses[TestStep.verifyFirmware.id] == .passed
            let otaPass = enabled.contains(where: { $0.id == TestStep.otaBeforeDisconnect.id }) && stepStatuses[TestStep.otaBeforeDisconnect.id] == .passed
            let d = detail(for: TestStep.verifyFirmware.id) ?? detail(for: TestStep.otaBeforeDisconnect.id)
            let isWarning = (fwPass || otaPass) && (d?.contains("升级已禁用") ?? false)
            list.append((appLanguage.string("production_test.result_criteria_fw"), fwPass || otaPass, isWarning, d))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.verifyFirmware.id }) {
            list.append((appLanguage.string("production_test.result_criteria_fw"), true, true, skippedDetail))
        }
        // 断开前 OTA（单独一行，便于看到 OTA 成功/失败/取消的结论）
        if enabled.contains(where: { $0.id == TestStep.otaBeforeDisconnect.id }) {
            let otaPass = stepStatuses[TestStep.otaBeforeDisconnect.id] == .passed
            list.append((appLanguage.string("production_test_rules.step_ota_title"), otaPass, false, detail(for: TestStep.otaBeforeDisconnect.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.otaBeforeDisconnect.id }) {
            list.append((appLanguage.string("production_test_rules.step_ota_title"), true, true, skippedDetail))
        }
        // 压力值
        if enabled.contains(where: { $0.id == TestStep.readPressure.id }) {
            list.append((appLanguage.string("production_test_rules.step4_title"), stepStatuses[TestStep.readPressure.id] == .passed, false, detail(for: TestStep.readPressure.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.readPressure.id }) {
            list.append((appLanguage.string("production_test_rules.step4_title"), true, true, skippedDetail))
        }
        // 屏蔽气体自检（Disable diag）
        if enabled.contains(where: { $0.id == TestStep.disableDiag.id }) {
            list.append((appLanguage.string("production_test_rules.step_disable_diag_title"), stepStatuses[TestStep.disableDiag.id] == .passed, false, detail(for: TestStep.disableDiag.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.disableDiag.id }) {
            list.append((appLanguage.string("production_test_rules.step_disable_diag_title"), true, true, skippedDetail))
        }
        // Gas system status
        if enabled.contains(where: { $0.id == TestStep.readGasSystemStatus.id }) {
            list.append((appLanguage.string("production_test_rules.step_gas_system_status_title"), stepStatuses[TestStep.readGasSystemStatus.id] == .passed, false, detail(for: TestStep.readGasSystemStatus.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.readGasSystemStatus.id }) {
            list.append((appLanguage.string("production_test_rules.step_gas_system_status_title"), true, true, skippedDetail))
        }
        // 气体泄漏检测（开阀压力）
        if enabled.contains(where: { $0.id == TestStep.gasLeakOpen.id }) {
            list.append((appLanguage.string("production_test_rules.step_gas_leak_open_title"), stepStatuses[TestStep.gasLeakOpen.id] == .passed, stepStatuses[TestStep.gasLeakOpen.id] == .skipped, detail(for: TestStep.gasLeakOpen.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.gasLeakOpen.id }) {
            list.append((appLanguage.string("production_test_rules.step_gas_leak_open_title"), true, true, skippedDetail))
        }
        // 气体泄漏检测（关阀压力）
        if enabled.contains(where: { $0.id == TestStep.gasLeakClosed.id }) {
            list.append((appLanguage.string("production_test_rules.step_gas_leak_closed_title"), stepStatuses[TestStep.gasLeakClosed.id] == .passed, stepStatuses[TestStep.gasLeakClosed.id] == .skipped, detail(for: TestStep.gasLeakClosed.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.gasLeakClosed.id }) {
            list.append((appLanguage.string("production_test_rules.step_gas_leak_closed_title"), true, true, skippedDetail))
        }
        // 电磁阀
        if enabled.contains(where: { $0.id == TestStep.ensureValveOpen.id }) {
            list.append((appLanguage.string("production_test_rules.step_valve_title"), stepStatuses[TestStep.ensureValveOpen.id] == .passed, false, detail(for: TestStep.ensureValveOpen.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.ensureValveOpen.id }) {
            list.append((appLanguage.string("production_test_rules.step_valve_title"), true, true, skippedDetail))
        }
        // 重启设备
        if enabled.contains(where: { $0.id == TestStep.reset.id }) {
            list.append((appLanguage.string("production_test_rules.step_reset_title"), stepStatuses[TestStep.reset.id] == .passed, stepStatuses[TestStep.reset.id] == .skipped, detail(for: TestStep.reset.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.reset.id }) {
            list.append((appLanguage.string("production_test_rules.step_reset_title"), true, true, skippedDetail))
        }
        // 恢复出厂设置
        if enabled.contains(where: { $0.id == TestStep.factoryReset.id }) {
            list.append((appLanguage.string("production_test_rules.step_factory_reset_title"), stepStatuses[TestStep.factoryReset.id] == .passed, stepStatuses[TestStep.factoryReset.id] == .skipped, detail(for: TestStep.factoryReset.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.factoryReset.id }) {
            list.append((appLanguage.string("production_test_rules.step_factory_reset_title"), true, true, skippedDetail))
        }
        // 待定（step5）
        if enabled.contains(where: { $0.id == TestStep.tbd.id }) {
            list.append((appLanguage.string("production_test_rules.step5_title"), stepStatuses[TestStep.tbd.id] == .passed, stepStatuses[TestStep.tbd.id] == .skipped, detail(for: TestStep.tbd.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.tbd.id }) {
            list.append((appLanguage.string("production_test_rules.step5_title"), true, true, skippedDetail))
        }
        // 安全断开连接
        if enabled.contains(where: { $0.id == TestStep.disconnectDevice.id }) {
            list.append((appLanguage.string("production_test_rules.step_disconnect_title"), stepStatuses[TestStep.disconnectDevice.id] == .passed, false, detail(for: TestStep.disconnectDevice.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.disconnectDevice.id }) {
            list.append((appLanguage.string("production_test_rules.step_disconnect_title"), true, true, skippedDetail))
        }
        return list
    }
    
    /// 产测结束时间字符串（用于 overlay 报表）
    private var productionTestEndTimeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_POSIX")
        return formatter.string(from: lastTestEndTime ?? Date())
    }
    
    /// 更新测试结果状态
    private func updateTestResultStatus() {
        guard !isRunning else {
            testResultStatus = .running
            return
        }
        
        let enabledSteps = currentTestSteps.filter { $0.enabled }
        guard !enabledSteps.isEmpty else {
            testResultStatus = .notStarted
            return
        }
        
        let passedCount = enabledSteps.filter { stepStatuses[$0.id] == .passed }.count
        let failedCount = enabledSteps.filter { stepStatuses[$0.id] == .failed }.count
        let hasRunning = enabledSteps.contains { stepStatuses[$0.id] == .running }
        
        if hasRunning {
            testResultStatus = .running
        } else if failedCount == 0 && passedCount > 0 {
            testResultStatus = .allPassed
        } else if passedCount == 0 && failedCount > 0 {
            testResultStatus = .allFailed
        } else if passedCount > 0 && failedCount > 0 {
            testResultStatus = .partialPassed
        } else {
            testResultStatus = .notStarted
        }
    }
    
    /// 测试规则数据结构
    private struct TestRules {
        var enabledStepsCount: Int = 0
        var firmwareVersion: String = ""
        var hardwareVersion: String = ""
    }
    
    /// 产测独立 OTA 区域：数据包大小、总大小、已用/剩余时间、速率、总耗时；升级中可取消
    private var productionTestOTAArea: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            HStack(spacing: UIDesignSystem.Spacing.sm) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text(appLanguage.string("production_test.ota_section_title"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if ble.isOTAInProgress {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if ble.isOTAFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if ble.isOTACancelled {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                } else if ble.isOTACompletedWaitingReboot {
                    Image(systemName: "clock.fill")
                        .foregroundStyle(.blue)
                }
            }
            
            Text(otaStatusText)
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            
            // 数据包大小、总大小（始终在 OTA 相关状态时显示）
            HStack(alignment: .top, spacing: UIDesignSystem.Spacing.lg) {
                VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
                    Text("\(appLanguage.string("ota.packet_size")): \(ble.otaChunkSizeBytes) B")
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text("\(appLanguage.string("ota.total_size")): \(otaTotalSizeDisplay)")
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
                Spacer()
                // 进行中：已用时间、剩余时间、速率
                if ble.isOTAInProgress {
                    VStack(alignment: .trailing, spacing: UIDesignSystem.Spacing.xs) {
                        Text("\(appLanguage.string("ota.elapsed")): \(otaElapsedDisplay)")
                            .font(UIDesignSystem.Typography.monospacedCaption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                        Text("\(appLanguage.string("ota.remaining")): \(otaRemainingDisplay)")
                            .font(UIDesignSystem.Typography.monospacedCaption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                        Text("\(appLanguage.string("ota.rate")): \(otaRateDisplay)")
                            .font(UIDesignSystem.Typography.monospacedCaption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    }
                }
                // 已完成（成功）：总耗时
                else if ble.otaProgress >= 1, !ble.isOTAFailed, !ble.isOTACancelled, let dur = ble.otaCompletedDuration {
                    Text("\(appLanguage.string("ota.duration")): \(formatOTATime(dur))")
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
            }
            
            if ble.isOTAInProgress {
                ProgressView(value: ble.otaProgress)
                    .progressViewStyle(.linear)
            }
            
            // 升级过程中临时允许一个按键用于触发取消升级
            if ble.isOTAInProgress {
                Button {
                    ble.cancelOTA()
                } label: {
                    Text(appLanguage.string("ota.cancel_upgrade"))
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: UIDesignSystem.Component.actionButtonWidth)
                .tint(.orange)
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(UIDesignSystem.CornerRadius.sm)
    }
    
    private func formatOTATime(_ sec: TimeInterval) -> String {
        let total = max(0, Int(sec))
        let m = min(99, total / 60)
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    private var otaTotalSizeDisplay: String {
        guard let total = ble.otaFirmwareTotalBytes, total > 0 else { return "—" }
        if total < 1024 { return "\(total) B" }
        if total < 1024 * 1024 { return "\(total / 1024) KB" }
        return String(format: "%.2f MB", Double(total) / (1024 * 1024))
    }
    
    private var otaElapsedDisplay: String {
        guard ble.isOTAInProgress, let start = ble.otaStartTime else { return "—" }
        return formatOTATime(Date().timeIntervalSince(start))
    }
    
    private var otaRemainingDisplay: String {
        guard ble.isOTAInProgress else { return "—" }
        let progress = ble.otaProgress
        guard progress > 0, progress < 1 else { return "00:00" }
        guard let total = ble.otaFirmwareTotalBytes, total > 0,
              let start = ble.otaStartTime else { return "—" }
        let elapsed = Date().timeIntervalSince(start)
        let bytesSent = Int(progress * Double(total))
        guard bytesSent > 0, elapsed > 0 else { return "—" }
        let rate = Double(bytesSent) / elapsed
        let remainingBytes = Int((1 - progress) * Double(total))
        let remaining = rate > 0 ? TimeInterval(remainingBytes) / rate : 0
        return formatOTATime(remaining)
    }
    
    private var otaRateDisplay: String {
        guard ble.isOTAInProgress,
              let total = ble.otaFirmwareTotalBytes, total > 0,
              let start = ble.otaStartTime else { return "—" }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return "—" }
        let bytesSent = Int(ble.otaProgress * Double(total))
        let rateBps = Double(bytesSent) / elapsed
        let kbps = Int(rateBps * 8 / 1000)
        return "\(min(999, max(0, kbps))) kbps"
    }
    
    /// OTA 状态文本
    private var otaStatusText: String {
        if ble.isOTAFailed {
            return appLanguage.string("ota.failed")
        } else if ble.isOTACancelled {
            return appLanguage.string("ota.cancelled")
        } else if ble.isOTACompletedWaitingReboot {
            return appLanguage.string("ota.waiting_reboot")
        } else if ble.isOTAInProgress {
            return "\(appLanguage.string("ota.progress")): \(Int(ble.otaProgress * 100))%"
        }
        return appLanguage.string("ota.ready")
    }

    /// 加载测试规则配置
    private func loadTestRules() -> (steps: [TestStep], bootloaderVersion: String, firmwareVersion: String, hardwareVersion: String, thresholds: TestThresholds, stepFatalOnFailure: [String: Bool]) {
        // 加载步骤顺序和启用状态（含断开前 OTA、确保电磁阀开启、重启、恢复出厂、气体泄漏检测、屏蔽气体自检等步骤）
        let stepMap = [TestStep.connectDevice, .verifyFirmware, .readRTC, .readPressure, .disableDiag, .readGasSystemStatus, .gasLeakOpen, .gasLeakClosed, .tbd, .ensureValveOpen, .reset, .factoryReset, .otaBeforeDisconnect, .disconnectDevice]
            .reduce(into: [:]) { $0[$1.id] = $1 }
        
        var steps: [TestStep] = []
        if let saved = UserDefaults.standard.array(forKey: "production_test_steps_order") as? [String] {
            for id in saved {
                let migratedId = TestStep.migrateLegacyStepId(id)
                if let step = stepMap[migratedId] {
                    steps.append(step)
                }
            }
        } else {
            steps = [.connectDevice, .verifyFirmware, .readRTC, .readPressure, .disableDiag, .readGasSystemStatus, .gasLeakOpen, .gasLeakClosed, .ensureValveOpen, .reset, .factoryReset, .tbd, .otaBeforeDisconnect, .disconnectDevice]
        }
        
        // 确保第一步和最后一步在正确位置
        if !steps.isEmpty && steps[0].id != TestStep.connectDevice.id {
            steps.removeAll { $0.id == TestStep.connectDevice.id }
            steps.insert(TestStep.connectDevice, at: 0)
        }
        if steps.last?.id != TestStep.disconnectDevice.id {
            steps.removeAll { $0.id == TestStep.disconnectDevice.id }
            steps.append(TestStep.disconnectDevice)
        }
        // 迁移：若旧配置中无「断开前 OTA」步骤，则插入在断开连接之前，默认启用
        if !steps.contains(where: { $0.id == TestStep.otaBeforeDisconnect.id }) {
            steps.insert(TestStep.otaBeforeDisconnect, at: steps.count - 1)
        }
        // 迁移：若旧配置中无「确保电磁阀开启」步骤，则插入在断开连接之前
        if !steps.contains(where: { $0.id == TestStep.ensureValveOpen.id }) {
            steps.insert(TestStep.ensureValveOpen, at: steps.count - 1)
        }
        // 迁移：若旧配置中无「屏蔽气体自检」步骤，则插入在读取压力之后
        if !steps.contains(where: { $0.id == TestStep.disableDiag.id }) {
            if let idx = steps.firstIndex(where: { $0.id == TestStep.readPressure.id }) {
                steps.insert(TestStep.disableDiag, at: idx + 1)
            } else if let idx = steps.firstIndex(where: { $0.id == TestStep.readGasSystemStatus.id }) {
                steps.insert(TestStep.disableDiag, at: idx)
            } else {
                steps.insert(TestStep.disableDiag, at: steps.count - 1)
            }
        }
        // 迁移：若旧配置中无「读取 Gas system status」步骤，则插入在读取压力/屏蔽自检之后、确保电磁阀之前
        if !steps.contains(where: { $0.id == TestStep.readGasSystemStatus.id }) {
            if let idx = steps.firstIndex(where: { $0.id == TestStep.disableDiag.id }) {
                steps.insert(TestStep.readGasSystemStatus, at: idx + 1)
            } else if let idx = steps.firstIndex(where: { $0.id == TestStep.readPressure.id }) {
                steps.insert(TestStep.readGasSystemStatus, at: idx + 1)
            } else if let idx = steps.firstIndex(where: { $0.id == TestStep.ensureValveOpen.id }) {
                steps.insert(TestStep.readGasSystemStatus, at: idx)
            } else {
                steps.insert(TestStep.readGasSystemStatus, at: steps.count - 1)
            }
        }
        // 迁移：若旧配置中无「气体泄漏检测（开阀压力）」步骤，则插入在读取 Gas system status 之后
        if !steps.contains(where: { $0.id == TestStep.gasLeakOpen.id }) {
            if let idx = steps.firstIndex(where: { $0.id == TestStep.readGasSystemStatus.id }) {
                steps.insert(TestStep.gasLeakOpen, at: idx + 1)
            } else if let idx = steps.firstIndex(where: { $0.id == TestStep.ensureValveOpen.id }) {
                steps.insert(TestStep.gasLeakOpen, at: idx)
            } else {
                steps.insert(TestStep.gasLeakOpen, at: steps.count - 1)
            }
        }
        // 迁移：若旧配置中无「气体泄漏检测（关阀压力）」步骤，则插入在开阀压力步骤之后
        if !steps.contains(where: { $0.id == TestStep.gasLeakClosed.id }) {
            if let idx = steps.firstIndex(where: { $0.id == TestStep.gasLeakOpen.id }) {
                steps.insert(TestStep.gasLeakClosed, at: idx + 1)
            } else if let idx = steps.firstIndex(where: { $0.id == TestStep.ensureValveOpen.id }) {
                steps.insert(TestStep.gasLeakClosed, at: idx)
            } else {
                steps.insert(TestStep.gasLeakClosed, at: steps.count - 1)
            }
        }
        // 迁移：若旧配置中无「重启」「恢复出厂」步骤，则插入在断开连接之前
        if !steps.contains(where: { $0.id == TestStep.reset.id }) {
            if let idx = steps.firstIndex(where: { $0.id == TestStep.otaBeforeDisconnect.id }) {
                steps.insert(TestStep.reset, at: idx)
            } else {
                steps.insert(TestStep.reset, at: steps.count - 1)
            }
        }
        if !steps.contains(where: { $0.id == TestStep.factoryReset.id }) {
            if let idx = steps.firstIndex(where: { $0.id == TestStep.otaBeforeDisconnect.id }) {
                steps.insert(TestStep.factoryReset, at: idx)
            } else {
                steps.insert(TestStep.factoryReset, at: steps.count - 1)
            }
        }
        // 重启、恢复出厂只允许在倒数第三步或倒数第二步（与规则页一致）
        ProductionTestRulesView.ensureResetAndFactoryResetBetweenSecondAndSecondToLast(steps: &steps)
        
        // 加载每个步骤的启用状态（step_reset 产测中不许启用，始终为 false）；兼容旧版 step1～step4 的 key
        if let enabledDict = UserDefaults.standard.dictionary(forKey: "production_test_steps_enabled") as? [String: Bool] {
            for i in 0..<steps.count {
                if steps[i].id == TestStep.reset.id {
                    steps[i] = TestStep(id: steps[i].id, key: steps[i].key, isLocked: steps[i].isLocked, enabled: false)
                } else {
                    let enabledValue = enabledDict[steps[i].id] ?? TestStep.legacyStepId(for: steps[i].id).flatMap { enabledDict[$0] }
                    if let enabled = enabledValue {
                        steps[i] = TestStep(id: steps[i].id, key: steps[i].key, isLocked: steps[i].isLocked, enabled: enabled)
                    } else if (steps[i].id == TestStep.gasLeakOpen.id || steps[i].id == TestStep.gasLeakClosed.id),
                              let legacyEnabled = enabledDict["step_gas_leak"] {
                        steps[i] = TestStep(id: steps[i].id, key: steps[i].key, isLocked: steps[i].isLocked, enabled: legacyEnabled)
                    }
                }
            }
        }
        
        // 加载版本配置（BOOTLOADER 默认为 2；固件版本从服务器拉取 OTA 列表，本地已有缓存则不重复拉取）
        let bootloaderVersion = UserDefaults.standard.string(forKey: "production_test_bootloader_version").flatMap { $0.isEmpty ? nil : $0 } ?? "2"
        let firmwareVersion = UserDefaults.standard.string(forKey: "production_test_firmware_version") ?? ""
        let hardwareVersion = UserDefaults.standard.string(forKey: "production_test_hardware_version") ?? ""
        
        // 加载阈值配置
        let thresholds = TestThresholds(
            stepIntervalMs: UserDefaults.standard.object(forKey: "production_test_step_interval_ms") as? Int ?? 100,
            bluetoothPermissionWaitSeconds: UserDefaults.standard.object(forKey: "production_test_bluetooth_permission_wait_seconds") as? Double ?? 0,
            rtcPassThreshold: UserDefaults.standard.object(forKey: "production_test_rtc_pass_threshold") as? Double ?? 2.0,
            rtcFailThreshold: UserDefaults.standard.object(forKey: "production_test_rtc_fail_threshold") as? Double ?? 5.0,
            rtcWriteEnabled: UserDefaults.standard.object(forKey: "production_test_rtc_write_enabled") as? Bool ?? true,
            rtcWriteRetryCount: UserDefaults.standard.object(forKey: "production_test_rtc_write_retry_count") as? Int ?? 3,
            rtcReadTimeout: UserDefaults.standard.object(forKey: "production_test_rtc_read_timeout") as? Double ?? 2.0,
            deviceInfoReadTimeout: UserDefaults.standard.object(forKey: "production_test_device_info_timeout") as? Double ?? 3.0,
            otaStartWaitTimeout: UserDefaults.standard.object(forKey: "production_test_ota_start_timeout") as? Double ?? 5.0,
            deviceReconnectTimeout: UserDefaults.standard.object(forKey: "production_test_reconnect_timeout") as? Double ?? 5.0,
            valveOpenTimeout: UserDefaults.standard.object(forKey: "production_test_valve_open_timeout") as? Double ?? 5.0,
            disableDiagWaitSeconds: UserDefaults.standard.object(forKey: "production_test_disable_diag_wait_seconds") as? Double ?? 2.0,
            disableDiagExpectedGasStatus: {
                let v = UserDefaults.standard.object(forKey: "production_test_disable_diag_expected_gas_status")
                // 兼容多值文本，例如 "0,1"
                if let s = v as? String {
                    if let first = s.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " }).first,
                       let intVal = Int(first) {
                        return max(0, min(9, intVal))
                    }
                    return 1
                }
                if let i = v as? Int { return max(0, min(9, i)) }
                if let d = v as? Double { return max(0, min(9, Int(d))) }
                return 1
            }(),
            disableDiagPollTimeoutSeconds: UserDefaults.standard.object(forKey: "production_test_disable_diag_poll_timeout_seconds") as? Double ?? 3.0,
            disableDiagPollGasStatusEnabled: UserDefaults.standard.object(forKey: "production_test_disable_diag_poll_gas_status_enabled") as? Bool ?? true,
            pressureClosedMin: UserDefaults.standard.object(forKey: "production_test_pressure_closed_min") as? Double ?? 1000,
            pressureClosedMax: UserDefaults.standard.object(forKey: "production_test_pressure_closed_max") as? Double ?? 1350,
            pressureOpenMin: UserDefaults.standard.object(forKey: "production_test_pressure_open_min") as? Double ?? 1000,
            pressureOpenMax: UserDefaults.standard.object(forKey: "production_test_pressure_open_max") as? Double ?? 1500,
            pressureDiffCheckEnabled: UserDefaults.standard.object(forKey: "production_test_pressure_diff_check_enabled") as? Bool ?? true,
            pressureDiffMin: UserDefaults.standard.object(forKey: "production_test_pressure_diff_min") as? Double ?? 0,
            pressureDiffMax: UserDefaults.standard.object(forKey: "production_test_pressure_diff_max") as? Double ?? 400,
            firmwareUpgradeEnabled: UserDefaults.standard.object(forKey: "production_test_firmware_upgrade_enabled") as? Bool ?? true,
            skipFactoryResetAndDisconnectOnFail: UserDefaults.standard.object(forKey: "production_test_skip_factory_reset_and_disconnect_on_fail") as? Bool ?? false,
            pressureFailRetryConfirmEnabled: UserDefaults.standard.object(forKey: "production_test_pressure_fail_retry_confirm_enabled") as? Bool ?? true
        )
        
        // 加载每步「失败时是否终止产测」配置；未配置的步骤沿用规则层静态默认（stepIdsFatalOnFailure）；旧 step1～step4 迁移为语义化 id
        let rawFatal = UserDefaults.standard.dictionary(forKey: "production_test_steps_fatal_on_failure") as? [String: Bool] ?? [:]
        let stepFatalOnFailure = Dictionary(uniqueKeysWithValues: rawFatal.map { (TestStep.migrateLegacyStepId($0.key), $0.value) })

        return (steps: steps, bootloaderVersion: bootloaderVersion, firmwareVersion: firmwareVersion, hardwareVersion: hardwareVersion, thresholds: thresholds, stepFatalOnFailure: stepFatalOnFailure)
    }
    
    /// 测试阈值配置结构
    struct TestThresholds {
        let stepIntervalMs: Int               // 每个测试步骤之间的等待时间（毫秒），SOP 定义
        let bluetoothPermissionWaitSeconds: Double  // 连接设备步骤后等待秒数（供用户处理蓝牙权限/配对弹窗，0=不等待）
        let rtcPassThreshold: Double          // RTC时间差通过阈值（秒）
        let rtcFailThreshold: Double         // RTC时间差失败阈值（秒）
        let rtcWriteEnabled: Bool             // 是否启用RTC写入
        let rtcWriteRetryCount: Int          // RTC写入重试次数
        let rtcReadTimeout: Double            // RTC读取超时（秒）
        let deviceInfoReadTimeout: Double      // 设备信息读取超时（秒）
        let otaStartWaitTimeout: Double       // OTA启动等待超时（秒）
        let deviceReconnectTimeout: Double    // 设备重新连接超时（秒）
        let valveOpenTimeout: Double          // 阀门打开超时（秒）
        let disableDiagWaitSeconds: Double   // Disable diag 发送完成后等待时间（秒），默认 2
        let disableDiagExpectedGasStatus: Int   // Disable diag 轮询 Gas status 时期望的值（0–9，1=ok）
        let disableDiagPollTimeoutSeconds: Double   // Disable diag 轮询 Gas status 超时（秒），默认 3
        let disableDiagPollGasStatusEnabled: Bool   // Disable diag 是否轮询 Gas status 直至期望值，默认 true
        let pressureClosedMin: Double        // 关闭状态压力下限（mbar）
        let pressureClosedMax: Double        // 关闭状态压力上限（mbar）
        let pressureOpenMin: Double          // 开启状态压力下限（mbar）
        let pressureOpenMax: Double          // 开启状态压力上限（mbar）
        let pressureDiffCheckEnabled: Bool   // 是否启用压力差值检查
        let pressureDiffMin: Double          // 压力差值下限（mbar）
        let pressureDiffMax: Double          // 压力差值上限（mbar）
        let firmwareUpgradeEnabled: Bool     // 是否启用固件版本升级
        let skipFactoryResetAndDisconnectOnFail: Bool  // 测试失败时是否跳过恢复出厂与安全断开（默认 false）
        let pressureFailRetryConfirmEnabled: Bool    // 压力读取失败时是否弹窗确认重测（默认 true）
    }
    
    /// 日志函数（类级别，供所有方法使用）：写入产测日志区，并同步到主日志区（格式 [FQC] 或 [FQC][OTA]:，遵循日志等级配置）
    /// - Parameters:
    ///   - msg: 日志内容
    ///   - level: 日志等级（影响主日志区过滤）
    ///   - category: 可选分类，如 "OTA" 时主日志区输出为 [FQC][OTA]: ...
    private func log(_ msg: String, level: LogLevel = .info, category: String? = nil) {
        let prefix: String
        switch level {
        case .error:
            prefix = "❌"
        case .warning:
            prefix = "⚠️"
        case .info:
            prefix = "ℹ️"
        case .debug:
            prefix = "🔍"
        }
        let line = "\(stepIndex): \(prefix) \(msg)"
        testLog.append(line)
        stepIndex += 1
        // 同步到主日志区：产测前缀 [FQC]，OTA 相关用 [FQC][OTA]:，并遵循日志等级过滤
        let fqcLine: String
        if let cat = category, !cat.isEmpty {
            fqcLine = "[FQC][\(cat)]: \(line)"
        } else {
            fqcLine = "[FQC] \(line)"
        }
        let bleLevel: BLEManager.LogLevel
        switch level {
        case .debug: bleLevel = .debug
        case .info: bleLevel = .info
        case .warning: bleLevel = .warning
        case .error: bleLevel = .error
        }
        ble.appendLog(fqcLine, level: bleLevel)
    }
    
    /// 与 log 类似，但将大段 payload 不写入日志行，而是通过 BLEManager 的「点击预览」机制展示；用于上传产测记录 payload 等避免刷屏
    private func logWithPayloadPreview(_ shortMessage: String, payloadJson: String, level: LogLevel = .info) {
        let prefix: String
        switch level {
        case .error: prefix = "❌"
        case .warning: prefix = "⚠️"
        case .info: prefix = "ℹ️"
        case .debug: prefix = "🔍"
        }
        let line = "\(stepIndex): \(prefix) \(shortMessage)"
        testLog.append(line)
        stepIndex += 1
        let fqcLine = "[FQC] \(line)"
        let bleLevel: BLEManager.LogLevel
        switch level {
        case .debug: bleLevel = .debug
        case .info: bleLevel = .info
        case .warning: bleLevel = .warning
        case .error: bleLevel = .error
        }
        ble.appendLogWithPayloadPreview(fqcLine, payloadJson: payloadJson, level: bleLevel)
    }
    
    /// 流水账：追加一条执行过程记录（步骤开始/结束等），结束时与 summary 一起写入本地文件
    private func appendJournal(stepId: String, event: String, detail: [String: Any]? = nil) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var entry: [String: Any] = ["at": iso.string(from: Date()), "stepId": stepId, "event": event]
        if let d = detail, !d.isEmpty { entry["detail"] = d }
        journalEntries.append(entry)
    }
    
    /// 流水账：记录步骤结束（passed/failed/skipped）
    private func recordStepOutcome(stepId: String, outcome: String) {
        appendJournal(stepId: stepId, event: "step_\(outcome)", detail: nil)
    }
    
    /// 产测记录本地存储根目录：Application Support/BOG Tool/ProductionTestRecords/
    private static var productionTestRecordsBaseURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent("BOG Tool", isDirectory: true).appendingPathComponent("ProductionTestRecords", isDirectory: true)
    }
    
    /// 按小时子目录名：YYYY-MM-DD_HHMM00-HHMM00（以 date 所在小时为准）
    private static func hourlySubdirName(for date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        let y = comps.year ?? 0
        let M = comps.month ?? 1
        let d = comps.day ?? 1
        let h = comps.hour ?? 0
        let hEnd = h == 23 ? 24 : (h + 1)
        let dayPart = String(format: "%04d-%02d-%02d", y, M, d)
        return "\(dayPart)_\(String(format: "%02d", h))0000-\(String(format: "%02d", hEnd))0000"
    }
    
    /// 浮点数保留最多 3 位小数且 JSON 序列化时不再出现长尾（通过字符串往返避免 Double 二进制表示导致的 31.547999999998 等）
    private static func roundDoubleForJSON(_ value: Double) -> Double {
        Double(String(format: "%.3f", value)) ?? value
    }

    /// 构建与 API 一致的产测 payload（summary），供本地写入与上传共用
    private func buildProductionTestPayload(enabledSteps: [TestStep]) -> [String: Any] {
        let roundTo3: (Double) -> Double = { Self.roundDoubleForJSON($0) }
        let sn = (capturedDeviceSN ?? ble.deviceSerialNumber)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endTime = lastTestEndTime ?? Date()
        let startTime = lastTestStartTime ?? endTime
        let durationSeconds = roundTo3(endTime.timeIntervalSince(startTime))
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startTimeStr = isoFormatter.string(from: startTime)
        let endTimeStr = isoFormatter.string(from: endTime)
        let stepsSummary: [[String: Any]] = enabledSteps.enumerated().map { index, step in
            let status: String
            switch stepStatuses[step.id] ?? .pending {
            case .passed: status = "passed"
            case .failed: status = "failed"
            case .skipped: status = "skipped"
            case .pending, .running: status = "pending"
            }
            let stepName = appLanguage.string("production_test_rules.\(step.key)_title")
            return [
                "stepIndex": index + 1,
                "stepName": stepName,
                "stepId": step.id,
                "status": status,
            ] as [String: Any]
        }
        var body: [String: Any] = [
            "deviceSerialNumber": sn,
            "overallPassed": overallTestPassed,
            "needRetest": needRetestAfterOtaReboot,
            "startTime": startTimeStr,
            "endTime": endTimeStr,
            "durationSeconds": durationSeconds,
            "stepsSummary": stepsSummary,
        ]
        let deviceName = capturedDeviceName ?? ble.connectedDeviceName
        if let name = deviceName, !name.isEmpty { body["deviceName"] = name }
        if let v = capturedFirmwareVersion ?? ble.currentFirmwareVersion { body["deviceFirmwareVersion"] = v }
        if let v = capturedBootloaderVersion ?? ble.bootloaderVersion { body["deviceBootloaderVersion"] = v }
        if let v = capturedHardwareRevision ?? ble.deviceHardwareRevision { body["deviceHardwareRevision"] = v }
        if !stepResults.isEmpty { body["stepResults"] = stepResults }
        var testDetails: [String: Any] = [:]
        if let v = capturedRtcDeviceTime { testDetails["rtcDeviceTime"] = v }
        if let v = capturedRtcSystemTime { testDetails["rtcSystemTime"] = v }
        if let v = capturedRtcTimeDiffSeconds { testDetails["rtcTimeDiffSeconds"] = roundTo3(v) }
        if let v = capturedPressureClosedMbar { testDetails["pressureClosedMbar"] = roundTo3(v) }
        if let v = capturedPressureOpenMbar { testDetails["pressureOpenMbar"] = roundTo3(v) }
        if let v = capturedGasSystemStatus { testDetails["gasSystemStatus"] = v }
        if let v = capturedValveState { testDetails["valveState"] = v }
        if let v = capturedGasLeakOpenDeltaMbar { testDetails["gasLeakOpenDeltaMbar"] = roundTo3(v) }
        if let v = capturedGasLeakOpenDurationSeconds { testDetails["gasLeakOpenDurationSeconds"] = roundTo3(v) }
        if let v = capturedGasLeakClosedDeltaMbar { testDetails["gasLeakClosedDeltaMbar"] = roundTo3(v) }
        if let v = capturedGasLeakClosedDurationSeconds { testDetails["gasLeakClosedDurationSeconds"] = roundTo3(v) }
        if let v = capturedGasLeakOpenPhase1AvgBar { testDetails["gasLeakOpenPhase1AvgBar"] = roundTo3(v) }
        if let v = capturedGasLeakClosedPhase1AvgBar { testDetails["gasLeakClosedPhase1AvgBar"] = roundTo3(v) }
        if let v = capturedGasLeakOpenThresholdMbar { testDetails["gasLeakOpenThresholdMbar"] = roundTo3(v) }
        if let v = capturedGasLeakClosedThresholdMbar { testDetails["gasLeakClosedThresholdMbar"] = roundTo3(v) }
        if let v = capturedGasLeakOpenLimitBar { testDetails["gasLeakOpenLimitBar"] = roundTo3(v) }
        if let v = capturedGasLeakClosedLimitBar { testDetails["gasLeakClosedLimitBar"] = roundTo3(v) }
        if let v = capturedGasLeakOpenLimitSource { testDetails["gasLeakOpenLimitSource"] = v }
        if let v = capturedGasLeakClosedLimitSource { testDetails["gasLeakClosedLimitSource"] = v }
        if let v = capturedGasLeakOpenPhase3FirstBar { testDetails["gasLeakOpenPhase3FirstBar"] = roundTo3(v) }
        if let v = capturedGasLeakClosedPhase3FirstBar { testDetails["gasLeakClosedPhase3FirstBar"] = roundTo3(v) }
        if let v = capturedGasLeakOpenUserActionSeconds { testDetails["gasLeakOpenUserActionSeconds"] = roundTo3(v) }
        if let v = capturedGasLeakClosedUserActionSeconds { testDetails["gasLeakClosedUserActionSeconds"] = roundTo3(v) }
        if let v = capturedGasLeakOpenSamples { testDetails["gasLeakOpenSamples"] = v }
        if let v = capturedGasLeakClosedSamples { testDetails["gasLeakClosedSamples"] = v }
        if !testDetails.isEmpty { body["testDetails"] = testDetails }
        return body
    }
    
    /// 在 Finder 中打开产测记录目录（Application Support/BOG Tool/ProductionTestRecords/），不存在则先创建
    private func openProductionTestRecordsDirectory() {
        guard let baseURL = Self.productionTestRecordsBaseURL else { return }
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(baseURL)
    }
    
    /// 将设备序列号转为安全文件名片段：去除首尾空白，非法字符替换为 _，空则返回 no_sn
    private static func sanitizedSNForFilename(_ sn: String?) -> String {
        let raw = (sn ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "no_sn" }
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return raw.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
    }
    
    /// 将本次产测记录（testId + summary + journal）写入按小时分目录的本地文件。文件名规则：{序列号}_{testId}.json，序列号为空时用 no_sn
    private func saveProductionTestRecordToLocalFile(testId: String, summary: [String: Any], journal: [[String: Any]]) {
        guard let baseURL = Self.productionTestRecordsBaseURL else { return }
        let sn = summary["deviceSerialNumber"] as? String
        let sanitizedSN = Self.sanitizedSNForFilename(sn)
        let fileName = "\(sanitizedSN)_\(testId).json"
        let startTime = lastTestStartTime ?? Date()
        let hourDirName = Self.hourlySubdirName(for: startTime)
        let hourDir = baseURL.appendingPathComponent(hourDirName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: hourDir.path) {
            try? FileManager.default.createDirectory(at: hourDir, withIntermediateDirectories: true)
        }
        let record: [String: Any] = ["testId": testId, "summary": summary, "journal": journal]
        let fileURL = hourDir.appendingPathComponent(fileName)
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]),
              let _ = try? data.write(to: fileURL) else {
            self.log("本地产测记录写入失败: \(hourDirName)/\(fileName)", level: .warning)
            return
        }
        self.log("产测记录已保存: \(hourDirName)/\(fileName)", level: .info)
    }
    
    /// 日志级别枚举（与BLEManager保持一致）
    private enum LogLevel {
        case debug
        case info
        case warning
        case error
    }
    
    /// 解析时间差字符串为秒数
    private func parseTimeDiff(_ timeDiffString: String) -> Double {
        // 格式如：+1.5s, -2.3min, +0.5h
        let trimmed = timeDiffString.trimmingCharacters(in: .whitespaces)
        
        if trimmed.hasSuffix("s") {
            let value = Double(trimmed.dropLast()) ?? 0
            return value
        } else if trimmed.hasSuffix("min") {
            let value = Double(trimmed.dropLast(3)) ?? 0
            return value * 60
        } else if trimmed.hasSuffix("h") {
            let value = Double(trimmed.dropLast()) ?? 0
            return value * 3600
        }
        
        return 0
    }
    
    /// 重启/恢复出厂后重连结果：用于恢复出厂步骤根据「Peer removed pairing」判定复位成功
    private enum ReconnectAfterResetResult {
        case reconnected
        case timeout(pairingRemoved: Bool)
        case skipped // 已连接或未选中设备，未执行重连
    }
    
    /// 确保电磁阀处于 OPEN 状态：先读取状态，已开启则直接通过；否则发送开启命令后等待，超时 5s（可配置）。
    /// 重启/恢复出厂后设备会断开，需重新连接以便后续步骤（如 OTA）继续执行；恢复出厂步骤可根据返回的 timeout(pairingRemoved: true) 判定复位成功
    /// - Parameter expectPairingRemoved: 为 true 时表示本次为恢复出厂后的重连，BLE 层将「Peer removed pairing」按 info 处理且检测到后立即视为成功
    private func reconnectAfterTestingReboot(rules: TestThresholds, expectPairingRemoved: Bool = false) async -> ReconnectAfterResetResult {
        defer { ble.isExpectingPairingRemovedFromFactoryReset = false }
        guard let selectedDeviceId = ble.selectedDeviceId,
              let device = ble.discoveredDevices.first(where: { $0.id == selectedDeviceId }) else {
            self.log("无法重连：未选中设备或设备不在列表", level: .warning)
            return .skipped
        }
        if ble.isConnected {
            return .reconnected
        }
        self.log("设备已重启，等待 \(Int(rules.deviceReconnectTimeout))s 内重新连接...", level: .info)
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 给设备 2s 启动时间
        if expectPairingRemoved {
            ble.isExpectingPairingRemovedFromFactoryReset = true
        }
        ble.connect(to: device)
        let maxWait = Int(rules.deviceReconnectTimeout * 10)
        var waitCount = 0
        while isRunning && !ble.isConnected && !ble.lastConnectFailureWasPairingRemoved && waitCount < maxWait {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitCount += 1
        }
        if !ble.isConnected {
            let pairingRemoved = ble.lastConnectFailureWasPairingRemoved
            if pairingRemoved {
                self.log("检测到设备已清除配对，判定恢复出厂成功", level: .info)
            } else {
                self.log("重连超时（\(Int(rules.deviceReconnectTimeout))s）", level: .error)
            }
            return .timeout(pairingRemoved: pairingRemoved)
        }
        var waitCount2 = 0
        while isRunning && !ble.areCharacteristicsReady && waitCount2 < maxWait {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitCount2 += 1
        }
        if ble.areCharacteristicsReady {
            self.log("重连成功，GATT 就绪", level: .info)
        } else {
            self.log("重连后 GATT 未就绪（\(Int(rules.deviceReconnectTimeout))s）", level: .warning)
        }
        return .reconnected
    }
    
    /// 产测提前终止时：若「恢复出厂」已使能且尚未执行，则先执行恢复出厂再结束，确保恢复出厂被使能时一定会执行
    private func runFactoryResetIfEnabledBeforeExit(enabledSteps: [TestStep], thresholds: TestThresholds) async {
        guard enabledSteps.contains(where: { $0.id == TestStep.factoryReset.id }) else { return }
        let status = stepStatuses[TestStep.factoryReset.id] ?? .pending
        guard status != .passed, status != .running else { return }
        guard ble.isConnected else { return }
        self.log("产测提前终止，因恢复出厂已使能，先执行恢复出厂再结束", level: .info)
        stepStatuses[TestStep.factoryReset.id] = .running
        let result = await ble.sendTestingFactoryResetCommand()
        switch result {
        case .sent:
            stepStatuses[TestStep.factoryReset.id] = .passed
            let reconnectResult = await reconnectAfterTestingReboot(rules: thresholds, expectPairingRemoved: true)
        switch reconnectResult {
        case .reconnected, .skipped:
            stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria")
        case .timeout(pairingRemoved: true):
            stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test_rules.step_factory_reset_confirmed_pairing_removed")
        case .timeout(pairingRemoved: false):
            stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria")
        }
        case .timeout:
            self.log("警告：恢复出厂命令已发送但未在约定时间内确认断开", level: .warning)
            stepStatuses[TestStep.factoryReset.id] = .passed
            let reconnectResult = await reconnectAfterTestingReboot(rules: thresholds, expectPairingRemoved: true)
            switch reconnectResult {
            case .reconnected, .skipped:
                stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria") + appLanguage.string("production_test.step_factory_reset_not_confirmed")
            case .timeout(pairingRemoved: true):
                stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test_rules.step_factory_reset_confirmed_pairing_removed")
            case .timeout(pairingRemoved: false):
                stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria") + appLanguage.string("production_test.step_factory_reset_not_confirmed")
            }
        case .rejectedByVersion:
            self.log("固件版本不支持恢复出厂命令，步骤跳过", level: .warning)
            stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test.overlay_step_skipped_version")
            stepStatuses[TestStep.factoryReset.id] = .skipped
        case .notReady:
            stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test.factory_reset_not_ready")
            stepStatuses[TestStep.factoryReset.id] = .failed
        }
    }

    /// 步骤失败后的统一处理：根据规则层配置（或静态 `TestStep.stepIdsFatalOnFailure`）决定终止产测（return）或仅本步失败（break）。
    /// 调用方应先设置 `stepStatuses[step.id] = .failed` 和 `stepResults[step.id]`，再调用本方法。
    /// - Returns: true 表示调用方应 return 终止产测，false 表示调用方应 break 继续下一步。
    private func handleStepFailureShouldExit(step: TestStep, enabledSteps: [TestStep], thresholds: TestThresholds, stepFatalOnFailure: [String: Bool]) async -> Bool {
        let isFatal = stepFatalOnFailure[step.id] ?? TestStep.stepIdsFatalOnFailure.contains(step.id)
        guard isFatal else { return false }
        isRunningFactoryResetBeforeExit = true
        defer { isRunningFactoryResetBeforeExit = false }
        if !thresholds.skipFactoryResetAndDisconnectOnFail {
            await runFactoryResetIfEnabledBeforeExit(enabledSteps: enabledSteps, thresholds: thresholds)
        } else {
            self.log("已开启「测试失败时跳过恢复出厂与安全断开」，不执行恢复出厂", level: .info)
        }
        isRunning = false
        expandedSteps.remove(step.id)
        currentStepId = nil
        updateTestResultStatus()
        finishProductionTestRunWithReportAndUpload(enabledSteps: enabledSteps)
        return true
    }

    /// 是否存在任意启用步骤已失败（用于「测试失败时跳过恢复出厂与安全断开」判断）；excluding 中的 stepId 不参与判断。
    private func hasAnyEnabledStepFailed(stepStatuses: [String: StepTestStatus], enabledSteps: [TestStep], excluding: Set<String>) -> Bool {
        enabledSteps.contains { !excluding.contains($0.id) && stepStatuses[$0.id] == .failed }
    }

    private func ensureValveOpen() async -> Bool {
        let rules = loadTestRules()
        let valveTimeout = rules.thresholds.valveOpenTimeout
        
        // 先读取当前阀门状态
        ble.readValveState()
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // 如果已经是打开状态，直接通过
        if ble.lastValveStateValue == "open" {
            self.log("阀门已为开启状态，直接通过", level: .info)
            return true
        }
        
        // 判断为关闭，需要打开，尝试重新写入开启
        self.log("电磁阀当前为关闭状态，尝试重新写入开启", level: .info)
        self.log("确保阀门打开...", level: .info)
        ble.setValve(open: true)
        
        let targetState = "open"
        let startTime = Date()
        var checkCount = 0
        let maxChecks = Int(valveTimeout * 10) // 每 0.1 秒检查一次
        
        while checkCount < maxChecks {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 秒
            checkCount += 1
            ble.readValveState() // 每次循环重新读取状态
            try? await Task.sleep(nanoseconds: 50_000_000)  // 给读回包一点时间
            
            if ble.lastValveStateValue == targetState {
                self.log("阀门已打开", level: .info)
                return true
            }
            if Date().timeIntervalSince(startTime) >= valveTimeout {
                self.log("错误：阀门打开失败（超时，\(Int(valveTimeout))秒）", level: .error)
                return false
            }
        }
        
        self.log("错误：阀门打开失败（超时，\(Int(valveTimeout))秒）", level: .error)
        return false
    }
    
    /// 将电磁阀设为指定状态并等待回读确认（用于气体泄漏检测的判定压力对应状态）
    private func ensureValveState(open targetOpen: Bool) async -> Bool {
        let rules = loadTestRules()
        let valveTimeout = rules.thresholds.valveOpenTimeout
        let targetState = targetOpen ? "open" : "closed"
        
        ble.readValveState()
        try? await Task.sleep(nanoseconds: 500_000_000)
        if ble.lastValveStateValue == targetState {
            self.log("电磁阀已是\(targetState)状态", level: .info)
            return true
        }
        self.log("将电磁阀切换为\(targetState)...", level: .info)
        ble.setValve(open: targetOpen)
        var checkCount = 0
        let maxChecks = Int(valveTimeout * 10)
        while checkCount < maxChecks {
            try? await Task.sleep(nanoseconds: 100_000_000)
            checkCount += 1
            ble.readValveState()
            try? await Task.sleep(nanoseconds: 50_000_000)
            if ble.lastValveStateValue == targetState {
                self.log("电磁阀已切换为\(targetState)", level: .info)
                return true
            }
        }
        self.log("错误：电磁阀未能切换为\(targetState)（超时）", level: .error)
        return false
    }
    
    /// 轮询等待压力读取结果，直到值有效（非 "--" 且非空、非 "Error..."）或超时。用于产测步骤4：BLE 读是异步的，固定 500ms 可能尚未收到回调，导致 lastPressureValue 仍为 "--" 无法解析。
    private func waitForPressureValue(getValue: @Sendable @escaping () -> String, timeoutSeconds: Double, pollIntervalMs: Int, label: String) async -> String {
        let pollNs = UInt64(pollIntervalMs) * 1_000_000
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let value = await MainActor.run(body: getValue)
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && trimmed != "--" && !trimmed.hasPrefix("Error") {
                return value
            }
            try? await Task.sleep(nanoseconds: pollNs)
        }
        return await MainActor.run(body: getValue)
    }
    
    /// 从 BLE 压力显示字符串解析 bar 值（支持 "0.123 bar" 或 "123 mbar"）
    private static func parseBarFromPressureString(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("Error") else { return nil }
        let parts = t.split(separator: " ")
        guard let first = parts.first, let value = Double(first) else { return nil }
        if parts.count >= 2, parts.last?.lowercased() == "mbar" {
            return value / 1000.0
        }
        return value
    }
    
    /// 从 UserDefaults 加载产测气体泄漏步骤配置（keyPrefix 为 production_test_gas_leak_open 或 production_test_gas_leak_closed）
    private func loadProductionGasLeakConfig(keyPrefix: String) -> ProductionGasLeakConfig {
        let raw = UserDefaults.standard.string(forKey: "\(keyPrefix)_limit_source")
        let limitSource = (raw == kGasLeakLimitSourcePhase3First ? kGasLeakLimitSourcePhase3First : kGasLeakLimitSourcePhase1Avg)
        let rawFloor = UserDefaults.standard.object(forKey: "\(keyPrefix)_limit_floor_bar") as? Double ?? 0
        let limitFloorBar = max(0, rawFloor)
        return ProductionGasLeakConfig(
            preCloseDurationSeconds: UserDefaults.standard.object(forKey: "\(keyPrefix)_pre_close_duration_seconds") as? Int ?? 10,
            postCloseDurationSeconds: UserDefaults.standard.object(forKey: "\(keyPrefix)_post_close_duration_seconds") as? Int ?? 15,
            intervalSeconds: UserDefaults.standard.object(forKey: "\(keyPrefix)_interval_seconds") as? Double ?? 0.5,
            dropThresholdMbar: UserDefaults.standard.object(forKey: "\(keyPrefix)_drop_threshold_mbar") as? Double ?? 15,
            startPressureMinMbar: UserDefaults.standard.object(forKey: "\(keyPrefix)_start_pressure_min_mbar") as? Double ?? 1300,
            requirePipelineReadyConfirm: UserDefaults.standard.object(forKey: "\(keyPrefix)_require_pipeline_ready_confirm") as? Bool ?? true,
            requireValveClosedConfirm: UserDefaults.standard.object(forKey: "\(keyPrefix)_require_valve_closed_confirm") as? Bool ?? true,
            limitSource: limitSource,
            limitFloorBar: limitFloorBar
        )
    }
    
    /// 执行产测气体泄漏检测步骤：阀门预置 → 可选 Phase 1 前气路确认 → Phase 1 采样 → Phase 2 用户确认关阀/采样 → Phase 3 采样 → 判定；关阀压力步骤可选 Phase 4 开阀泄压检测
    private func runProductionGasLeakStep(stepId: String, stepLabel: String, config: ProductionGasLeakConfig) async -> (passed: Bool, message: String) {
        // 产测泄漏检测期间抑制 GATT 底层 rd/wr 日志，只保留高层压力/阀门/判定日志
        ble.suppressGattLogs = true
        ble.suppressSensorDetailLogs = true
        defer {
            ble.suppressGattLogs = false
            ble.suppressSensorDetailLogs = false
        }

        let useOpenPressure = (stepId == TestStep.gasLeakOpen.id)
        let preDur = max(0, config.preCloseDurationSeconds)
        let postDur = max(0, config.postCloseDurationSeconds)
        let interval = max(0.1, min(3.0, config.intervalSeconds))
        let thresholdMbar = max(0, config.dropThresholdMbar)
        
        self.log(
            "\(stepLabel)：判定压力=\(useOpenPressure ? "开阀" : "关阀")，Phase 1=\(preDur)s，Phase 3=\(postDur)s，间隔=\(String(format: "%.2f", interval))s，阈值=\(String(format: "%.1f", thresholdMbar)) mbar，limitSource=\(config.limitSource)，floor=\(String(format: "%.0f", config.limitFloorBar * 1000)) mbar",
            level: .info
        )
        
        // 1. 阀门预置：切换到判定压力对应状态
        let valveOk = await ensureValveState(open: useOpenPressure)
        guard valveOk else {
            return (false, "电磁阀未能切换到判定压力对应状态")
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        ble.readPressure(silent: true)
        ble.readPressureOpen(silent: true)
        ble.readValveState()
        try? await Task.sleep(nanoseconds: 700_000_000)
        
        // 2. Phase 1 前气路确认（可选）
        if !config.requirePipelineReadyConfirm {
            self.log("\(stepLabel)：\(appLanguage.string("production_test.gas_leak_phase1_confirm_skipped"))", level: .info)
        }
        if config.requirePipelineReadyConfirm {
            let confirmed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                DispatchQueue.main.async {
                    self.gasLeakConfirmTitle = appLanguage.string("debug.gas_leak_pipeline_ready_title")
                    self.gasLeakConfirmMessage = appLanguage.string("debug.gas_leak_pipeline_ready_message")
                    self.gasLeakConfirmResume = { cont.resume(returning: $0) }
                    self.showGasLeakConfirmAlert = true
                    self.playProductionHintSound()
                }
            }
            guard confirmed else {
                return (false, appLanguage.string("debug.gas_leak_stop_reason_pipeline_not_confirmed"))
            }
        }
        
        // 3. Phase 1 采样（关阀前）
        struct SamplePoint {
            let t: Double
            let pressureClosed: Double?
            let pressureOpen: Double?
            /// 该时刻读取的阀门状态（用于上传更细腻的产测数据）
            let valveState: String?
            /// 该时刻读取的 Gas 系统状态（用于上传更细腻的产测数据）
            let gasSystemStatus: String?
        }
        var phase1Samples: [SamplePoint] = []
        var betweenSamples: [SamplePoint] = []
        var phase2Samples: [SamplePoint] = []
        var phaseElapsed: Double = 0
        let afterReadWaitNs: UInt64 = 600_000_000
        // 为后续判定流程缓存 Phase 1 平均值，避免多次独立计算导致日志与判定存在细微数值差异
        var cachedPhase1Avg: Double?
        // 统一根据当前步骤使用的压力通道（开阀/关阀）提取用于判定的压力值
        func value(for p: SamplePoint) -> Double? { useOpenPressure ? p.pressureOpen : p.pressureClosed }
        
        while phaseElapsed <= Double(preDur) {
            guard isRunning, ble.isConnected, ble.areCharacteristicsReady else {
                return (false, "连接丢失或用户终止")
            }
            ble.readPressure(silent: true)
            ble.readPressureOpen(silent: true)
            ble.readValveState()
            ble.readGasSystemStatus(silent: true)
            try? await Task.sleep(nanoseconds: afterReadWaitNs)
            let closeBar = Self.parseBarFromPressureString(ble.lastPressureValue)
            let openBar = Self.parseBarFromPressureString(ble.lastPressureOpenValue)
            let valveStr = ble.lastValveStateValue
            let gasStr = ble.lastGasSystemStatusValue
            if closeBar != nil || openBar != nil {
                phase1Samples.append(SamplePoint(t: phaseElapsed, pressureClosed: closeBar, pressureOpen: openBar, valveState: valveStr.isEmpty ? nil : valveStr, gasSystemStatus: gasStr.isEmpty ? nil : gasStr))
                let tStr = String(format: "%.1f", phaseElapsed)
                let closeStr = closeBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                let openStr = openBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                self.log("\(stepLabel)：[Phase 1] t=\(tStr)s，关阀=\(closeStr)，开阀=\(openStr)，阀门=\(valveStr.isEmpty ? "--" : valveStr)，Gas=\(gasStr.isEmpty ? "--" : gasStr)", level: .debug)
            }
            phaseElapsed += interval
            if phaseElapsed <= Double(preDur) {
                let remainingNs = UInt64(max(0, interval - 0.6) * 1_000_000_000)
                if remainingNs > 0 { try? await Task.sleep(nanoseconds: remainingNs) }
            }
        }
        
        self.log("\(stepLabel)：Phase 1 采样完成，共 \(phase1Samples.count) 点", level: .info)
        // 在 Phase 1 结束时立即计算并记录 Phase 1 平均值；若规则使用 Phase 1 平均作为 reference，则在此时明确声明
        let phase1ValuesForDecision = phase1Samples.compactMap { value(for: $0) }
        if !phase1ValuesForDecision.isEmpty {
            let avg = phase1ValuesForDecision.reduce(0, +) / Double(phase1ValuesForDecision.count)
            cachedPhase1Avg = avg
            let avgMbarStr = String(format: "%.1f", avg * 1000)
            self.log("\(stepLabel)：Phase 1 平均=\(avgMbarStr) mbar", level: .info)
            if config.limitSource == kGasLeakLimitSourcePhase1Avg {
                self.log("\(stepLabel)：本次规则使用 Phase 1 平均 \(avgMbarStr) mbar 作为 reference（后续泄漏判定基准）", level: .info)
            }
        }
        
        // 4. Phase 2：用户确认关阀期间采样，并统计耗时
        var userActionDuration: Double = 0
        if !config.requireValveClosedConfirm {
            self.log("\(stepLabel)：\(appLanguage.string("production_test.gas_leak_phase2_skipped"))", level: .info)
        }
        if config.requireValveClosedConfirm {
            let userActionStart = Date()
            var betweenElapsed: Double = 0
            var userConfirmed = false
            
            // 弹出确认弹窗（关阀确认）
            let confirmationTask = Task {
                let confirmed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    DispatchQueue.main.async {
                        self.gasLeakConfirmTitle = appLanguage.string("debug.gas_leak_valve_closed_title")
                        self.gasLeakConfirmMessage = appLanguage.string("debug.gas_leak_valve_closed_message")
                        self.gasLeakConfirmResume = { cont.resume(returning: $0) }
                        self.showGasLeakConfirmAlert = true
                        self.playProductionHintSound()
                    }
                }
                userConfirmed = confirmed
            }
            
            while isRunning, ble.isConnected, ble.areCharacteristicsReady, !userConfirmed {
                ble.readPressure(silent: true)
                ble.readPressureOpen(silent: true)
                ble.readValveState()
                ble.readGasSystemStatus(silent: true)
                try? await Task.sleep(nanoseconds: afterReadWaitNs)
                let closeBar = Self.parseBarFromPressureString(ble.lastPressureValue)
                let openBar = Self.parseBarFromPressureString(ble.lastPressureOpenValue)
                let valveStr = ble.lastValveStateValue
                let gasStr = ble.lastGasSystemStatusValue
                let t = Double(preDur) + betweenElapsed
                if closeBar != nil || openBar != nil {
                    betweenSamples.append(SamplePoint(t: t, pressureClosed: closeBar, pressureOpen: openBar, valveState: valveStr.isEmpty ? nil : valveStr, gasSystemStatus: gasStr.isEmpty ? nil : gasStr))
                    let tStr = String(format: "%.1f", t)
                    let closeStr = closeBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                    let openStr = openBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                    self.log("\(stepLabel)：[Phase 2] t=\(tStr)s，关阀=\(closeStr)，开阀=\(openStr)，阀门=\(valveStr.isEmpty ? "--" : valveStr)，Gas=\(gasStr.isEmpty ? "--" : gasStr)", level: .debug)
                }
                betweenElapsed += interval
                if betweenElapsed > 3600 { break } // 安全上限，避免意外长时间阻塞
                let remainingNs = UInt64(max(0, interval - 0.6) * 1_000_000_000)
                if remainingNs > 0 { try? await Task.sleep(nanoseconds: remainingNs) }
            }
            
            await confirmationTask.value
            guard userConfirmed else {
                return (false, appLanguage.string("debug.gas_leak_stop_reason_valve_not_confirmed"))
            }
            userActionDuration = Date().timeIntervalSince(userActionStart)
            let durationStr = String(format: "%.2f", userActionDuration)
            self.log("\(stepLabel)：Phase 2 采样完成，共 \(betweenSamples.count) 点，耗时 \(durationStr) 秒", level: .info)
        }
        
        // 5. Phase 3 采样（关阀后）
        phaseElapsed = 0
        var hasLoggedPhase3FirstRef = false
        while phaseElapsed <= Double(postDur) {
            guard isRunning, ble.isConnected, ble.areCharacteristicsReady else {
                return (false, "连接丢失或用户终止")
            }
            ble.readPressure(silent: true)
            ble.readPressureOpen(silent: true)
            ble.readValveState()
            ble.readGasSystemStatus(silent: true)
            try? await Task.sleep(nanoseconds: afterReadWaitNs)
            let closeBar = Self.parseBarFromPressureString(ble.lastPressureValue)
            let openBar = Self.parseBarFromPressureString(ble.lastPressureOpenValue)
            let valveStr = ble.lastValveStateValue
            let gasStr = ble.lastGasSystemStatusValue
            let t = Double(preDur) + userActionDuration + phaseElapsed
            if closeBar != nil || openBar != nil {
                phase2Samples.append(SamplePoint(t: t, pressureClosed: closeBar, pressureOpen: openBar, valveState: valveStr.isEmpty ? nil : valveStr, gasSystemStatus: gasStr.isEmpty ? nil : gasStr))
                // 若规则选择 Phase 3 首采样值作为 reference，则在首个有效采样点出现时立即记录 reference 决策
                if config.limitSource == kGasLeakLimitSourcePhase3First,
                   !hasLoggedPhase3FirstRef,
                   let firstRefBar = value(for: phase2Samples[0]) {
                    let refMbarStr = String(format: "%.1f", firstRefBar * 1000)
                    self.log("\(stepLabel)：Phase 3 首采样值=\(refMbarStr) mbar，将作为本次泄漏判定的 reference", level: .info)
                    hasLoggedPhase3FirstRef = true
                }
                let tStr = String(format: "%.1f", t)
                let closeStr = closeBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                let openStr = openBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                self.log("\(stepLabel)：[Phase 3] t=\(tStr)s，关阀=\(closeStr)，开阀=\(openStr)，阀门=\(valveStr.isEmpty ? "--" : valveStr)，Gas=\(gasStr.isEmpty ? "--" : gasStr)", level: .debug)
            }
            phaseElapsed += interval
            if phaseElapsed <= Double(postDur) {
                let remainingNs = UInt64(max(0, interval - 0.6) * 1_000_000_000)
                if remainingNs > 0 { try? await Task.sleep(nanoseconds: remainingNs) }
            }
        }
        
        self.log("\(stepLabel)：Phase 3 采样完成，共 \(phase2Samples.count) 点", level: .info)
        
        // 6. 判定：按配置的 limit 基准（Phase 1 平均或 Phase 3 首个值）计算判定线，Phase 3 最低压力低于判定线则失败
        let phase1Values = phase1Samples.compactMap { value(for: $0) }
        let phase2Values = phase2Samples.compactMap { value(for: $0) }
        guard !phase1Values.isEmpty else {
            return (false, appLanguage.string("production_test.gas_leak_insufficient_phase1"))
        }
        guard !phase2Values.isEmpty else {
            return (false, appLanguage.string("production_test.gas_leak_insufficient_phase2"))
        }
        // 若前面已在 Phase 1 结束时计算过平均值，则此处重用缓存结果，保证日志与判定使用完全一致的数值
        let phase1Avg = cachedPhase1Avg ?? (phase1Values.reduce(0, +) / Double(phase1Values.count))
        let phase2Min = phase2Values.min()!
        let phase3First = phase2Values.first
        let thresholdBar = thresholdMbar / 1000.0
        let referenceBar: Double
        let refLabel: String
        if config.limitSource == kGasLeakLimitSourcePhase3First, let first = phase3First {
            referenceBar = first
            refLabel = appLanguage.string("production_test.gas_leak_limit_ref_phase3_first")
        } else {
            referenceBar = phase1Avg
            refLabel = appLanguage.string("production_test.gas_leak_limit_ref_phase1_avg")
        }
        let thresholdLineBar = referenceBar - thresholdBar
        let effectiveLimitBar = max(thresholdLineBar, config.limitFloorBar)

        // 两种压降：基于 Phase 1 平均值的压降（用于上传与历史兼容），以及基于当前参考值 referenceBar 的压降（用于日志文案）
        let dropFromPhase1Mbar = (phase1Avg - phase2Min) * 1000.0
        let dropFromRefMbar = (referenceBar - phase2Min) * 1000.0

        // 起始压力下限判定（单位 mbar）：Phase 1 平均压力低于下限则直接失败
        let startMbar = phase1Avg * 1000.0
        if startMbar < config.startPressureMinMbar {
            let msg = String(format: appLanguage.string("production_test.gas_leak_start_pressure_below_min"), startMbar, config.startPressureMinMbar)
            self.log("\(stepLabel)：✗ \(msg)", level: .error)
            return (false, msg)
        }

        // 记录 Phase 1 与 Phase 3 的关键统计值，便于后续日志与报表理解
        self.log(
            "\(stepLabel)：Phase 1 平均=\(String(format: "%.1f", phase1Avg * 1000)) mbar，Phase 3 最低=\(String(format: "%.1f", phase2Min * 1000)) mbar，参考=\(String(format: "%.1f", referenceBar * 1000)) mbar，判定线=max(参考−阈值, floor)=\(String(format: "%.1f", effectiveLimitBar * 1000)) mbar",
            level: .info
        )

        // 记录本次气体泄漏检测的压降、Phase 1 均值、阈值和总检测/用户操作时长（用于上传 testDetails）
        let totalDurationSeconds = Double(preDur) + userActionDuration + Double(postDur)
        let roundTo3: (Double) -> Double = { Self.roundDoubleForJSON($0) }
        /// 将单点采样转为上传用字典（含双路压力、阀门状态、Gas 状态，便于产测数据更细腻）
        func sampleToDetailDict(_ s: SamplePoint, phase: Int, pressureBar: Double) -> [String: Any] {
            var d: [String: Any] = [
                "phase": phase,
                "t": roundTo3(s.t),
                "pressureBar": roundTo3(pressureBar),
            ]
            if let v = s.pressureClosed { d["pressureClosedBar"] = roundTo3(v) }
            if let v = s.pressureOpen { d["pressureOpenBar"] = roundTo3(v) }
            if let v = s.valveState, !v.isEmpty { d["valveState"] = v }
            if let v = s.gasSystemStatus, !v.isEmpty { d["gasSystemStatus"] = v }
            return d
        }
        if useOpenPressure {
            // 统一定义：Delta 始终为 referenceBar → Phase 3 最低值的压降（由 limitSource 决定参考值）
            capturedGasLeakOpenDeltaMbar = dropFromRefMbar
            capturedGasLeakOpenDurationSeconds = totalDurationSeconds
            capturedGasLeakOpenPhase1AvgBar = phase1Avg
            capturedGasLeakOpenThresholdMbar = thresholdMbar
            capturedGasLeakOpenLimitBar = effectiveLimitBar
            capturedGasLeakOpenLimitSource = config.limitSource
            capturedGasLeakOpenPhase3FirstBar = phase3First
            capturedGasLeakOpenUserActionSeconds = userActionDuration > 0 ? userActionDuration : nil

            var allSamples: [[String: Any]] = []
            for s in phase1Samples {
                let value = s.pressureOpen ?? s.pressureClosed ?? 0
                allSamples.append(sampleToDetailDict(s, phase: 1, pressureBar: value))
            }
            for s in betweenSamples {
                let value = s.pressureOpen ?? s.pressureClosed ?? 0
                allSamples.append(sampleToDetailDict(s, phase: 2, pressureBar: value))
            }
            for s in phase2Samples {
                let value = s.pressureOpen ?? s.pressureClosed ?? 0
                allSamples.append(sampleToDetailDict(s, phase: 3, pressureBar: value))
            }
            capturedGasLeakOpenSamples = allSamples.isEmpty ? nil : allSamples
        } else {
            // 统一定义：Delta 始终为 referenceBar → Phase 3 最低值的压降（由 limitSource 决定参考值）
            capturedGasLeakClosedDeltaMbar = dropFromRefMbar
            capturedGasLeakClosedDurationSeconds = totalDurationSeconds
            capturedGasLeakClosedPhase1AvgBar = phase1Avg
            capturedGasLeakClosedThresholdMbar = thresholdMbar
            capturedGasLeakClosedLimitBar = effectiveLimitBar
            capturedGasLeakClosedLimitSource = config.limitSource
            capturedGasLeakClosedPhase3FirstBar = phase3First
            capturedGasLeakClosedUserActionSeconds = userActionDuration > 0 ? userActionDuration : nil

            var allSamples: [[String: Any]] = []
            for s in phase1Samples {
                let value = s.pressureClosed ?? s.pressureOpen ?? 0
                allSamples.append(sampleToDetailDict(s, phase: 1, pressureBar: value))
            }
            for s in betweenSamples {
                let value = s.pressureClosed ?? s.pressureOpen ?? 0
                allSamples.append(sampleToDetailDict(s, phase: 2, pressureBar: value))
            }
            for s in phase2Samples {
                let value = s.pressureClosed ?? s.pressureOpen ?? 0
                allSamples.append(sampleToDetailDict(s, phase: 3, pressureBar: value))
            }
            capturedGasLeakClosedSamples = allSamples.isEmpty ? nil : allSamples
        }

        if phase2Min < effectiveLimitBar {
            // 区分失败原因：若有效判定线取的是「判定线下限」，则失败原因是 P2 低于下限；否则是压降超过阈值
            let failDueToFloor = (effectiveLimitBar == config.limitFloorBar)
            let msg: String
            if failDueToFloor {
                msg = String(format: appLanguage.string("production_test.gas_leak_result_fail_below_floor_format"), refLabel, referenceBar * 1000, phase2Min * 1000, config.limitFloorBar * 1000)
            } else {
                // 此处 Δ 统一按「参考值 referenceBar → Phase 3 最低」的压降描述，确保与判定基准一致
                msg = String(format: appLanguage.string("production_test.gas_leak_result_fail_format"), refLabel, referenceBar * 1000, phase2Min * 1000, dropFromRefMbar, thresholdMbar)
            }
            self.log("\(stepLabel)：✗ \(msg)", level: .error)
            return (false, msg)
        }

        // 通过场景同样使用基于 referenceBar 的压降描述，避免与文案中的参考值不一致
        let msgPhase3 = String(
            format: appLanguage.string("production_test.gas_leak_result_pass_format"),
            refLabel,
            referenceBar * 1000,
            phase2Min * 1000,
            dropFromRefMbar,
            thresholdMbar
        )
        self.log("\(stepLabel)：✓ \(msgPhase3)", level: .info)

        // 关阀压力步骤：可选 Phase 4 开阀泄压检测（Phase 3 与 Phase 4 均成功本步才成功）
        if stepId == TestStep.gasLeakClosed.id {
            let phase4Enabled = UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_phase4_enabled") as? Bool ?? true
            if !phase4Enabled {
                self.log("\(stepLabel)：\(appLanguage.string("production_test.gas_leak_phase4_skipped"))", level: .info)
            }
            if phase4Enabled {
                let monitorDur = max(0, UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_phase4_monitor_duration_seconds") as? Int ?? 15)
                let dropWithin = max(0, UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_phase4_drop_within_seconds") as? Int ?? 5)
                let belowMbar = max(0, UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_phase4_pressure_below_mbar") as? Double ?? 100)
                self.log("\(stepLabel)：Phase 4 开阀泄压检测，监测 \(monitorDur)s，\(dropWithin)s 内开阀压力需低于 \(String(format: "%.0f", belowMbar)) mbar", level: .info)

                let valveOk = await ensureValveState(open: true)
                guard valveOk else {
                    self.log("\(stepLabel)：✗ Phase 4 电磁阀未能打开", level: .error)
                    return (false, "Phase 4：电磁阀未能打开")
                }
                try? await Task.sleep(nanoseconds: 700_000_000)

                var phase4Samples: [SamplePoint] = []
                var phase4Elapsed: Double = 0
                var phase4DropAchieved = false
                let phase4Interval = max(0.1, min(3.0, interval))
                let afterReadWaitNs: UInt64 = 600_000_000

                while phase4Elapsed <= Double(monitorDur) {
                    guard isRunning, ble.isConnected, ble.areCharacteristicsReady else {
                        return (false, "连接丢失或用户终止")
                    }
                    ble.readPressure(silent: true)
                    ble.readPressureOpen(silent: true)
                    ble.readValveState()
                    ble.readGasSystemStatus(silent: true)
                    try? await Task.sleep(nanoseconds: afterReadWaitNs)
                    let closeBar = Self.parseBarFromPressureString(ble.lastPressureValue)
                    let openBar = Self.parseBarFromPressureString(ble.lastPressureOpenValue)
                    let valveStr = ble.lastValveStateValue
                    let gasStr = ble.lastGasSystemStatusValue
                    if openBar != nil || closeBar != nil {
                        let openMbar = (openBar ?? 0) * 1000
                        let point = SamplePoint(t: phase4Elapsed, pressureClosed: closeBar, pressureOpen: openBar, valveState: valveStr.isEmpty ? nil : valveStr, gasSystemStatus: gasStr.isEmpty ? nil : gasStr)
                        if phase4Elapsed <= Double(dropWithin) && openMbar < belowMbar {
                            phase4DropAchieved = true
                            phase4Samples.append(point)
                            self.log("\(stepLabel)：[Phase 4] t=\(String(format: "%.1f", phase4Elapsed))s 开阀压力 \(String(format: "%.0f", openMbar)) mbar < \(String(format: "%.0f", belowMbar)) mbar，达标，立即判定通过", level: .info)
                            break
                        }
                        phase4Samples.append(point)
                        let tStr = String(format: "%.1f", phase4Elapsed)
                        let closeStr = closeBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                        let openStr = openBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                        self.log("\(stepLabel)：[Phase 4] t=\(tStr)s，关阀=\(closeStr)，开阀=\(openStr)，阀门=\(valveStr.isEmpty ? "--" : valveStr)，Gas=\(gasStr.isEmpty ? "--" : gasStr)", level: .debug)
                    }
                    phase4Elapsed += phase4Interval
                    if phase4Elapsed <= Double(monitorDur) {
                        let remainingNs = UInt64(max(0, phase4Interval - 0.6) * 1_000_000_000)
                        if remainingNs > 0 { try? await Task.sleep(nanoseconds: remainingNs) }
                    }
                }

                self.log("\(stepLabel)：Phase 4 开阀泄压采样完成，共 \(phase4Samples.count) 点", level: .info)
                if !phase4DropAchieved {
                    let failMsg = String(format: "Phase 4：在 %d s 内开阀压力未低于 %.0f mbar", dropWithin, belowMbar)
                    self.log("\(stepLabel)：✗ \(failMsg)", level: .error)
                    return (false, failMsg)
                }
                self.log("\(stepLabel)：✓ Phase 4 通过（开阀压力已在 \(dropWithin)s 内低于 \(String(format: "%.0f", belowMbar)) mbar）", level: .info)

                // 将 Phase 4 采样并入上传的 raw data（Phase 1～4 一起上传）
                var closedSamples = capturedGasLeakClosedSamples ?? []
                for s in phase4Samples {
                    let pressureBar = s.pressureOpen ?? s.pressureClosed ?? 0
                    closedSamples.append(sampleToDetailDict(s, phase: 4, pressureBar: pressureBar))
                }
                capturedGasLeakClosedSamples = closedSamples.isEmpty ? nil : closedSamples
            }
        }

        let msg = stepId == TestStep.gasLeakClosed.id && (UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_phase4_enabled") as? Bool ?? true)
            ? (msgPhase3 + appLanguage.string("production_test.gas_leak_phase4_passed"))
            : msgPhase3
        return (true, msg)
    }
    
    /// 用户点击「TESTING.」时终止产测
    private func stopProductionTest() {
        guard isRunning else { return }
        isRunning = false
        if let id = currentStepId { expandedSteps.remove(id) }
        currentStepId = nil
        log("用户终止测试", level: .info)
    }
    
    private func runProductionTest() {
        guard !isRunning else { return }
        if let validationMessage = validateRequiredRulesBeforeStart() {
            testLog.removeAll()
            stepLogRanges.removeAll()
            stepIndex = 0
            log(validationMessage, level: .error)
            return
        }
        
        // 检查是否有选中的设备
        guard let selectedDeviceId = ble.selectedDeviceId,
              let device = ble.discoveredDevices.first(where: { $0.id == selectedDeviceId }) else {
            // 没有选中设备，提示用户
            testLog.removeAll()
            stepLogRanges.removeAll()
            stepIndex = 0
            log("错误：请先选中设备", level: .error)
            return
        }
        
        // 如果未连接，先连接设备
        if !ble.isConnected {
            showResultOverlay = false
            needRetestAfterOtaReboot = false
            ble.clearLog()
            isRunning = true
            testLog.removeAll()
            stepLogRanges.removeAll()
            stepIndex = 0
            log("正在连接设备: \(device.name)...", level: .info)
            ble.connect(to: device)
            
            // 等待连接完成，且 GATT 特征就绪（发现服务/特征需要时间），才认为连接完成
            Task { @MainActor in
                var waitCount = 0
                while isRunning && !ble.isConnected && !ble.lastConnectFailureWasPairingRemoved && waitCount < 100 { // 最多等待10秒；配对被移除时立即退出
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
                    waitCount += 1
                }
                if ble.lastConnectFailureWasPairingRemoved {
                    log("[FQC] 蓝牙连接失败：Peer removed pairing information，当前测试终止，请在系统「蓝牙」设置中删除该设备（忘记设备）后重测", level: .error)
                    isRunning = false
                    return
                }
                if !ble.isConnected {
                    log("错误：设备连接失败", level: .error)
                    isRunning = false
                    return
                }
                guard isRunning else { return }
                log("已连接，等待 GATT 特征就绪...", level: .info)
                waitCount = 0
                while isRunning && !ble.areCharacteristicsReady && !ble.lastConnectFailureWasPairingRemoved && waitCount < 100 { // 最多再等10秒；配对被移除时立即退出
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waitCount += 1
                }
                if ble.lastConnectFailureWasPairingRemoved {
                    log("[FQC] 蓝牙连接失败：Peer removed pairing information，当前测试终止，请在系统「蓝牙」设置中删除该设备（忘记设备）后重测", level: .error)
                    isRunning = false
                    return
                }
                if !ble.areCharacteristicsReady {
                    log("错误：连接后 GATT 特征未就绪（10秒）", level: .error)
                    isRunning = false
                    return
                }
                guard isRunning else { return }
                log("GATT 就绪，开始产测", level: .info)
                await executeProductionTest()
            }
        } else {
            // 已连接，直接执行产测流程
            showResultOverlay = false
            needRetestAfterOtaReboot = false
            ble.clearLog()
            isRunning = true
            testLog.removeAll()
            stepLogRanges.removeAll()
            stepIndex = 0
            stepResults.removeAll()
            initializeStepStatuses()
            
            Task { @MainActor in
                await executeProductionTest()
            }
        }
    }
    
    private func executeProductionTest() async {
        // 确保状态已初始化（使用最新的步骤列表），并清空上一轮的设备信息缓存
        stepResults.removeAll()
        stepLogRanges.removeAll()
        expandedSteps.removeAll()
        capturedDeviceSN = nil
        capturedDeviceName = nil
        capturedFirmwareVersion = nil
        capturedBootloaderVersion = nil
        capturedHardwareRevision = nil
        capturedRtcDeviceTime = nil
        capturedRtcSystemTime = nil
        capturedRtcTimeDiffSeconds = nil
        capturedPressureClosedMbar = nil
        capturedPressureOpenMbar = nil
        capturedGasSystemStatus = nil
        capturedValveState = nil
        capturedGasLeakOpenDeltaMbar = nil
        capturedGasLeakClosedDeltaMbar = nil
        capturedGasLeakOpenDurationSeconds = nil
        capturedGasLeakClosedDurationSeconds = nil
        initializeStepStatuses()
        
        currentTestId = String(UUID().uuidString.prefix(8))
        journalEntries = []
        
        // 使用当前的测试步骤列表（已从UserDefaults加载）
        let enabledSteps = currentTestSteps.filter { $0.enabled }
        lastTestStartTime = Date()
        didFinishThisRun = false
        
        // 加载版本配置（用于步骤验证）
        let rules = loadTestRules()
        
        self.log("开始产测流程（共 \(enabledSteps.count) 个步骤）", level: .info)
        self.log("——— 产测参数 ———", level: .info)
        self.log("步骤顺序与启用: \(rules.steps.map { "\($0.id)(\($0.enabled ? "开" : "关"))" }.joined(separator: " → "))", level: .info)
        self.log("版本配置: Bootloader=\(rules.bootloaderVersion.isEmpty ? "(空)" : rules.bootloaderVersion), FW=\(rules.firmwareVersion.isEmpty ? "(空)" : rules.firmwareVersion), HW=\(rules.hardwareVersion.isEmpty ? "(空)" : rules.hardwareVersion)", level: .info)
        let t = rules.thresholds
        self.log("步骤间延时: \(t.stepIntervalMs) ms", level: .info)
        if t.bluetoothPermissionWaitSeconds > 0 {
            self.log("蓝牙权限等待: \(String(format: "%.0f", t.bluetoothPermissionWaitSeconds)) s（连接后若出现弹窗请点击允许）", level: .info)
        }
        self.log("超时: 设备信息=\(t.deviceInfoReadTimeout)s, OTA启动=\(t.otaStartWaitTimeout)s, 重连=\(t.deviceReconnectTimeout)s, RTC读取=\(t.rtcReadTimeout)s, 阀门=\(t.valveOpenTimeout)s", level: .info)
        self.log("RTC: 通过阈值=\(t.rtcPassThreshold)s, 失败阈值=\(t.rtcFailThreshold)s, 写入=\(t.rtcWriteEnabled), 重试=\(t.rtcWriteRetryCount)次", level: .info)
        self.log("压力: 关阀 \(t.pressureClosedMin)~\(t.pressureClosedMax) mbar, 开阀 \(t.pressureOpenMin)~\(t.pressureOpenMax) mbar, 差值检查=\(t.pressureDiffCheckEnabled), 差值 \(t.pressureDiffMin)~\(t.pressureDiffMax) mbar", level: .info)
        self.log("OTA: 若 FW 不匹配则触发 \(t.firmwareUpgradeEnabled ? "是" : "否")", level: .info)
        self.log("———————————————", level: .info)
        
        /// 由 step_verify_firmware（确认固件版本）设置：FW 不匹配且「若 FW 不匹配则触发 OTA」开启时为 true；step_ota 据此决定是否执行 OTA
        var fwMismatchRequiresOTA = false
        
        // 规则：若配置为“开阀压力通过则跳过关阀压力步骤”，且开阀步骤启用并通过，则在执行关阀步骤前跳过
        let skipClosedWhenOpenPasses = UserDefaults.standard.object(forKey: "production_test_gas_leak_skip_closed_when_open_passes") as? Bool ?? false
        
        for step in enabledSteps {
                guard isRunning else {
                    if !didFinishThisRun {
                        if let id = currentStepId { expandedSteps.remove(id) }
                        currentStepId = nil
                        self.log("用户终止测试", level: .info)
                        finishProductionTestRunWithReportAndUpload(enabledSteps: enabledSteps)
                    }
                    return
                }
                // 记录步骤开始时的日志索引
                let logStartIndex = testLog.count
                
                // 步骤开始时：折叠上一步（若有），展开当前步，并让 UI 有机会刷新
                await MainActor.run {
                    if let prev = currentStepId { expandedSteps.remove(prev) }
                    currentStepId = step.id
                    expandedSteps.insert(step.id)
                }
                stepStatuses[step.id] = .running
                appendJournal(stepId: step.id, event: "step_start", detail: nil)
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms，确保步骤列表展开动画/滚动有机会渲染
                
                // 产测过程中若蓝牙连接丢失，直接报错并终止（仅对需要连接的步骤检查，step_connect/最后一步断开除外）
                let stepRequiresConnection = (step.id != TestStep.connectDevice.id && step.id != TestStep.disconnectDevice.id)
                if stepRequiresConnection && !ble.isConnected {
                    if ble.lastConnectFailureWasPairingRemoved {
                        // 特殊错误：系统已移除配对信息，本轮产测无法继续，提示产线在系统蓝牙中忘记设备后重测
                        self.log("[FQC] 蓝牙连接失败：Peer removed pairing information，当前测试终止，请在系统「蓝牙」设置中删除该设备（忘记设备）后重测", level: .error)
                        stepResults[step.id] = appLanguage.string("production_test.connect_fail_pairing_removed")
                    } else {
                        self.log("错误：蓝牙连接已丢失，产测终止", level: .error)
                        stepResults[step.id] = appLanguage.string("production_test.connect_fail_ble_lost")
                    }
                    stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                    stepLogRanges[step.id] = (start: logStartIndex, end: testLog.count)
                    expandedSteps.remove(step.id)
                    currentStepId = nil
                    isRunning = false
                    updateTestResultStatus()
                    finishProductionTestRunWithReportAndUpload(enabledSteps: enabledSteps)
                    return
                }
                
                switch step.id {
                case "step_connect": // 连接设备：已连接且 GATT 就绪才认为连接完成
                    self.log("步骤1: 连接设备", level: .info)
                    if !ble.isConnected {
                        self.log("错误：未连接", level: .error)
                        stepResults[step.id] = appLanguage.string("production_test.connect_fail_not_connected")
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    if !ble.areCharacteristicsReady {
                        self.log("等待 GATT 特征就绪...", level: .info)
                        var charWaitCount = 0
                        let charTimeoutSeconds = 10.0
                        let maxCharWait = Int(charTimeoutSeconds * 10)
                        while isRunning && !ble.areCharacteristicsReady && charWaitCount < maxCharWait {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            charWaitCount += 1
                        }
                        if !ble.areCharacteristicsReady {
                            self.log("错误：GATT 特征未就绪（\(Int(charTimeoutSeconds))秒）", level: .error)
                            stepResults[step.id] = appLanguage.string("production_test.connect_fail_gatt_not_ready")
                            stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                            if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                            break
                        }
                    }
                    self.log("已连接，GATT 就绪", level: .info)
                    stepResults[step.id] = appLanguage.string("production_test.connected_gatt_ready")
                    stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                    
                case "step_verify_firmware": // 确认固件版本
                    self.log("步骤2: 确认固件版本", level: .info)
                    
                    // 等待设备信息读取完成（SN、FW、HW 均等待，使用配置的超时时间）
                    self.log("等待读取设备信息（SN、FW、HW 版本）...", level: .info)
                    let timeoutSeconds = rules.thresholds.deviceInfoReadTimeout
                    let maxWaitCount = Int(timeoutSeconds * 10) // 每0.1秒检查一次
                    var waitCount = 0
                    while isRunning && (ble.deviceSerialNumber == nil || ble.currentFirmwareVersion == nil || ble.deviceHardwareRevision == nil) && waitCount < maxWaitCount {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        waitCount += 1
                        // 每2秒输出一次等待状态
                        if waitCount % 20 == 0 {
                            let elapsed = Double(waitCount) / 10.0
                            self.log("等待中...（已等待 \(String(format: "%.1f", elapsed))秒，超时: \(Int(timeoutSeconds))秒）", level: .debug)
                        }
                    }
                    
                    if waitCount >= maxWaitCount {
                        self.log("警告：设备信息读取超时（\(Int(timeoutSeconds))秒）", level: .warning)
                    } else {
                        self.log("设备信息读取完成", level: .info)
                    }
                    
                    // 验证 SN
                    var resultMessages: [String] = []
                    
                    if let sn = ble.deviceSerialNumber, !sn.isEmpty {
                        self.log("✓ SN 验证通过: \(sn)", level: .info)
                        resultMessages.append("SN: \(sn)")
                        // 立即缓存设备信息，供产测结束后上传使用（步骤2 即使后续 BL/FW/HW 失败也会执行恢复出厂等，上传时仍需 SN）
                        capturedDeviceSN = sn.trimmingCharacters(in: .whitespacesAndNewlines)
                        capturedDeviceName = ble.connectedDeviceName
                        capturedFirmwareVersion = ble.currentFirmwareVersion
                        capturedBootloaderVersion = ble.bootloaderVersion
                        capturedHardwareRevision = ble.deviceHardwareRevision
                    } else {
                        self.log("错误：SN 无效或为空", level: .error)
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = appLanguage.string("production_test.sn_invalid")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    
                    // 验证 Bootloader 版本：
                    // - 若 SOP 中配置了 bootloaderVersion（如 "1" 或 "1,2"），则仅允许在该集合内，否则报错
                    // - 若未配置，则沿用旧逻辑：版本 < 2 报错，其余仅记录实际版本
                    if let blVersionStr = ble.bootloaderVersion {
                        let trimmed = blVersionStr.trimmingCharacters(in: .whitespaces)
                        let blNum = Int(trimmed)
                        let ruleString = rules.bootloaderVersion.trimmingCharacters(in: .whitespaces)

                        if !ruleString.isEmpty, let num = blNum {
                            // 解析 SOP 中允许的 Bootloader 版本列表，例如 "1,2" → [1,2]
                            let allowedNums: [Int] = ruleString
                                .split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace })
                                .compactMap { Int($0) }
                            if !allowedNums.isEmpty {
                                if allowedNums.contains(num) {
                                    self.log("✓ Bootloader 版本验证通过: \(blVersionStr)（允许列表: \(rules.bootloaderVersion)）", level: .info)
                                    resultMessages.append("BL: \(blVersionStr)")
                                } else {
                                    self.log("错误：Bootloader 版本不匹配（期望: \(rules.bootloaderVersion), 实际: \(blVersionStr)）", level: .error)
                                    stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                                    stepResults[step.id] = resultMessages.joined(separator: "\n") + "\n" + appLanguage.string("production_test.bootloader_version_mismatch")
                                    if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                                    break
                                }
                            } else {
                                // 规则解析不到有效数字时，退回旧逻辑
                                if let num = blNum, num < 2 {
                                    self.log("错误：Bootloader 版本过低（当前: \(blVersionStr)，要求 ≥ 2）", level: .error)
                                    stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                                    stepResults[step.id] = resultMessages.joined(separator: "\n") + "\n" + appLanguage.string("production_test.bootloader_too_old")
                                    if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                                    break
                                }
                                resultMessages.append("BL: \(blVersionStr)")
                            }
                        } else {
                            // 未配置规则：仅做“<2 报错”的最低版本检查
                            if let num = blNum, num < 2 {
                                self.log("错误：Bootloader 版本过低（当前: \(blVersionStr)，要求 ≥ 2）", level: .error)
                                stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                                stepResults[step.id] = resultMessages.joined(separator: "\n") + "\n" + appLanguage.string("production_test.bootloader_too_old")
                                if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                                break
                            }
                            resultMessages.append("BL: \(blVersionStr)")
                        }
                    } else {
                        self.log("错误：无法读取 Bootloader 版本", level: .error)
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = resultMessages.joined(separator: "\n") + "\n" + appLanguage.string("production_test.bootloader_unreadable")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    
                    // 验证 FW 版本（仅检查是否需要升级，不在此步执行 OTA；OTA 在「断开前 OTA」步骤执行）
                    if let fwVersion = ble.currentFirmwareVersion {
                        self.log("当前 FW 版本: \(fwVersion)", level: .info)
                        if fwVersion != rules.firmwareVersion {
                            if rules.thresholds.firmwareUpgradeEnabled {
                                fwMismatchRequiresOTA = true
                                self.log("FW 版本不匹配，需要 OTA（期望: \(rules.firmwareVersion), 实际: \(fwVersion)），将在「断开前 OTA」步骤执行", level: .warning, category: "OTA")
                                resultMessages.append("FW: \(fwVersion) → 待OTA")
                                // 提前校验服务器是否提供了目标版本，避免到 OTA 步骤才报错
                                if await productionFirmwareItem(for: rules.firmwareVersion) == nil {
                                    self.log("错误：服务器未提供版本 \(rules.firmwareVersion) 的产线固件，请检查服务器固件列表或产线可见配置", level: .error, category: "OTA")
                                    stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                                    stepResults[step.id] = resultMessages.joined(separator: "\n") + "\n" + String(format: appLanguage.string("production_test.server_no_firmware"), rules.firmwareVersion)
                                    if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                                    break
                                }
                            } else {
                                // 固件升级已禁用：FW 不匹配仅作警告，本步骤仍视为通过
                                self.log("警告：FW 版本不匹配，但固件升级已禁用（期望: \(rules.firmwareVersion), 实际: \(fwVersion)），本步骤按警告处理、仍视为通过", level: .warning)
                                resultMessages.append("FW: \(fwVersion) ⚠️ (升级已禁用，仍通过)")
                            }
                        } else {
                            self.log("✓ FW 版本验证通过: \(fwVersion)", level: .info)
                            resultMessages.append("FW: \(fwVersion) ✓")
                        }
                    } else {
                        self.log("警告：无法读取 FW 版本", level: .warning)
                        resultMessages.append("FW: ⚠️")
                    }
                    
                    // 验证 HW 版本：若 SOP 中配置了 hardwareVersion，则设备必须完全匹配，否则测试失败；未配置时仅记录实际值
                    if let hwVersion = ble.deviceHardwareRevision {
                        let ruleHW = rules.hardwareVersion.trimmingCharacters(in: .whitespaces)
                        if !ruleHW.isEmpty {
                            if hwVersion == ruleHW {
                                self.log("✓ HW 版本验证通过: \(hwVersion)", level: .info)
                                resultMessages.append("HW: \(hwVersion) ✓")
                            } else {
                                self.log("错误：HW 版本不匹配（期望: \(ruleHW), 实际: \(hwVersion)）", level: .error)
                                stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                                stepResults[step.id] = resultMessages.joined(separator: "\n") + "\n" + appLanguage.string("production_test.hardware_version_mismatch")
                                if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                                break
                            }
                        } else {
                            resultMessages.append("HW: \(hwVersion)")
                        }
                    } else {
                        // HW 为可选：设备若未实现 GATT 2A27（Hardware Revision String）则无法读取，属正常
                        self.log("HW 版本未提供（设备可能未实现 2A27 特征）", level: .info)
                        resultMessages.append("HW: −")
                    }
                    
                    stepResults[step.id] = resultMessages.joined(separator: "\n")
                    stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                    // 缓存设备信息，供产测结束后上传使用（与是否仍连接无关）
                    capturedDeviceSN = ble.deviceSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
                    capturedDeviceName = ble.connectedDeviceName
                    capturedFirmwareVersion = ble.currentFirmwareVersion
                    capturedBootloaderVersion = ble.bootloaderVersion
                    capturedHardwareRevision = ble.deviceHardwareRevision
                    
                case "step_read_rtc": // 检查 RTC - step_connect 已保证连接且 GATT 就绪，此处直接读 RTC
                    self.log("步骤3: 检查 RTC", level: .info)
                    self.log("步骤3 判定准则：读取设备 RTC 与系统时间比对，时间差在 ±\(rules.thresholds.rtcPassThreshold)s 内为通过，超过 ±\(rules.thresholds.rtcFailThreshold)s 为失败，中间区间按配置尝试写入/重试。", level: .info)
                    
                    let passThreshold = rules.thresholds.rtcPassThreshold
                    let failThreshold = rules.thresholds.rtcFailThreshold
                    let rtcWriteEnabled = rules.thresholds.rtcWriteEnabled
                    let maxRetries = rules.thresholds.rtcWriteRetryCount
                    let rtcTimeoutSeconds = rules.thresholds.rtcReadTimeout
                    let maxRtcWaitCount = Int(rtcTimeoutSeconds * 10) // 每0.1秒检查一次
                    
                    // 与 Debug 一致的 RTC 读取流程：先清状态、再解锁+延时+读
                    self.log("读取 RTC...", level: .info)
                    ble.clearRTCReadState()
                    ble.readRTCWithUnlock()
                    
                    // 等待RTC读取完成
                    self.log("等待 RTC 读取完成（超时: \(Int(rtcTimeoutSeconds))秒）...", level: .info)
                    var waitCount = 0
                    while isRunning && (ble.lastRTCValue.isEmpty || ble.lastRTCValue == "--") && waitCount < maxRtcWaitCount {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
                        waitCount += 1
                        // 每2秒输出一次等待状态
                        if waitCount % 20 == 0 {
                            let elapsed = Double(waitCount) / 10.0
                            self.log("等待 RTC 读取中...（已等待 \(String(format: "%.1f", elapsed))秒）", level: .debug)
                        }
                    }
                    
                    // 检查RTC读取是否成功
                    if ble.lastRTCValue.isEmpty || ble.lastRTCValue == "--" {
                        if waitCount >= maxRtcWaitCount {
                            self.log("错误：RTC 读取超时（\(Int(rtcTimeoutSeconds))秒）", level: .error)
                        } else {
                            self.log("错误：无法读取RTC值", level: .error)
                        }
                        stepResults[step.id] = appLanguage.string("production_test.rtc_fail_unreadable")
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    } else {
                        let deviceRTCString = ble.lastRTCValue
                        let systemTimeString = ble.lastSystemTimeAtRTCRead
                        var timeDiffString = ble.lastTimeDiffFromRTCRead
                        
                        self.log("设备RTC: \(deviceRTCString)", level: .info)
                        self.log("系统时间: \(systemTimeString)", level: .info)
                        self.log("时间差: \(timeDiffString)", level: .info)
                        
                        var rtcPassed = false
                        var retryCount = 0
                        
                        // 循环检查并写入RTC，直到通过或超过重试次数
                        while !rtcPassed && retryCount <= maxRetries {
                            if timeDiffString == "--" {
                                self.log("错误：无法解析时间差", level: .error)
                                break
                            }
                            
                            let timeDiffSeconds = parseTimeDiff(timeDiffString)
                            let absDiff = abs(timeDiffSeconds)
                            
                            if absDiff <= passThreshold {
                                // 2秒内，直接通过
                                rtcPassed = true
                                self.log("✓ RTC时间比对通过（时间差: \(timeDiffString)，在±\(Int(passThreshold))秒范围内）", level: .info)
                                break
                            } else if absDiff > failThreshold {
                                // 超过5秒，失败
                                self.log("✗ RTC时间比对失败（时间差: \(timeDiffString)，超过±\(Int(failThreshold))秒）", level: .error)
                                break
                            } else {
                                // 2-5秒之间，根据配置决定是否尝试写入RTC
                                if !rtcWriteEnabled {
                                    // RTC写入已禁用，直接判定失败
                                    self.log("✗ RTC时间比对失败（时间差: \(timeDiffString)，在±\(Int(passThreshold))-±\(Int(failThreshold))秒范围内，但RTC写入已禁用）", level: .error)
                                    break
                                } else if retryCount < maxRetries {
                                    self.log("⚠️ RTC时间差 \(timeDiffString) 在±\(Int(passThreshold))-±\(Int(failThreshold))秒范围内，尝试写入RTC（第\(retryCount + 1)/\(maxRetries)次）...", level: .warning)
                                    
                                    // 执行RTC写入（写入当前系统时间，7字节）；writeRTCTime 内部会延时后 readRTC
                                    let logCountBeforeWrite = ble.logEntries.count
                                    ble.writeRTCTime()
                                    try? await Task.sleep(nanoseconds: 500_000_000)
                                    
                                    // 检查是否有RTC写入错误
                                    let recentLogs = Array(ble.logEntries.suffix(ble.logEntries.count - logCountBeforeWrite))
                                    let rtcWriteError = recentLogs.first { logEntry in
                                        logEntry.line.contains("rtc") && (logEntry.line.contains("失败") || logEntry.line.contains("invalid") || logEntry.line.contains("error"))
                                    }
                                    
                                    if let errorLog = rtcWriteError {
                                        let errorMsg = errorLog.line.replacingOccurrences(of: "^\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\s+", with: "", options: .regularExpression)
                                        self.log("❌ RTC写入失败: \(errorMsg)", level: .error)
                                        break
                                    }
                                    
                                    // writeRTCTime() 内部已经会自动读取RTC，等待读取完成
                                    self.log("RTC写入成功，等待读取RTC验证...", level: .info)
                                    waitCount = 0
                                    while isRunning && (ble.lastRTCValue.isEmpty || ble.lastRTCValue == "--") && waitCount < maxRtcWaitCount {
                                        try? await Task.sleep(nanoseconds: 100_000_000)
                                        waitCount += 1
                                    }
                                    
                                    if ble.lastRTCValue.isEmpty || ble.lastRTCValue == "--" {
                                        if waitCount >= maxRtcWaitCount {
                                            self.log("错误：RTC 验证读取超时（\(Int(rtcTimeoutSeconds))秒）", level: .error)
                                        } else {
                                            self.log("错误：重新读取RTC失败", level: .error)
                                        }
                                        break
                                    }
                                    
                                    timeDiffString = ble.lastTimeDiffFromRTCRead
                                    self.log("RTC 读取: \(ble.lastRTCValue)，时间差: \(timeDiffString)", level: .info)
                                    retryCount += 1
                                } else {
                                    // 已达到最大重试次数
                                    self.log("✗ RTC时间比对失败：已重试\(maxRetries)次，仍无法达到±\(Int(passThreshold))秒范围内", level: .error)
                                    break
                                }
                            }
                        }
                        
                        // 更新步骤结果和状态，并缓存 RTC 详情供上传
                        if rtcPassed {
                            stepResults[step.id] = String(format: appLanguage.string("production_test.rtc_result_format"), deviceRTCString, timeDiffString, appLanguage.string("production_test.rtc_time_diff_ok"))
                            stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                        } else {
                            stepResults[step.id] = String(format: appLanguage.string("production_test.rtc_result_format"), deviceRTCString, timeDiffString, appLanguage.string("production_test.rtc_time_diff_fail"))
                            stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                            if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        }
                        capturedRtcDeviceTime = (ble.lastRTCValue.isEmpty || ble.lastRTCValue == "--") ? deviceRTCString : ble.lastRTCValue
                        capturedRtcSystemTime = (ble.lastSystemTimeAtRTCRead.isEmpty || ble.lastSystemTimeAtRTCRead == "--") ? systemTimeString : ble.lastSystemTimeAtRTCRead
                        let diffStr = (ble.lastTimeDiffFromRTCRead.isEmpty || ble.lastTimeDiffFromRTCRead == "--") ? timeDiffString : ble.lastTimeDiffFromRTCRead
                        capturedRtcTimeDiffSeconds = (diffStr != "--" ? parseTimeDiff(diffStr) : nil)
                    }
                    
                case "step_read_pressure": // 读取压力值 - 复用debug mode的方法，并验证阈值；失败且开关打开时可弹窗确认重测
                    self.log("步骤4 判定准则：关阀压力需在 \(rules.thresholds.pressureClosedMin)~\(rules.thresholds.pressureClosedMax) mbar 区间内，开阀压力需在 \(rules.thresholds.pressureOpenMin)~\(rules.thresholds.pressureOpenMax) mbar 区间内；若开启差值检查，则 |开−关| 在 \(Int(rules.thresholds.pressureDiffMin))~\(Int(rules.thresholds.pressureDiffMax)) mbar 区间。", level: .info)
                    var closedPressureValue: Double? = nil
                    var openPressureValue: Double? = nil
                    pressureRetryLoop: while true {
                        // 在开始压力测试前，让产线人员确认气路与阀门状态
                        do {
                            let confirmed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                                DispatchQueue.main.async {
                                    self.gasLeakConfirmTitle = appLanguage.string("production_test.pressure_pipeline_ready_title")
                                    self.gasLeakConfirmMessage = appLanguage.string("production_test.pressure_pipeline_ready_message")
                                    self.gasLeakConfirmResume = { cont.resume(returning: $0) }
                                    self.showGasLeakConfirmAlert = true
                                }
                            }
                            if !confirmed {
                                self.log("步骤4: 用户未确认气路与阀门状态，压力测试终止", level: .warning)
                                stepResults[step.id] = appLanguage.string("production_test.pressure_pipeline_ready_message")
                                stepStatuses[step.id] = .failed
                                recordStepOutcome(stepId: step.id, outcome: "failed")
                                break pressureRetryLoop
                            }
                        }
                        
                        self.log("步骤4: 读取压力值（先开阀→读开阀压力→关阀→读关阀压力）", level: .info)
                        
                        let pressureClosedMin = rules.thresholds.pressureClosedMin
                        let pressureClosedMax = rules.thresholds.pressureClosedMax
                        let pressureOpenMin = rules.thresholds.pressureOpenMin
                        let pressureOpenMax = rules.thresholds.pressureOpenMax
                        
                        // 1. 打开阀门并确保打开成功
                        self.log("打开阀门...", level: .info)
                        ble.setValve(open: true)
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if ble.lastValveStateValue == "open" {
                            self.log("阀门已打开", level: .info)
                        } else {
                            self.log("警告：阀门状态异常（当前: \(ble.lastValveStateValue)）", level: .warning)
                        }
                        
                        // 2. 读取开阀压力（清空旧值后发起读取，轮询等待设备响应，避免固定 500ms 未收到回调导致仍为 "--"）
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        self.log("读取开启状态压力...", level: .info)
                        ble.clearLastPressureOpenValue()
                        ble.readPressureOpen()
                        let openPressureStr = await waitForPressureValue(
                            getValue: { ble.lastPressureOpenValue },
                            timeoutSeconds: 2.5,
                            pollIntervalMs: 100,
                            label: "开阀压力"
                        )
                        if openPressureStr.isEmpty || openPressureStr == "--" {
                            self.log(appLanguage.string("production_test.pressure_read_timeout_open"), level: .warning)
                        } else {
                            self.log("开启压力: \(openPressureStr)", level: .info)
                        }
                        openPressureValue = Self.parseBarFromPressureString(openPressureStr)
                        
                        // 3. 关闭阀门并确保关闭成功
                        self.log("关闭阀门...", level: .info)
                        ble.setValve(open: false)
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if ble.lastValveStateValue == "closed" {
                            self.log("阀门已关闭", level: .info)
                        } else {
                            self.log("警告：阀门状态异常（当前: \(ble.lastValveStateValue)）", level: .warning)
                        }
                        
                        // 4. 读取关闭状态压力（同样轮询等待响应）
                        self.log("读取关闭状态压力...", level: .info)
                        ble.clearLastPressureValue()
                        ble.readPressure()
                        let closedPressureStr = await waitForPressureValue(
                            getValue: { ble.lastPressureValue },
                            timeoutSeconds: 2.5,
                            pollIntervalMs: 100,
                            label: "关阀压力"
                        )
                        if closedPressureStr.isEmpty || closedPressureStr == "--" {
                            self.log(appLanguage.string("production_test.pressure_read_timeout_closed"), level: .warning)
                        } else {
                            self.log("关闭压力: \(closedPressureStr)", level: .info)
                        }
                        closedPressureValue = Self.parseBarFromPressureString(closedPressureStr)
                        
                        var pressurePassed = true
                        var pressureMessages: [String] = []
                        let closedRangeStr = String(format: "%.0f~%.0f mbar", pressureClosedMin, pressureClosedMax)
                        let openRangeStr = String(format: "%.0f~%.0f mbar", pressureOpenMin, pressureOpenMax)
                        let closedDisplayStr = closedPressureValue.map { String(format: "%.0f mbar", $0 * 1000) } ?? "-- mbar"
                        let openDisplayStr = openPressureValue.map { String(format: "%.0f mbar", $0 * 1000) } ?? "-- mbar"
                        
                        if let closedBar = closedPressureValue {
                            let closedMbar = closedBar * 1000.0
                            if closedMbar >= pressureClosedMin && closedMbar <= pressureClosedMax {
                                self.log("✓ 关闭压力验证通过: \(closedMbar) mbar（\(pressureClosedMin)~\(pressureClosedMax) mbar）", level: .info)
                                pressureMessages.append(String(format: appLanguage.string("production_test.pressure_closed_line"), closedDisplayStr, closedRangeStr, appLanguage.string("production_test.pressure_mark_ok")))
                            } else {
                                self.log("✗ 关闭压力验证失败: \(closedMbar) mbar（应在 \(pressureClosedMin)~\(pressureClosedMax) mbar）", level: .error)
                                pressureMessages.append(String(format: appLanguage.string("production_test.pressure_closed_line"), closedDisplayStr, closedRangeStr, appLanguage.string("production_test.pressure_mark_fail")))
                                pressurePassed = false
                            }
                        } else {
                            self.log("警告：无法解析关闭压力值", level: .warning)
                            pressureMessages.append(String(format: appLanguage.string("production_test.pressure_closed_line"), closedDisplayStr, closedRangeStr, appLanguage.string("production_test.pressure_mark_warn")))
                            pressurePassed = false
                        }
                        
                        if let openBar = openPressureValue {
                            let openMbar = openBar * 1000.0
                            if openMbar >= pressureOpenMin && openMbar <= pressureOpenMax {
                                self.log("✓ 开启压力验证通过: \(openMbar) mbar（\(pressureOpenMin)~\(pressureOpenMax) mbar）", level: .info)
                                pressureMessages.append(String(format: appLanguage.string("production_test.pressure_open_line"), openDisplayStr, openRangeStr, appLanguage.string("production_test.pressure_mark_ok")))
                            } else {
                                self.log("✗ 开启压力验证失败: \(openMbar) mbar（应在 \(pressureOpenMin)~\(pressureOpenMax) mbar）", level: .error)
                                pressureMessages.append(String(format: appLanguage.string("production_test.pressure_open_line"), openDisplayStr, openRangeStr, appLanguage.string("production_test.pressure_mark_fail")))
                                pressurePassed = false
                            }
                        } else {
                            self.log("警告：无法解析开启压力值", level: .warning)
                            pressureMessages.append(String(format: appLanguage.string("production_test.pressure_open_line"), openDisplayStr, openRangeStr, appLanguage.string("production_test.pressure_mark_warn")))
                            pressurePassed = false
                        }
                        
                        if rules.thresholds.pressureDiffCheckEnabled {
                            let diffMin = rules.thresholds.pressureDiffMin
                            let diffMax = rules.thresholds.pressureDiffMax
                            let diffRangeStr = "\(Int(diffMin))~\(Int(diffMax)) mbar"
                            if let closedMbar = closedPressureValue.map({ $0 * 1000.0 }),
                               let openMbar = openPressureValue.map({ $0 * 1000.0 }) {
                                let diff = abs(openMbar - closedMbar)
                                if diff >= diffMin && diff <= diffMax {
                                    self.log("✓ 压力差值验证通过: \(String(format: "%.0f", diff)) mbar（\(Int(diffMin))~\(Int(diffMax)) mbar）", level: .info)
                                    pressureMessages.append(String(format: appLanguage.string("production_test.pressure_diff_line"), diff, diffRangeStr, appLanguage.string("production_test.pressure_mark_ok")))
                                } else {
                                    self.log("✗ 压力差值验证失败: \(String(format: "%.0f", diff)) mbar（应在 \(Int(diffMin))~\(Int(diffMax)) mbar）", level: .error)
                                    pressureMessages.append(String(format: appLanguage.string("production_test.pressure_diff_line"), diff, diffRangeStr, appLanguage.string("production_test.pressure_mark_fail")))
                                    pressurePassed = false
                                }
                            } else {
                                let closedReason = closedPressureValue == nil ? appLanguage.string("production_test.pressure_value_missing") : appLanguage.string("production_test.pressure_value_read")
                                let openReason = openPressureValue == nil ? appLanguage.string("production_test.pressure_value_missing") : appLanguage.string("production_test.pressure_value_read")
                                self.log(String(format: appLanguage.string("production_test.pressure_diff_uncalc_reason"), closedReason, openReason), level: .warning)
                                pressureMessages.append(appLanguage.string("production_test.pressure_diff_uncalc"))
                                pressurePassed = false
                            }
                        }
                        
                        stepResults[step.id] = pressureMessages.joined(separator: " ") + " " + appLanguage.string("production_test.pressure_criteria_hint")
                        stepStatuses[step.id] = pressurePassed ? .passed : .failed
                        if pressurePassed {
                            recordStepOutcome(stepId: step.id, outcome: "passed")
                            capturedPressureClosedMbar = closedPressureValue.map { $0 * 1000.0 }
                            capturedPressureOpenMbar = openPressureValue.map { $0 * 1000.0 }
                            break pressureRetryLoop
                        }
                        if !rules.thresholds.pressureFailRetryConfirmEnabled {
                            recordStepOutcome(stepId: step.id, outcome: "failed")
                            capturedPressureClosedMbar = closedPressureValue.map { $0 * 1000.0 }
                            capturedPressureOpenMbar = openPressureValue.map { $0 * 1000.0 }
                            break pressureRetryLoop
                        }
                        let userWantsRetry = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                            DispatchQueue.main.async {
                                self.showPressureRetryAlert = true
                                self.pressureRetryResume = { cont.resume(returning: $0) }
                            }
                        }
                        if !userWantsRetry {
                            recordStepOutcome(stepId: step.id, outcome: "failed")
                            capturedPressureClosedMbar = closedPressureValue.map { $0 * 1000.0 }
                            capturedPressureOpenMbar = openPressureValue.map { $0 * 1000.0 }
                            break pressureRetryLoop
                        }
                        self.log("步骤4: 用户选择重新测试压力", level: .info)
                    }
                    if stepStatuses[step.id] == .failed, await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                    
                case "step_disable_diag": // 屏蔽系统气体自检：写入 12×0x00 后等待可配置秒数，再轮询 Gas status 直至等于 SOP 配置的期望值或超时
                    self.log("步骤: 屏蔽气体自检（Disable diag）", level: .info)
                    // 从 UserDefaults 读取期望的 Gas status 集合（支持单值或多值，如 "0,1"）
                    let expectedStatusesRaw = UserDefaults.standard.object(forKey: "production_test_disable_diag_expected_gas_status")
                    let expectedStatuses: [Int]
                    if let s = expectedStatusesRaw as? String {
                        let parsed = s.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " }).compactMap { Int($0) }.map { max(0, min(9, $0)) }
                        expectedStatuses = parsed.isEmpty ? [1] : parsed
                    } else if let i = expectedStatusesRaw as? Int {
                        expectedStatuses = [max(0, min(9, i))]
                    } else if let d = expectedStatusesRaw as? Double {
                        expectedStatuses = [max(0, min(9, Int(d)))]
                    } else {
                        expectedStatuses = [1]
                    }
                    let expectedDescription = expectedStatuses.map(String.init).joined(separator: ",")
                    let waitSecondsStr = String(format: "%.1f", rules.thresholds.disableDiagWaitSeconds)
                    let pollTimeoutStr = String(format: "%.1f", rules.thresholds.disableDiagPollTimeoutSeconds)

                    self.log("Disable diag 判定准则：向 CO2 Pressure Limits 写入 12×0x00 后，等待 \(waitSecondsStr) 秒，再在 \(pollTimeoutStr) 秒轮询内，Gas system status 必须变为期望值集合中的任意一个：\(expectedDescription)。", level: .info)
                    ble.writeCo2PressureLimitsZeros()
                    let waitSec = max(0, rules.thresholds.disableDiagWaitSeconds)
                    if waitSec > 0 {
                        self.log("等待 \(String(format: "%.1f", waitSec)) 秒…", level: .info)
                        try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
                    }
                    if rules.thresholds.disableDiagPollGasStatusEnabled {
                        let pollTimeout = max(0.1, rules.thresholds.disableDiagPollTimeoutSeconds)
                        let pollTimeoutStr = String(format: "%.1f", pollTimeout)
                        self.log("轮询 Gas system status 直至为集合中的任意一个值 [\(expectedDescription)]（超时 \(pollTimeoutStr)s）…", level: .info)
                        let pollStart = Date()
                        var gasReached = false
                        while isRunning, ble.isConnected, ble.areCharacteristicsReady, Date().timeIntervalSince(pollStart) < pollTimeout {
                            ble.readGasSystemStatus(silent: true)
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            let raw = ble.lastGasSystemStatusValue
                            let parsed: Int? = raw.split(separator: " ").first.flatMap { Int(String($0)) }
                            if let v = parsed, expectedStatuses.contains(v) {
                                gasReached = true
                                self.log("Gas system status 已满足期望集合 [\(expectedDescription)]: \(raw)", level: .info)
                                break
                            }
                        }
                        if gasReached {
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_disable_diag_criteria")
                            stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                        } else {
                            let elapsed = String(format: "%.1f", Date().timeIntervalSince(pollStart))
                            let pollTimeoutStr = String(format: "%.1f", pollTimeout)
                            self.log("错误：\(pollTimeoutStr)s 内 Gas system status 未进入期望集合 [\(expectedDescription)]（当前: \(ble.lastGasSystemStatusValue)）", level: .error)
                            stepResults[step.id] = String(format: appLanguage.string("production_test_rules.step_disable_diag_fail_timeout"), elapsed, expectedDescription)
                            stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                            if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        }
                    } else {
                        stepResults[step.id] = appLanguage.string("production_test_rules.step_disable_diag_criteria")
                        stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                    }
                    
                case "step_gas_system_status": // 读取 Gas system status，解码后须为 1 (ok)
                    self.log("步骤: 读取 Gas system status", level: .info)
                    ble.readGasSystemStatus()
                    let gasStatusTimeoutSeconds = rules.thresholds.deviceInfoReadTimeout
                    let maxGasStatusWaitCount = Int(gasStatusTimeoutSeconds * 10)
                    var gasStatusWaitCount = 0
                    while isRunning && (ble.lastGasSystemStatusValue.isEmpty || ble.lastGasSystemStatusValue == "--") && gasStatusWaitCount < maxGasStatusWaitCount {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        gasStatusWaitCount += 1
                        if gasStatusWaitCount % 20 == 0 {
                            let elapsed = Double(gasStatusWaitCount) / 10.0
                            self.log("等待 Gas system status 读取中...（已等待 \(String(format: "%.1f", elapsed))秒）", level: .debug)
                        }
                    }
                    let gasStatusStr = ble.lastGasSystemStatusValue
                    if gasStatusStr.isEmpty || gasStatusStr == "--" {
                        self.log("错误：Gas system status 读取超时或无效（\(Int(gasStatusTimeoutSeconds))秒）", level: .error)
                        stepResults[step.id] = appLanguage.string("production_test_rules.gas_status_read_timeout")
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    } else {
                        self.log("Gas system status 读取值: \(gasStatusStr)", level: .info)
                        // 解码：1 = ok 为通过，其余均为失败
                        let isOk = gasStatusStr.hasPrefix("1 (ok)")
                        if isOk {
                            self.log("✓ Gas system status 验证通过: \(gasStatusStr)", level: .info)
                            stepResults[step.id] = String(format: appLanguage.string("production_test_rules.gas_status_pass"), gasStatusStr)
                            stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                        } else {
                            self.log("Gas system status 检查失败: \(gasStatusStr)，期望 1 (ok)", level: .error)
                            stepResults[step.id] = String(format: appLanguage.string("production_test_rules.gas_status_fail_expected"), gasStatusStr)
                            stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                            if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        }
                        capturedGasSystemStatus = gasStatusStr.isEmpty || gasStatusStr == "--" ? nil : gasStatusStr
                    }
                    
                case "step_gas_leak_open": // 气体泄漏检测（开阀压力）
                    self.log("步骤: 气体泄漏检测（开阀压力）", level: .info)
                    let configOpen = loadProductionGasLeakConfig(keyPrefix: "production_test_gas_leak_open")
                    let resultOpen = await runProductionGasLeakStep(stepId: step.id, stepLabel: appLanguage.string("production_test_rules.step_gas_leak_open_title"), config: configOpen)
                    stepResults[step.id] = resultOpen.message
                    stepStatuses[step.id] = resultOpen.passed ? .passed : .failed
                    if stepStatuses[step.id] == .failed, await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                    
                case "step_gas_leak_closed": // 气体泄漏检测（关阀压力）
                    // 若启用了“开阀压力通过则跳过关阀压力步骤”，且开阀步骤启用并已通过，则跳过本步骤
                    if skipClosedWhenOpenPasses,
                       let openStep = currentTestSteps.first(where: { $0.id == TestStep.gasLeakOpen.id }),
                       openStep.enabled,
                       stepStatuses[TestStep.gasLeakOpen.id] == .passed {
                        self.log("步骤: 气体泄漏检测（关阀压力）已根据规则跳过（开阀压力检测已通过）", level: .info)
                        stepResults[step.id] = appLanguage.string("production_test.overlay_step_skipped_open_passed")
                        stepStatuses[step.id] = .skipped
                    recordStepOutcome(stepId: step.id, outcome: "skipped")
                    } else {
                        self.log("步骤: 气体泄漏检测（关阀压力）", level: .info)
                        let configClosed = loadProductionGasLeakConfig(keyPrefix: "production_test_gas_leak_closed")
                        let resultClosed = await runProductionGasLeakStep(stepId: step.id, stepLabel: appLanguage.string("production_test_rules.step_gas_leak_closed_title"), config: configClosed)
                        stepResults[step.id] = resultClosed.message
                        stepStatuses[step.id] = resultClosed.passed ? .passed : .failed
                        if stepStatuses[step.id] == .failed, await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                    }
                    
                case "step_valve": // 确保电磁阀是开启的
                    self.log("步骤: 确保电磁阀是开启的", level: .info)
                    let valveOpened = await ensureValveOpen()
                    if valveOpened {
                        stepResults[step.id] = appLanguage.string("production_test_rules.step_valve_criteria")
                        stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                        capturedValveState = ble.lastValveStateValue
                    } else {
                        self.log("电磁阀打开失败或超时", level: .error)
                        stepResults[step.id] = appLanguage.string("production_test.valve_open_fail")
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                    }
                    
                case "step_reset": // 重启设备（Testing 0x00000001）
                    self.log("步骤: 重启设备", level: .info)
                    let result = await ble.sendTestingRebootCommand()
                    switch result {
                    case .sent:
                        stepResults[step.id] = appLanguage.string("production_test_rules.step_reset_criteria")
                        stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                        _ = await reconnectAfterTestingReboot(rules: rules.thresholds)
                    case .timeout:
                        self.log("警告：重启命令已发送但未在约定时间内确认断开", level: .warning)
                        stepResults[step.id] = appLanguage.string("production_test_rules.step_reset_criteria") + appLanguage.string("production_test.step_factory_reset_not_confirmed")
                        stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                        _ = await reconnectAfterTestingReboot(rules: rules.thresholds)
                    case .rejectedByVersion:
                        self.log("固件版本不支持重启命令，步骤跳过", level: .warning)
                        stepResults[step.id] = appLanguage.string("production_test.overlay_step_skipped_version")
                        stepStatuses[step.id] = .skipped
                    recordStepOutcome(stepId: step.id, outcome: "skipped")
                    case .notReady:
                        stepResults[step.id] = appLanguage.string("production_test.reset_not_ready")
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                    }
                    
                case "step_factory_reset": // 恢复出厂（Testing 0x00000002）；重连若得到「Peer removed pairing」则判定恢复出厂成功
                    self.log("步骤: 恢复出厂设置", level: .info)
                    if rules.thresholds.skipFactoryResetAndDisconnectOnFail && hasAnyEnabledStepFailed(stepStatuses: stepStatuses, enabledSteps: enabledSteps, excluding: [TestStep.factoryReset.id, TestStep.disconnectDevice.id]) {
                        self.log(appLanguage.string("production_test.log_factory_reset_skipped_error"), level: .error)
                        stepResults[step.id] = appLanguage.string("production_test.skipped_test_failed")
                        stepStatuses[step.id] = .failed
                        recordStepOutcome(stepId: step.id, outcome: "failed")
                        break
                    }
                    let result = await ble.sendTestingFactoryResetCommand()
                    switch result {
                    case .sent:
                        stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                        let reconnectResult = await reconnectAfterTestingReboot(rules: rules.thresholds, expectPairingRemoved: true)
                        switch reconnectResult {
                        case .reconnected, .skipped:
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria")
                        case .timeout(pairingRemoved: true):
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_confirmed_pairing_removed")
                            stepResults[TestStep.disconnectDevice.id] = appLanguage.string("production_test.step_disconnect_after_factory_reset_ok")
                            stepStatuses[TestStep.disconnectDevice.id] = .passed
                            expandedSteps.remove(step.id)
                            currentStepId = nil
                            isRunning = false
                            updateTestResultStatus()
                            finishProductionTestRunWithReportAndUpload(enabledSteps: enabledSteps)
                            return
                        case .timeout(pairingRemoved: false):
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria")
                        }
                    case .timeout:
                        self.log("警告：恢复出厂命令已发送但未在约定时间内确认断开", level: .warning)
                        stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                        let reconnectResult = await reconnectAfterTestingReboot(rules: rules.thresholds, expectPairingRemoved: true)
                        switch reconnectResult {
                        case .reconnected, .skipped:
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria") + appLanguage.string("production_test.step_factory_reset_not_confirmed")
                        case .timeout(pairingRemoved: true):
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_confirmed_pairing_removed")
                            stepResults[TestStep.disconnectDevice.id] = appLanguage.string("production_test.step_disconnect_after_factory_reset_ok")
                            stepStatuses[TestStep.disconnectDevice.id] = .passed
                            expandedSteps.remove(step.id)
                            currentStepId = nil
                            isRunning = false
                            updateTestResultStatus()
                            finishProductionTestRunWithReportAndUpload(enabledSteps: enabledSteps)
                            return
                        case .timeout(pairingRemoved: false):
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria") + appLanguage.string("production_test.step_factory_reset_not_confirmed")
                        }
                    case .rejectedByVersion:
                        self.log("固件版本不支持恢复出厂命令，步骤跳过", level: .warning)
                        stepResults[step.id] = appLanguage.string("production_test.overlay_step_skipped_version")
                        stepStatuses[step.id] = .skipped
                    recordStepOutcome(stepId: step.id, outcome: "skipped")
                    case .notReady:
                        stepResults[step.id] = appLanguage.string("production_test.factory_reset_not_ready")
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                    }
                    
                case "step_ota": // 断开连接前 OTA（是否执行由 step_verify_firmware 的「若 FW 不匹配则触发 OTA」+ FW 比对结果决定；OTA 步骤始终在 SOP 中，无法由用户单独关闭）
                    self.log("步骤: 断开前 OTA", level: .info, category: "OTA")
                    // 若后续还有会触发 reboot 的步骤（恢复出厂/重启）且当前固件支持该命令，则 OTA 完成后不发送 reboot；否则 OTA 后发 reboot，报表提示需要重测
                    let otaIndex = enabledSteps.firstIndex(where: { $0.id == TestStep.otaBeforeDisconnect.id })
                    let hasRebootStepAfterOTA = otaIndex.map { idx in
                        enabledSteps[(idx + 1)...].contains { $0.id == TestStep.reset.id || $0.id == TestStep.factoryReset.id }
                    } ?? false
                    let currentFirmwareSupports = ble.currentFirmwareSupportsTestingRebootAndFactoryReset()
                    ble.shouldSkipRebootAfterOTA = hasRebootStepAfterOTA && currentFirmwareSupports
                    if hasRebootStepAfterOTA && currentFirmwareSupports {
                        self.log("后续将执行恢复出厂/重启，OTA 完成后将不发送 reboot", level: .info, category: "OTA")
                    } else if hasRebootStepAfterOTA && !currentFirmwareSupports && fwMismatchRequiresOTA {
                        self.log("当前固件不支持重启/恢复出厂，OTA 后将发送 reboot，报表将提示需要重测", level: .info, category: "OTA")
                    }
                    
                    if !fwMismatchRequiresOTA {
                        self.log("OTA 未触发（FW 已匹配或未使能「若 FW 不匹配则触发 OTA」）", level: .info, category: "OTA")
                        stepResults[step.id] = appLanguage.string("production_test.ota_not_triggered")
                        stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                        break
                    }
                    
                    // 产测按 SOP 期望版本，从服务器产线固件列表中按需下载目标固件
                    guard let targetFirmware = await productionFirmwareItem(for: rules.firmwareVersion) else {
                        self.log("错误：服务器未提供版本 \(rules.firmwareVersion) 的产线固件，请检查服务器固件列表或产线可见配置", level: .error, category: "OTA")
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = String(format: appLanguage.string("production_test.ota_server_no_firmware"), rules.firmwareVersion)
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    let otaURL: URL
                    do {
                        otaURL = try await firmwareManager.resolveLocalURL(for: targetFirmware, serverClient: serverClient)
                        ble.selectFirmware(url: otaURL, version: targetFirmware.version)
                    } catch {
                        self.log("错误：无法从服务器准备 OTA 固件 \(rules.firmwareVersion)：\(error.localizedDescription)", level: .error, category: "OTA")
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = String(format: appLanguage.string("production_test.ota_prepare_fail"), rules.firmwareVersion)
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    // 产测：由规则决定是否跳过（当前已是目标版本则跳过）；OTA 只接收 URL 执行，不做版本比对
                    if let currentFw = ble.currentFirmwareVersion, currentFw == rules.firmwareVersion {
                        self.log("固件版本已与期望一致（\(currentFw)），跳过 OTA", level: .info, category: "OTA")
                        stepResults[step.id] = String(format: appLanguage.string("production_test.ota_skipped_fw_ok"), currentFw)
                        stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                        break
                    }
                    
                    let valveOpened = await ensureValveOpen()
                    if !valveOpened {
                        self.log("警告：OTA 前阀门打开失败，继续执行 OTA...", level: .warning, category: "OTA")
                    }
                    
                    if ble.shouldSkipRebootAfterOTA {
                        self.log("OTA 启动前确认：完成后不发送 reboot（由后续恢复出厂/重启步骤触发）", level: .info, category: "OTA")
                    }
                    if hasRebootStepAfterOTA && !currentFirmwareSupports {
                        needRetestAfterOtaReboot = true
                    }
                    if needRetestAfterOtaReboot {
                        self.log("本次 OTA 将触发 reboot，OTA 完毕后将提示需要重测", level: .error, category: "OTA")
                    }
                    self.log("使用已选固件，启动 OTA", level: .info, category: "OTA")
                    if let reason = ble.startOTA(firmwareURL: otaURL, initiatedByProductionTest: true) {
                        self.log("错误：OTA 未启动（\(reason)）", level: .error, category: "OTA")
                        needRetestAfterOtaReboot = false
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = String(format: appLanguage.string("production_test.ota_reason"), reason)
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    
                    let otaTimeoutSeconds = rules.thresholds.otaStartWaitTimeout
                    let maxOtaWaitCount = Int(otaTimeoutSeconds * 2)
                    var otaWaitCount = 0
                    while !ble.isOTAInProgress && otaWaitCount < maxOtaWaitCount {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        otaWaitCount += 1
                        if otaWaitCount % 4 == 0 {
                            let elapsed = Double(otaWaitCount) / 2.0
                            self.log("等待 OTA 启动中...（已等待 \(String(format: "%.1f", elapsed))秒）", level: .debug, category: "OTA")
                        }
                    }
                    
                    if otaWaitCount >= maxOtaWaitCount {
                        self.log("错误：OTA 启动超时（\(Int(otaTimeoutSeconds))秒）", level: .error, category: "OTA")
                        needRetestAfterOtaReboot = false
                        if let reason = ble.lastOTARejectReason {
                            self.log("OTA 未启动原因: \(reason)", level: .error, category: "OTA")
                            stepResults[step.id] = String(format: appLanguage.string("production_test.ota_start_timeout_with"), reason)
                        } else {
                            stepResults[step.id] = appLanguage.string("production_test.ota_start_timeout")
                        }
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    
                    self.log("OTA 已启动，传输进行中...", level: .info, category: "OTA")
                    while ble.isOTAInProgress {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    
                    if ble.isOTAFailed || ble.isOTACancelled {
                        self.log("错误：OTA 失败或已取消", level: .error, category: "OTA")
                        needRetestAfterOtaReboot = false
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = appLanguage.string("production_test.ota_fail_or_cancelled")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    
                    if ble.otaProgress >= 1.0 && !ble.isOTAFailed {
                        self.log("OTA 传输完成", level: .info, category: "OTA")
                        stepResults[step.id] = appLanguage.string("production_test.ota_done")
                        stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                    } else {
                        self.log("错误：OTA 未完成", level: .error, category: "OTA")
                        needRetestAfterOtaReboot = false
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = appLanguage.string("production_test.ota_not_done")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    
                case "step5": // 待定
                    self.log("步骤5: 待定步骤（跳过）", level: .info)
                    stepStatuses[step.id] = .skipped
                    recordStepOutcome(stepId: step.id, outcome: "skipped")
                    
                case "step_disconnect": // 安全断开连接（阀门状态已在「确保电磁阀是开启的」步骤中确认，此处仅执行断开）
                    self.log("最后步骤: 安全断开连接", level: .info)
                    if rules.thresholds.skipFactoryResetAndDisconnectOnFail && hasAnyEnabledStepFailed(stepStatuses: stepStatuses, enabledSteps: enabledSteps, excluding: [TestStep.factoryReset.id, TestStep.disconnectDevice.id]) {
                        self.log(appLanguage.string("production_test.log_disconnect_skipped_error"), level: .error)
                        stepResults[step.id] = appLanguage.string("production_test.skipped_test_failed")
                        stepStatuses[step.id] = .failed
                        recordStepOutcome(stepId: step.id, outcome: "failed")
                        break
                    }
                    if ble.isOTARebootDisconnected {
                        // 设备已因 OTA 重启断开，断开步骤直接视为通过
                        self.log("设备已因 OTA 重启断开，断开步骤视为通过", level: .info)
                        stepResults[step.id] = appLanguage.string("production_test.disconnected_after_ota")
                        stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                    } else {
                        self.log("断开连接...", level: .info)
                        ble.disconnect()
                        try? await Task.sleep(nanoseconds: 1000_000_000)
                        self.log("已断开连接", level: .info)
                        stepResults[step.id] = appLanguage.string("production_test.disconnected")
                        stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                    }
                    
                default:
                    self.log("未知步骤: \(step.id)", level: .error)
                    stepResults[step.id] = appLanguage.string("production_test.step_unknown")
                    stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                    if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                }
                
                // 记录步骤结束时的日志索引
                let logEndIndex = testLog.count
                stepLogRanges[step.id] = (start: logStartIndex, end: logEndIndex)
                
                // 当前步骤结束：折叠该步骤并清除标记（主线程更新以便 UI 立即反映）
                await MainActor.run {
                    expandedSteps.remove(step.id)
                    currentStepId = nil
                }
                
                // 步骤间延时（SOP 定义，单位 ms）；步骤1 后可选：等待蓝牙权限/配对弹窗
                if step.id != enabledSteps.last?.id {
                    if step.id == TestStep.connectDevice.id && rules.thresholds.bluetoothPermissionWaitSeconds > 0 {
                        self.log("请处理蓝牙权限/配对弹窗（若出现请点击允许），完成后在弹窗中点击「继续」或按回车", level: .info)
                        showBluetoothPermissionConfirmation = true
                        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                            bluetoothPermissionContinuation = { cont.resume() }
                        }
                        showBluetoothPermissionConfirmation = false
                        bluetoothPermissionContinuation = nil
                    }
                    let intervalMs = rules.thresholds.stepIntervalMs
                    self.log("步骤完成，等待 \(intervalMs) ms 后继续下一步骤...", level: .debug)
                    try? await Task.sleep(nanoseconds: UInt64(max(0, intervalMs)) * 1_000_000)
                }
            }
            
        self.log("产测流程结束", level: .info)
        // 统一收尾：生成报表、按配置上传、设置结束时间与 overlay
        finishProductionTestRunWithReportAndUpload(enabledSteps: enabledSteps)
        isRunning = false
        if let id = currentStepId { expandedSteps.remove(id) }
        currentStepId = nil
        updateTestResultStatus()
    }
    
    /// 若「上传至服务器」已开启，将本次产测结果 POST 到服务器；body 由调用方通过 buildProductionTestPayload 提供
    private func uploadProductionTestResultIfNeeded(body: [String: Any]) async {
        guard serverSettings.uploadToServerEnabled else { return }
        let sn = (body["deviceSerialNumber"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sn.isEmpty else {
            self.log("上传跳过：无设备 SN（步骤2 未通过或未执行）", level: .warning)
            return
        }
        // 日志区只显示短文案 + 预览入口，点击后在弹窗中查看完整 payload，避免刷屏
        if let jsonData = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            self.logWithPayloadPreview(appLanguage.string("log.upload_payload_preview_line"), payloadJson: jsonString, level: .info)
        } else {
            self.log("上传产测记录 payload 构造完成（JSON 序列化失败，仅记录结构体）: \(body)", level: .warning)
        }

        let uploadDestination: String = {
            let base = serverSettings.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return base.isEmpty ? "(未配置)" : "\(base)\(ServerAPI.productionTest)"
        }()
        self.log("正在上传产测结果至服务器（后台）… \(uploadDestination)", level: .info)
        do {
            try await serverClient.uploadProductionTest(body: body)
            self.log("产测结果已上传至服务器（\(uploadDestination)）", level: .info)
        } catch let err as ServerClientError {
            switch err {
            case .serverError(let code, let retriable):
                if retriable {
                    self.log("上传失败：服务器返回 \(code)；结果已写入本地，下次启动将自动重传", level: .error)
                } else {
                    self.log("上传失败：服务器返回 \(code)（客户端错误），不重试；结果已写入本地", level: .error)
                }
                serverSettings.savePendingUpload(body: body)
            case .networkError(let e, let retriable):
                self.log("上传失败: \(e.localizedDescription)；结果已写入本地，下次启动将自动重传", level: .error)
                if retriable { serverSettings.savePendingUpload(body: body) }
            case .missingConfiguration, .encodingFailed:
                self.log("上传失败: \(err.localizedDescription)", level: .error)
            }
        } catch {
            self.log("上传失败: \(error.localizedDescription)；结果已写入本地，下次启动将自动重传", level: .error)
            serverSettings.savePendingUpload(body: body)
        }
    }
    
    /// 产测结束时的统一收尾：生成报表、按配置上传、设置结束时间与结果 overlay。正常结束与提前终止（用户停止、连接丢失、致命步骤失败）均调用此方法，保证每次产测都有报表并可上传。
    /// 幂等：若本次运行已收尾过（didFinishThisRun），直接 return，避免 onChange 与 run loop 重复调用导致上传两次。
    private func finishProductionTestRunWithReportAndUpload(enabledSteps: [TestStep]) {
        if didFinishThisRun { return }
        didFinishThisRun = true
        emitProductionTestReport(enabledSteps: enabledSteps)
        lastTestEndTime = Date()
        let body = buildProductionTestPayload(enabledSteps: enabledSteps)
        if let tid = currentTestId {
            saveProductionTestRecordToLocalFile(testId: tid, summary: body, journal: journalEntries)
        }
        if serverSettings.uploadToServerEnabled {
            Task { await uploadProductionTestResultIfNeeded(body: body) }
        }
        showResultOverlay = true
    }
    
    /// 产测结束时生成报表并写入日志区，按步骤结果使用不同 log 等级（通过=info、失败=error、跳过=warning）
    private func emitProductionTestReport(enabledSteps: [TestStep]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_POSIX")
        let timeStr = formatter.string(from: Date())
        
        self.log("", level: .info)
        self.log("", level: .info)
        self.log("────────── 产测报表 ──────────", level: .info)
        self.log("时间: \(timeStr)", level: .info)
        if needRetestAfterOtaReboot {
            self.log("需要重测（本次因当前固件不支持恢复出厂/重启而在 OTA 后发送了 reboot，请重测以执行后续步骤）", level: .warning)
        }
        self.log("步骤:", level: .info)
        for (index, step) in enabledSteps.enumerated() {
            let status = stepStatuses[step.id] ?? .pending
            let result = stepResults[step.id] ?? ""
            let title = appLanguage.string("production_test_rules.\(step.key)_title")
            let statusStr: String
            let stepLevel: LogLevel
            switch status {
            case .passed:
                statusStr = "✓"
                stepLevel = .info
            case .failed:
                statusStr = "✗"
                stepLevel = .error
            case .skipped:
                statusStr = "−"
                stepLevel = .warning
            case .pending, .running:
                statusStr = "?"
                stepLevel = .info
            }
            let oneLine = result.replacingOccurrences(of: "\n", with: " ")
            if oneLine.isEmpty {
                self.log("  \(index + 1). \(title) \(statusStr)", level: stepLevel)
            } else {
                self.log("  \(index + 1). \(title) \(statusStr) \(oneLine)", level: stepLevel)
            }
        }
        self.log("──────────────────────────────", level: .info)
        self.log("", level: .info)
        self.log("", level: .info)
    }
}

// MARK: - 产测结果 Overlay（极简报表：通过=绿，失败=红，仅警告通过=橙）
private struct ProductionTestResultOverlay: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    let passed: Bool
    let criteria: [(name: String, ok: Bool, isWarning: Bool, detail: String?)]
    let timeString: String
    let needRetest: Bool
    let onDismiss: () -> Void
    
    /// 需要重测时也按「测试失败」展示标题与主色，仅通过说明文案提示用户重测
    private var titleKey: String {
        if needRetest { return "production_test.result_overlay_title_fail" }
        return passed ? "production_test.result_overlay_title_pass" : "production_test.result_overlay_title_fail"
    }
    private var accentColor: Color {
        if needRetest { return Color(red: 0.75, green: 0.28, blue: 0.28) }
        return passed ? Color(red: 0.2, green: 0.45, blue: 0.78) : Color(red: 0.75, green: 0.28, blue: 0.28)
    }
    
    private func rowColor(ok: Bool, isWarning: Bool) -> Color {
        if !ok { return Color(red: 0.72, green: 0.3, blue: 0.3) }       // 红色（不深）
        if isWarning { return Color(red: 0.85, green: 0.65, blue: 0.35) } // 浅橙（图标/勾）
        return Color(red: 0.2, green: 0.45, blue: 0.78)               // 蓝色（通过）
    }
    
    /// 每行通过/失败/跳过的背景色：通过=蓝，失败=浅红，跳过=非常浅橙
    private func rowBackgroundColor(ok: Bool, isWarning: Bool) -> Color {
        if !ok { return Color(red: 0.96, green: 0.45, blue: 0.45) }     // 浅红
        if isWarning { return Color(red: 1.0, green: 0.95, blue: 0.88) } // 非常浅橙
        return Color(red: 0.35, green: 0.58, blue: 0.88)               // 蓝
    }
    
    /// Close 按钮：通过=蓝，失败/需要重测=浅红
    private var closeButtonColor: Color {
        if needRetest { return Color(red: 0.72, green: 0.28, blue: 0.28) }
        return passed ? Color(red: 0.18, green: 0.42, blue: 0.72) : Color(red: 0.72, green: 0.28, blue: 0.28)
    }
    
    var body: some View {
        ZStack {
            // 半透明遮罩：仅覆盖主功能区，不参与命中测试
            Color.black.opacity(0.3)
                .allowsHitTesting(false)
            
            GeometryReader { geo in
                let maxCardHeight = min(560, geo.size.height * 0.88)
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.lg) {
                        Text(appLanguage.string(titleKey))
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Color(NSColor.labelColor))
                        Text(timeString)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color(NSColor.secondaryLabelColor))
                        if needRetest {
                            Text(appLanguage.string("production_test.need_retest_detail"))
                                .font(.subheadline)
                                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(criteria.enumerated()), id: \.offset) { _, item in
                                    let color = rowColor(ok: item.ok, isWarning: item.isWarning)
                                    let bgColor = rowBackgroundColor(ok: item.ok, isWarning: item.isWarning)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .center, spacing: 8) {
                                            Text(item.ok ? "✓" : "✗")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(color)
                                            Text(item.name)
                                                .font(.subheadline)
                                                .foregroundStyle(Color(NSColor.labelColor))
                                            Spacer(minLength: 0)
                                        }
                                        if let detail = item.detail, !detail.isEmpty {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(bgColor)
                                    .cornerRadius(6)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(maxHeight: max(120, maxCardHeight - 160))
                        
                        HStack {
                            Spacer(minLength: 0)
                            Text(appLanguage.string("production_test.result_overlay_dismiss"))
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .frame(minWidth: 200)
                                .padding(.vertical, 10)
                                .background(closeButtonColor, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { onDismiss() }
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(UIDesignSystem.Padding.xl)
                    .frame(minWidth: 320, maxWidth: 440, maxHeight: maxCardHeight)
                    .background(Color(NSColor.windowBackgroundColor))
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.15), radius: 16, x: 0, y: 8)
                .allowsHitTesting(true)
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { onDismiss() }
    }
}

// MARK: - 连接后蓝牙权限/配对确认弹窗（用户点击「继续」或回车后产测继续）
private struct BluetoothPermissionConfirmSheet: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    var onContinue: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.lg) {
            Text(appLanguage.string("production_test.bluetooth_permission_confirm_title"))
                .font(.headline)
            Text(appLanguage.string("production_test.bluetooth_permission_confirm_message"))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(appLanguage.string("production_test.bluetooth_permission_continue")) {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: UIDesignSystem.Component.actionButtonWidth)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(UIDesignSystem.Padding.lg)
        .frame(minWidth: 360)
    }
}
