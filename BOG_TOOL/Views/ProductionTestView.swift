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

/// 产测气体泄漏检测步骤的配置（从 ProductionRules JSON 加载）
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
    /// Phase 4 开关与判定参数（仅对关阀步骤生效；对开阀步骤忽略）
    var phase4Enabled: Bool
    var phase4MonitorDurationSeconds: Int
    var phase4DropWithinSeconds: Int
    var phase4PressureBelowMbar: Double
}

/// 产测模式：连接后执行 开→关→开，并在开前/开后/关后各读一次压力
struct ProductionTestView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @EnvironmentObject private var serverSettings: ServerSettings
    @EnvironmentObject private var serverClient: ServerClient
    @EnvironmentObject private var productionState: ProductionTestState
    @EnvironmentObject private var productionRulesStore: ProductionRulesStore
    @EnvironmentObject private var auxValveSettings: AuxValveSettings
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
    /// 用户点击「开始产测」的时刻（用于上传 durationSeconds，含连接/GATT 等待）
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
    @State private var capturedGasLeakClosedDeltaMbar: Double?
    @State private var capturedGasLeakClosedDurationSeconds: Double?
    @State private var capturedGasLeakClosedPhase1AvgBar: Double?
    @State private var capturedGasLeakClosedThresholdMbar: Double?
    @State private var capturedGasLeakClosedLimitBar: Double?
    @State private var capturedGasLeakClosedRefBar: Double?
    @State private var capturedGasLeakClosedLimitSource: String?
    @State private var capturedGasLeakClosedPhase3FirstBar: Double?
    @State private var capturedGasLeakClosedUserActionSeconds: Double?
    @State private var capturedGasLeakClosedSamples: [[String: Any]]?
    /// 本轮产测是否真正执行过「气体泄漏检测（关阀压力）」步骤（不含被规则跳过的情况）
    @State private var didRunGasLeakClosedStep: Bool = false
    
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

    /// §4.9.3 WiFi 气阀编排失败：提醒切换人工 / 重试 / 关闭自动
    @State private var showAuxValveFailureAlert = false
    @State private var auxValveFailureTitle = ""
    @State private var auxValveFailureMessage = ""
    @State private var auxValveFailureResume: ((AuxValveFailureAlertChoice) -> Void)?

    /// 产测提示音：弹窗提示用户做动作时播放，提升可见性
    private func playProductionHintSound() {
        if let sound = NSSound(named: "Glass") {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    /// 清空气体泄漏（关阀压力）步骤的 captured 字段
    private func resetCapturedGasLeakValues() {
        capturedGasLeakClosedDeltaMbar = nil
        capturedGasLeakClosedDurationSeconds = nil
        capturedGasLeakClosedPhase1AvgBar = nil
        capturedGasLeakClosedThresholdMbar = nil
        capturedGasLeakClosedLimitBar = nil
        capturedGasLeakClosedRefBar = nil
        capturedGasLeakClosedLimitSource = nil
        capturedGasLeakClosedPhase3FirstBar = nil
        capturedGasLeakClosedUserActionSeconds = nil
        capturedGasLeakClosedSamples = nil

        // 标志位
        didRunGasLeakClosedStep = false
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
                Text(appLanguage.string("production_test.steps_list_sop_hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    log("[User] Bluetooth permission dialog: user chose Continue", level: .info)
                    bluetoothPermissionContinuation?()
                    bluetoothPermissionContinuation = nil
                    showBluetoothPermissionConfirmation = false
                }
            )
            .environmentObject(appLanguage)
        }
        .alert(gasLeakConfirmTitle, isPresented: $showGasLeakConfirmAlert) {
            Button(appLanguage.string("debug.gas_leak_confirm_action")) {
                log("[User] Gas leak confirm: user tapped Confirm (\(gasLeakConfirmTitle))", level: .info)
                gasLeakConfirmResume?(true)
                gasLeakConfirmResume = nil
                showGasLeakConfirmAlert = false
            }
            Button(appLanguage.string("debug.gas_leak_cancel_action"), role: .cancel) {
                log("[User] Gas leak confirm: user tapped Cancel (\(gasLeakConfirmTitle))", level: .info)
                gasLeakConfirmResume?(false)
                gasLeakConfirmResume = nil
                showGasLeakConfirmAlert = false
            }
        } message: {
            Text(gasLeakConfirmMessage)
        }
        .alert(auxValveFailureTitle, isPresented: $showAuxValveFailureAlert) {
            Button(appLanguage.string("aux_valve.alert_use_manual")) {
                auxValveFailureResume?(.useManualThisRun)
                auxValveFailureResume = nil
                showAuxValveFailureAlert = false
            }
            Button(appLanguage.string("aux_valve.alert_retry")) {
                auxValveFailureResume?(.retry)
                auxValveFailureResume = nil
                showAuxValveFailureAlert = false
            }
            Button(appLanguage.string("aux_valve.alert_disable"), role: .destructive) {
                auxValveFailureResume?(.disableAutomation)
                auxValveFailureResume = nil
                showAuxValveFailureAlert = false
            }
        } message: {
            Text(auxValveFailureMessage)
        }
        .alert(appLanguage.string("production_test.pressure_fail_retry_alert_title"), isPresented: $showPressureRetryAlert) {
            Button(appLanguage.string("production_test.pressure_fail_retry_retry_action")) {
                log("[User] Pressure retry dialog: user chose Retry", level: .info)
                pressureRetryResume?(true)
                pressureRetryResume = nil
                showPressureRetryAlert = false
            }
            Button(appLanguage.string("production_test.pressure_fail_retry_continue_action"), role: .cancel) {
                log("[User] Pressure retry dialog: user chose Continue", level: .info)
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
                    sopVersionDisplay: displayableSOPVersion,
                    rulesSchemaVersion: productionRulesStore.rules.schemaVersion,
                    bogToolVersionDisplay: bogToolVersionPayloadString,
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
        resetCapturedGasLeakValues()
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
    
    /// 更新测试步骤列表（严格从 JSON 读取）
    private func updateTestSteps() {
        guard let rules = try? loadTestRules() else { return }
        currentTestSteps = rules.steps
    }
    
    /// 测试步骤功能区：完整 SOP 顺序（含规则中未启用的步骤），序号与上报 `stepIndex` 一致。
    private var testStepsSection: some View {
        VStack(spacing: UIDesignSystem.Spacing.xs) {
            ForEach(Array(currentTestSteps.enumerated()), id: \.element.id) { index, step in
                stepRow(step: step, stepNumber: index + 1)
                    .id(step.id)
            }
        }
    }
    
    /// 步骤行 - 水平布局，对号在最右侧；规则中关闭的步骤弱化展示且不可展开详细日志。
    private func stepRow(step: TestStep, stepNumber: Int) -> some View {
        let disabledInRules = !step.enabled
        let status = stepStatuses[step.id] ?? .pending
        let isCurrent = !disabledInRules && currentStepId == step.id
        let result = stepResults[step.id] ?? ""
        let isExpanded = expandedSteps.contains(step.id)
        let captionWhenDisabledRules: String = {
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return appLanguage.string("production_test.step_disabled_in_rules")
        }()
        
        return VStack(alignment: .leading, spacing: 0) {
            // 主行：启用步骤可点击展开/折叠；规则中关闭仅展示说明
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                // 左侧：步骤编号圆圈
                ZStack {
                    Circle()
                        .fill(disabledInRules ? Color.gray.opacity(0.2) : status.color.opacity(0.2))
                        .frame(width: 28, height: 28)
                    
                    if !disabledInRules && status == .running {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Text("\(stepNumber)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(disabledInRules ? Color.secondary : status.color)
                    }
                }
                
                // 中间：步骤标题和结果信息
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(appLanguage.string("production_test_rules.\(step.key)_title"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(disabledInRules ? Color.secondary : Color.primary)
                        
                        if disabledInRules {
                            Image(systemName: "eye.slash.fill")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    if disabledInRules {
                        Text(captionWhenDisabledRules)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(3)
                    } else if !result.isEmpty {
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
                    if !disabledInRules && status == .running {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16)
                    }
                    
                    Image(systemName: disabledInRules ? "minus.circle.fill" : status.icon)
                        .foregroundStyle(disabledInRules ? Color.secondary.opacity(0.7) : status.color)
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .frame(minWidth: 40, alignment: .trailing)
            }
            .padding(.horizontal, UIDesignSystem.Padding.sm)
            .padding(.vertical, UIDesignSystem.Padding.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(disabledInRules ? 0.92 : 1)
            .onTapGesture {
                guard !disabledInRules else { return }
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
            
            if !disabledInRules && isExpanded {
                stepDetailView(step: step, status: status, result: result)
                    .padding(.leading, UIDesignSystem.Padding.md + 28 + UIDesignSystem.Spacing.md)
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
        guard let rules = try? loadTestRules() else { return }
        testRules = TestRules(
            enabledStepsCount: rules.steps.filter { $0.enabled }.count,
            firmwareVersion: rules.firmwareVersion,
            hardwareVersion: rules.hardwareVersion
        )
    }

    /// 启动前规则校验：严格 JSON，缺 step/缺 key 即禁止开始
    private func validateRequiredRulesBeforeStart() -> String? {
        do {
            _ = try loadTestRules()
            return nil
        } catch {
            return "SOP JSON 规则不完整：\(error.localizedDescription)"
        }
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
        let serialOk = !enabled.contains(where: { $0.id == TestStep.readSerialNumber.id }) || stepStatuses[TestStep.readSerialNumber.id] == .passed
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
        let hwRevOk = !enabled.contains(where: { $0.id == TestStep.verifyHardwareRevision.id }) || stepStatuses[TestStep.verifyHardwareRevision.id] == .passed
        let hwRevShipOk = !enabled.contains(where: { $0.id == TestStep.hwRevShippingRegion.id }) || stepStatuses[TestStep.hwRevShippingRegion.id] == .passed
        let pressureOk = !enabled.contains(where: { $0.id == TestStep.readPressure.id }) || stepStatuses[TestStep.readPressure.id] == .passed
        let disableDiagOk = stepOkForOverall(stepId: TestStep.disableDiag.id, enabled: enabled)
        let gasSystemStatusOk = !enabled.contains(where: { $0.id == TestStep.readGasSystemStatus.id }) || stepStatuses[TestStep.readGasSystemStatus.id] == .passed
        let gasLeakClosedOk = stepOkForOverall(stepId: TestStep.gasLeakClosed.id, enabled: enabled)
        let valveOk = !enabled.contains(where: { $0.id == TestStep.ensureValveOpen.id }) || stepStatuses[TestStep.ensureValveOpen.id] == .passed
        // 恢复出厂 / 重启：若步骤启用则必须真正执行通过，未执行（如版本不支持而跳过）则整体判失败
        let factoryResetOk = !enabled.contains(where: { $0.id == TestStep.factoryReset.id }) || stepStatuses[TestStep.factoryReset.id] == .passed
        let resetOk = !enabled.contains(where: { $0.id == TestStep.reset.id }) || stepStatuses[TestStep.reset.id] == .passed
        let disconnectOk = stepOkForOverall(stepId: TestStep.disconnectDevice.id, enabled: enabled)
        return connectOk && serialOk && rtcOk && fwOk && hwRevOk && hwRevShipOk && pressureOk && disableDiagOk && gasSystemStatusOk && gasLeakClosedOk && valveOk && factoryResetOk && resetOk && disconnectOk
    }
    
    /// 用于 overlay 报表的判定项列表：(名称, 是否通过, 是否仅警告通过, 测试数据备注)。禁用的步骤也保留，标记为警告并注明「测试跳过」。
    /// 注意：这里只组织展示用的数据结构，不改变任何真实判定逻辑。
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
        if enabled.contains(where: { $0.id == TestStep.readSerialNumber.id }) {
            list.append((appLanguage.string("production_test_rules.step_read_serial_number_title"), stepStatuses[TestStep.readSerialNumber.id] == .passed, false, detail(for: TestStep.readSerialNumber.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.readSerialNumber.id }) {
            list.append((appLanguage.string("production_test_rules.step_read_serial_number_title"), true, true, skippedDetail))
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
        // HW_REV
        if enabled.contains(where: { $0.id == TestStep.verifyHardwareRevision.id }) {
            list.append((appLanguage.string("production_test_rules.step_verify_hw_rev_title"), stepStatuses[TestStep.verifyHardwareRevision.id] == .passed, false, detail(for: TestStep.verifyHardwareRevision.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.verifyHardwareRevision.id }) {
            list.append((appLanguage.string("production_test_rules.step_verify_hw_rev_title"), true, true, skippedDetail))
        }
        if enabled.contains(where: { $0.id == TestStep.hwRevShippingRegion.id }) {
            list.append((appLanguage.string("production_test_rules.step_hw_rev_shipping_region_title"), stepStatuses[TestStep.hwRevShippingRegion.id] == .passed, false, detail(for: TestStep.hwRevShippingRegion.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.hwRevShippingRegion.id }) {
            list.append((appLanguage.string("production_test_rules.step_hw_rev_shipping_region_title"), true, true, skippedDetail))
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

    private enum StrictRulesError: LocalizedError {
        case missingItems([String])
        var errorDescription: String? {
            switch self {
            case .missingItems(let items):
                return items.joined(separator: "；")
            }
        }
    }

    private func requireStepConfig(_ stepMap: [String: ProductionRules.Step], _ stepId: String, _ issues: inout [String]) -> ProductionRules.Step.Config? {
        guard let cfg = stepMap[stepId]?.config else {
            issues.append("[JSON缺失] step=\(stepId) 不存在或无 config")
            return nil
        }
        return cfg
    }

    /// 加载测试规则配置：严格 JSON，不允许代码默认值。
    private func loadTestRules() throws -> (steps: [TestStep], bootloaderVersion: String, firmwareVersion: String, hardwareVersion: String, thresholds: TestThresholds, stepFatalOnFailure: [String: Bool]) {
        var rules = productionRulesStore.rules
        // App 升级后内置模板可能新增步骤 id；旧版持久化/导入的 JSON 缺步时，按 bundle 默认补齐并写回 store，避免产测无法启动
        let template = try ProductionRulesLoader.loadBundledDefaultRules()
        let templateIds = Set(template.steps.map(\.id))
        let declared = Set(rules.steps.map(\.id))
        // 内置模板增减步骤 id 时（补齐新步或移除废弃步），与用户持久化不一致则按模板合并并保存
        if templateIds != declared {
            rules = rules.mergedWithTemplate(template)
            productionRulesStore.apply(rules)
            ble.appendLog("[Rules] 已按内置模板同步步骤列表并保存（补齐缺失或移除废弃 id），当前 steps=\(rules.steps.count)", level: .info)
        }
        var issues: [String] = []

        // 首次加载时在日志区打印当前规则来源与版本，便于排查默认配置是否生效
        if testRules.enabledStepsCount == 0 {
            ble.appendLog("[Rules] Using production rules version=\(rules.rulesVersion), steps=\(rules.steps.count) (source: bundled default_production_rules.json or last applied JSON)", level: .info)
        }

        // 1. 构建步骤顺序与启用状态
        let baseSteps: [TestStep] = [
            .connectDevice,
            .readSerialNumber,
            .verifyFirmware,
            .verifyHardwareRevision,
            .hwRevShippingRegion,
            .readRTC,
            .readPressure,
            .disableDiag,
            .readGasSystemStatus,
            .gasLeakClosed,
            .ensureValveOpen,
            .reset,
            .factoryReset,
            .otaBeforeDisconnect,
            .disconnectDevice
        ]
        /// 旧版占位步骤 `step5`（待定）：仍可从旧 JSON 读出，但构建运行列表时会过滤掉，不参与产测。
        let knownStepMap = (baseSteps + [TestStep.tbd]).reduce(into: [String: TestStep]()) { $0[$1.id] = $1 }
        let declaredStepIds = Set(rules.steps.map(\.id))
        let requiredStepIds = Set(baseSteps.map(\.id))
        let allowedDeclaredIds = requiredStepIds.union([TestStep.tbd.id])
        let missingSteps = requiredStepIds.subtracting(declaredStepIds).sorted()
        let unknownSteps = declaredStepIds.subtracting(allowedDeclaredIds).sorted()
        if !missingSteps.isEmpty {
            issues.append("[JSON缺失] steps 缺少: \(missingSteps.joined(separator: ", "))")
        }
        if !unknownSteps.isEmpty {
            issues.append("[JSON非法] steps 包含未知 id: \(unknownSteps.joined(separator: ", "))")
        }
        if !issues.isEmpty {
            throw StrictRulesError.missingItems(issues)
        }
        let rulesById = Dictionary(uniqueKeysWithValues: rules.steps.map { ($0.id, $0) })
        let steps: [TestStep] = rules.steps
            .filter { $0.id != TestStep.tbd.id }
            .sorted(by: { $0.order < $1.order })
            .compactMap { stepRule in
            guard let base = knownStepMap[stepRule.id] else { return nil }
            return TestStep(id: base.id, key: base.key, isLocked: base.isLocked, enabled: stepRule.enabled)
        }
        // 严格模式下仍保持首尾固定要求
        guard steps.first?.id == TestStep.connectDevice.id else {
            issues.append("[JSON非法] 第一步必须是 \(TestStep.connectDevice.id)")
            throw StrictRulesError.missingItems(issues)
        }
        guard steps.last?.id == TestStep.disconnectDevice.id else {
            issues.append("[JSON非法] 最后一步必须是 \(TestStep.disconnectDevice.id)")
            throw StrictRulesError.missingItems(issues)
        }

        // 2. 从 step_verify_firmware 配置解析版本限制
        guard let verifyCfg = requireStepConfig(rulesById, TestStep.verifyFirmware.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        guard let bootloaderVersion = verifyCfg.allowedBootloaderVersions?.first, !bootloaderVersion.isEmpty else {
            issues.append("[JSON缺失] step_verify_firmware.allowed_bootloader_versions[0]")
            throw StrictRulesError.missingItems(issues)
        }
        guard let firmwareVersion = verifyCfg.allowedFirmwareVersions?.first, !firmwareVersion.isEmpty else {
            issues.append("[JSON缺失] step_verify_firmware.allowed_firmware_versions[0]")
            throw StrictRulesError.missingItems(issues)
        }
        guard let hardwareVersion = verifyCfg.allowedHardwareVersions?.first, !hardwareVersion.isEmpty else {
            issues.append("[JSON缺失] step_verify_firmware.allowed_hardware_versions[0]")
            throw StrictRulesError.missingItems(issues)
        }
        guard let verifyHwCfg = requireStepConfig(rulesById, TestStep.verifyHardwareRevision.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        // step_verify_hw_rev：仅读取 2A27；JSON 键 write_verify_poll_interval_ms 语义为读轮询间隔（兼容旧键名）
        guard let hwRevReadTimeoutSeconds = verifyHwCfg.readTimeoutSeconds else { issues.append("[JSON缺失] step_verify_hw_rev.read_timeout_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let hwRevReadPollIntervalMs = verifyHwCfg.writeVerifyPollIntervalMs else { issues.append("[JSON缺失] step_verify_hw_rev.write_verify_poll_interval_ms"); throw StrictRulesError.missingItems(issues) }

        guard let shipCfg = requireStepConfig(rulesById, TestStep.hwRevShippingRegion.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        let shipDestRaw = shipCfg.shippingDestination?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard shipDestRaw == "us" || shipDestRaw == "eu" else {
            issues.append("[JSON缺失或非法] step_hw_rev_shipping_region.shipping_destination（须为 us 或 eu）")
            throw StrictRulesError.missingItems(issues)
        }
        guard let shipUsRaw = shipCfg.shippingHwRevUs?.trimmingCharacters(in: .whitespacesAndNewlines), !shipUsRaw.isEmpty,
              BLEManager.normalizedProductHardwareRevision(shipUsRaw) != nil else {
            issues.append("[JSON缺失或非法] step_hw_rev_shipping_region.shipping_hw_rev_us（须为合法 P##V##R##）")
            throw StrictRulesError.missingItems(issues)
        }
        guard let shipEuRaw = shipCfg.shippingHwRevEu?.trimmingCharacters(in: .whitespacesAndNewlines), !shipEuRaw.isEmpty,
              BLEManager.normalizedProductHardwareRevision(shipEuRaw) != nil else {
            issues.append("[JSON缺失或非法] step_hw_rev_shipping_region.shipping_hw_rev_eu（须为合法 P##V##R##）")
            throw StrictRulesError.missingItems(issues)
        }
        guard let shipAutoWrite = shipCfg.autoWriteWhenMismatch else { issues.append("[JSON缺失] step_hw_rev_shipping_region.auto_write_when_mismatch"); throw StrictRulesError.missingItems(issues) }
        guard let shipReadTimeout = shipCfg.readTimeoutSeconds else { issues.append("[JSON缺失] step_hw_rev_shipping_region.read_timeout_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let shipWriteVerifyTimeout = shipCfg.writeVerifyTimeoutSeconds else { issues.append("[JSON缺失] step_hw_rev_shipping_region.write_verify_timeout_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let shipWritePollMs = shipCfg.writeVerifyPollIntervalMs else { issues.append("[JSON缺失] step_hw_rev_shipping_region.write_verify_poll_interval_ms"); throw StrictRulesError.missingItems(issues) }

        // 3. 全局阈值配置（部分来自 global，部分来自各步骤 config）
        // step_connect
        guard let connectCfg = requireStepConfig(rulesById, TestStep.connectDevice.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        guard let bluetoothPermissionWaitSeconds = connectCfg.bluetoothPermissionWaitSeconds else { issues.append("[JSON缺失] step_connect.bluetooth_permission_wait_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let deviceReconnectTimeout = connectCfg.deviceReconnectTimeoutSeconds else { issues.append("[JSON缺失] step_connect.device_reconnect_timeout_seconds"); throw StrictRulesError.missingItems(issues) }

        // step_read_rtc
        guard let rtcCfg = requireStepConfig(rulesById, TestStep.readRTC.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        guard let rtcPassThreshold = rtcCfg.passThresholdSeconds else { issues.append("[JSON缺失] step_read_rtc.pass_threshold_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let rtcFailThreshold = rtcCfg.failThresholdSeconds else { issues.append("[JSON缺失] step_read_rtc.fail_threshold_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let rtcWriteEnabled = rtcCfg.writeEnabled else { issues.append("[JSON缺失] step_read_rtc.write_enabled"); throw StrictRulesError.missingItems(issues) }
        guard let rtcWriteRetryCount = rtcCfg.writeRetryCount else { issues.append("[JSON缺失] step_read_rtc.write_retry_count"); throw StrictRulesError.missingItems(issues) }
        guard let rtcReadTimeout = rtcCfg.readTimeoutSeconds else { issues.append("[JSON缺失] step_read_rtc.read_timeout_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let serialCfg = requireStepConfig(rulesById, TestStep.readSerialNumber.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        guard let serialReadTimeoutSeconds = serialCfg.readTimeoutSeconds else { issues.append("[JSON缺失] step_read_serial_number.read_timeout_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let deviceInfoReadTimeout = verifyCfg.deviceInfoReadTimeoutSeconds else { issues.append("[JSON缺失] step_verify_firmware.device_info_read_timeout_seconds"); throw StrictRulesError.missingItems(issues) }

        // step_valve
        guard let valveCfg = requireStepConfig(rulesById, TestStep.ensureValveOpen.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        guard let valveOpenTimeout = valveCfg.openTimeoutSeconds else { issues.append("[JSON缺失] step_valve.open_timeout_seconds"); throw StrictRulesError.missingItems(issues) }

        // step_disable_diag
        guard let disableCfg = requireStepConfig(rulesById, TestStep.disableDiag.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        guard let disableDiagWaitSeconds = disableCfg.waitSeconds else { issues.append("[JSON缺失] step_disable_diag.wait_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let disableDiagExpectedGasStatuses = disableCfg.expectedGasStatusValues, !disableDiagExpectedGasStatuses.isEmpty else { issues.append("[JSON缺失] step_disable_diag.expected_gas_status_values"); throw StrictRulesError.missingItems(issues) }
        let disableDiagExpectedGasStatus = disableDiagExpectedGasStatuses[0]
        guard let disableDiagPollTimeoutSeconds = disableCfg.pollTimeoutSeconds else { issues.append("[JSON缺失] step_disable_diag.poll_timeout_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let disableDiagPollGasStatusEnabled = disableCfg.pollEnabled else { issues.append("[JSON缺失] step_disable_diag.poll_enabled"); throw StrictRulesError.missingItems(issues) }
        guard let disableDiagPollIntervalMs = disableCfg.pollIntervalMs else { issues.append("[JSON缺失] step_disable_diag.poll_interval_ms"); throw StrictRulesError.missingItems(issues) }
        guard let disableDiagValveCheckEnabled = disableCfg.valveCheckEnabled else { issues.append("[JSON缺失] step_disable_diag.valve_check_enabled"); throw StrictRulesError.missingItems(issues) }
        guard let disableDiagValveCheckSettleSeconds = disableCfg.valveCheckSettleSeconds else { issues.append("[JSON缺失] step_disable_diag.valve_check_settle_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let disableDiagValveCheckPressureReadDelaySeconds = disableCfg.valveCheckPressureReadDelaySeconds else { issues.append("[JSON缺失] step_disable_diag.valve_check_pressure_read_delay_seconds"); throw StrictRulesError.missingItems(issues) }

        // step_read_pressure
        guard let pressureCfg = requireStepConfig(rulesById, TestStep.readPressure.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        guard let pressureClosedMin = pressureCfg.closedMinMbar else { issues.append("[JSON缺失] step_read_pressure.closed_min_mbar"); throw StrictRulesError.missingItems(issues) }
        guard let pressureClosedMax = pressureCfg.closedMaxMbar else { issues.append("[JSON缺失] step_read_pressure.closed_max_mbar"); throw StrictRulesError.missingItems(issues) }
        guard let pressureOpenMin = pressureCfg.openMinMbar else { issues.append("[JSON缺失] step_read_pressure.open_min_mbar"); throw StrictRulesError.missingItems(issues) }
        guard let pressureOpenMax = pressureCfg.openMaxMbar else { issues.append("[JSON缺失] step_read_pressure.open_max_mbar"); throw StrictRulesError.missingItems(issues) }
        guard let pressureDiffCheckEnabled = pressureCfg.diffCheckEnabled else { issues.append("[JSON缺失] step_read_pressure.diff_check_enabled"); throw StrictRulesError.missingItems(issues) }
        guard let pressureDiffMin = pressureCfg.diffMinMbar else { issues.append("[JSON缺失] step_read_pressure.diff_min_mbar"); throw StrictRulesError.missingItems(issues) }
        guard let pressureDiffMax = pressureCfg.diffMaxMbar else { issues.append("[JSON缺失] step_read_pressure.diff_max_mbar"); throw StrictRulesError.missingItems(issues) }
        guard let pressureFailRetryConfirmEnabled = pressureCfg.failRetryConfirmEnabled else { issues.append("[JSON缺失] step_read_pressure.fail_retry_confirm_enabled"); throw StrictRulesError.missingItems(issues) }
        guard let pressureReadTimeoutSeconds = pressureCfg.pressureReadTimeoutSeconds else { issues.append("[JSON缺失] step_read_pressure.pressure_read_timeout_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let pressureReadPollIntervalMs = pressureCfg.pressureReadPollIntervalMs else { issues.append("[JSON缺失] step_read_pressure.pressure_read_poll_interval_ms"); throw StrictRulesError.missingItems(issues) }
        guard let pressureRetryReadTimeoutSeconds = pressureCfg.pressureRetryReadTimeoutSeconds else { issues.append("[JSON缺失] step_read_pressure.pressure_retry_read_timeout_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let pressureRetryReadPollIntervalMs = pressureCfg.pressureRetryReadPollIntervalMs else { issues.append("[JSON缺失] step_read_pressure.pressure_retry_read_poll_interval_ms"); throw StrictRulesError.missingItems(issues) }

        // firmware upgrade / fail 时跳过恢复出厂和断开
        guard let firmwareUpgradeEnabled = verifyCfg.firmwareUpgradeEnabled else { issues.append("[JSON缺失] step_verify_firmware.firmware_upgrade_enabled"); throw StrictRulesError.missingItems(issues) }
        guard let otaCfg = requireStepConfig(rulesById, TestStep.otaBeforeDisconnect.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        guard let otaStartWaitTimeout = otaCfg.otaStartWaitTimeoutSeconds else { issues.append("[JSON缺失] step_ota.ota_start_wait_timeout_seconds"); throw StrictRulesError.missingItems(issues) }
        guard let gasStatusCfg = requireStepConfig(rulesById, TestStep.readGasSystemStatus.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        guard let gasStatusExpectedValues = gasStatusCfg.expectedGasStatusValues, !gasStatusExpectedValues.isEmpty else { issues.append("[JSON缺失] step_gas_system_status.expected_gas_status_values"); throw StrictRulesError.missingItems(issues) }
        guard let _ = requireStepConfig(rulesById, TestStep.gasLeakClosed.id, &issues) else { throw StrictRulesError.missingItems(issues) }
        let skipFactoryResetAndDisconnectOnFail = rules.global.skipFactoryResetAndDisconnectOnFail

        let gasStatusClamped = gasStatusExpectedValues.map { max(0, min(9, $0)) }
        let disableDiagGasClamped = disableDiagExpectedGasStatuses.map { max(0, min(9, $0)) }
        let gasSystemStatusMerged = Array(Set(gasStatusClamped + disableDiagGasClamped)).sorted()
        let gasSystemStatusGasOnlySet = Set(gasStatusClamped)
        let gasSystemStatusMergedSet = Set(gasSystemStatusMerged)
        if gasSystemStatusMergedSet.isStrictSuperset(of: gasSystemStatusGasOnlySet) {
            ble.appendLog("[Rules] step_gas_system_status 允许集合已与 step_disable_diag.expected_gas_status_values 合并为 [\(gasSystemStatusMerged.map(String.init).joined(separator: ","))]", level: .debug)
        }

        let thresholds = TestThresholds(
            stepIntervalMs: rules.global.stepIntervalMs,
            bluetoothPermissionWaitSeconds: bluetoothPermissionWaitSeconds,
            rtcPassThreshold: rtcPassThreshold,
            rtcFailThreshold: rtcFailThreshold,
            rtcWriteEnabled: rtcWriteEnabled,
            rtcWriteRetryCount: rtcWriteRetryCount,
            rtcReadTimeout: rtcReadTimeout,
            deviceInfoReadTimeout: deviceInfoReadTimeout,
            serialReadTimeoutSeconds: serialReadTimeoutSeconds,
            otaStartWaitTimeout: otaStartWaitTimeout,
            deviceReconnectTimeout: deviceReconnectTimeout,
            valveOpenTimeout: valveOpenTimeout,
            disableDiagWaitSeconds: disableDiagWaitSeconds,
            disableDiagExpectedGasStatus: disableDiagExpectedGasStatus,
            disableDiagPollTimeoutSeconds: disableDiagPollTimeoutSeconds,
            disableDiagPollGasStatusEnabled: disableDiagPollGasStatusEnabled,
            pressureClosedMin: pressureClosedMin,
            pressureClosedMax: pressureClosedMax,
            pressureOpenMin: pressureOpenMin,
            pressureOpenMax: pressureOpenMax,
            pressureDiffCheckEnabled: pressureDiffCheckEnabled,
            pressureDiffMin: pressureDiffMin,
            pressureDiffMax: pressureDiffMax,
            firmwareUpgradeEnabled: firmwareUpgradeEnabled,
            hwRevReadTimeoutSeconds: hwRevReadTimeoutSeconds,
            hwRevReadPollIntervalMs: hwRevReadPollIntervalMs,
            shippingDestination: shipDestRaw,
            shippingHwRevUs: BLEManager.normalizedProductHardwareRevision(shipUsRaw)!,
            shippingHwRevEu: BLEManager.normalizedProductHardwareRevision(shipEuRaw)!,
            shippingHwRevAutoWriteWhenMismatch: shipAutoWrite,
            shippingHwRevReadTimeoutSeconds: shipReadTimeout,
            shippingHwRevWriteVerifyTimeoutSeconds: shipWriteVerifyTimeout,
            shippingHwRevWriteVerifyPollIntervalMs: shipWritePollMs,
            skipFactoryResetAndDisconnectOnFail: skipFactoryResetAndDisconnectOnFail,
            pressureFailRetryConfirmEnabled: pressureFailRetryConfirmEnabled,
            disableDiagPollIntervalMs: disableDiagPollIntervalMs,
            disableDiagValveCheckEnabled: disableDiagValveCheckEnabled,
            disableDiagValveCheckSettleSeconds: disableDiagValveCheckSettleSeconds,
            disableDiagValveCheckPressureReadDelaySeconds: disableDiagValveCheckPressureReadDelaySeconds,
            disableDiagExpectedGasStatuses: disableDiagExpectedGasStatuses.map { max(0, min(9, $0)) },
            pressureReadTimeoutSeconds: pressureReadTimeoutSeconds,
            pressureReadPollIntervalMs: pressureReadPollIntervalMs,
            pressureRetryReadTimeoutSeconds: pressureRetryReadTimeoutSeconds,
            pressureRetryReadPollIntervalMs: pressureRetryReadPollIntervalMs,
            gasSystemStatusExpectedValues: gasSystemStatusMerged
        )

        // 4. 每步「失败时是否终止产测」：优先 step.fatalOnFailure，否则沿用 global.failurePolicy
        var stepFatalOnFailure: [String: Bool] = [:]
        let fatalDefault = Set(rules.global.failurePolicy.fatalDefault)
        let overrides = rules.global.failurePolicy.overrides
        for stepRule in rules.steps {
            let id = stepRule.id
            if let v = stepRule.fatalOnFailure {
                stepFatalOnFailure[id] = v
            } else if let override = overrides[id] {
                stepFatalOnFailure[id] = override
            } else {
                stepFatalOnFailure[id] = fatalDefault.contains(id)
            }
        }

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
        let serialReadTimeoutSeconds: Double   // step_read_serial_number：读序列号超时（秒）
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
        let hwRevReadTimeoutSeconds: Double   // step_verify_hw_rev：读取 2A27 超时（秒）
        let hwRevReadPollIntervalMs: Int      // step_verify_hw_rev：读轮询间隔（毫秒）；JSON 键仍为 write_verify_poll_interval_ms
        let shippingDestination: String            // step_hw_rev_shipping_region：us | eu
        let shippingHwRevUs: String                 // 美国出货 HW_REV（规范化为 P##V##R##）
        let shippingHwRevEu: String                 // 欧洲出货 HW_REV
        let shippingHwRevAutoWriteWhenMismatch: Bool
        let shippingHwRevReadTimeoutSeconds: Double
        let shippingHwRevWriteVerifyTimeoutSeconds: Double
        let shippingHwRevWriteVerifyPollIntervalMs: Int
        let skipFactoryResetAndDisconnectOnFail: Bool  // 测试失败时是否跳过恢复出厂与安全断开（默认 false）
        let pressureFailRetryConfirmEnabled: Bool    // 压力读取失败时是否弹窗确认重测（默认 true）
        let disableDiagPollIntervalMs: Int
        let disableDiagValveCheckEnabled: Bool
        let disableDiagValveCheckSettleSeconds: Double
        let disableDiagValveCheckPressureReadDelaySeconds: Double
        let disableDiagExpectedGasStatuses: [Int]
        let pressureReadTimeoutSeconds: Double
        let pressureReadPollIntervalMs: Int
        let pressureRetryReadTimeoutSeconds: Double
        let pressureRetryReadPollIntervalMs: Int
        let gasSystemStatusExpectedValues: [Int]
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

    /// §4.7 / §4.10.3：读压前 WiFi open；成功跳过 `pressure_pipeline_ready_*`；失败 §4.9 Alert 后仍须人工确认
    private func tryOpenLineValveViaWiFiBeforePressureStep() async -> Bool {
        guard AuxValveProductionBridge.shouldAttemptWifi(settings: auxValveSettings) else {
            return false
        }
        self.log("步骤4: 尝试 WiFi 打开产线入口阀 (device_id=\(auxValveSettings.normalizedTargetDeviceId))…", level: .info)
        let coordinator = AuxValveCoordinator(settings: auxValveSettings)
        let result = await AuxValveProductionBridge.ensureLineValveOpen(
            settings: auxValveSettings,
            coordinator: coordinator,
            presentFailureAlert: presentAuxValveFailureAlert
        )
        switch result {
        case .wifiSucceeded:
            self.log("步骤4: WiFi 产线入口阀已开，跳过气路确认弹窗", level: .info)
            return true
        case .useManualConfirm:
            return false
        case .wifiFailedUseManualConfirm(let reason):
            self.log("步骤4: WiFi 开阀未成功 (\(reason))，改用手动气路确认", level: .warning)
            return false
        }
    }

    private func presentAuxValveFailureAlert(reason: String, elapsedSec: TimeInterval) async -> AuxValveFailureAlertChoice {
        let displayReason = AuxValveUserMessage.localize(reason, language: appLanguage)
        return await withCheckedContinuation { (cont: CheckedContinuation<AuxValveFailureAlertChoice, Never>) in
            DispatchQueue.main.async {
                self.auxValveFailureTitle = self.appLanguage.string("aux_valve.alert_failure_title")
                self.auxValveFailureMessage = String(
                    format: self.appLanguage.string("aux_valve.alert_failure_message"),
                    displayReason,
                    elapsedSec
                )
                self.auxValveFailureResume = { cont.resume(returning: $0) }
                self.showAuxValveFailureAlert = true
                self.playProductionHintSound()
            }
        }
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

    /// 与 `buildProductionTestPayload` 中 `bogToolVersion` 字段一致（上报与本地产测 JSON 共用）。
    private var bogToolVersionPayloadString: String? {
        let shortVer = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let buildVer = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !shortVer.isEmpty else { return nil }
        return buildVer.isEmpty ? shortVer : "\(shortVer) (\(buildVer))"
    }

    /// 出货区写入 HW_REV 后上报变更（需已读到 SN）；失败落盘待重传。
    private func reportHardwareRevisionChangeToServer(
        previousHardwareRevision: String?,
        newHardwareRevision: String,
        changeSuccess: Bool,
        failureReason: String?
    ) {
        guard serverSettings.uploadToServerEnabled, let client = serverSettings.serverClient else { return }
        let sn = (capturedDeviceSN ?? ble.deviceSerialNumber)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sn.isEmpty else { return }

        let newTrim = newHardwareRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTrim.isEmpty else { return }
        let newNorm = BLEManager.normalizedProductHardwareRevision(newTrim) ?? newTrim
        let prevNorm: String? = {
            guard let p = previousHardwareRevision?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
            return BLEManager.normalizedProductHardwareRevision(p) ?? p
        }()

        if changeSuccess, prevNorm == newNorm { return }

        var body: [String: Any] = [
            "deviceSerialNumber": sn,
            "newHardwareRevision": newNorm,
            "changeSuccess": changeSuccess,
            "source": "fqc",
        ]
        if let pv = prevNorm { body["previousHardwareRevision"] = pv }
        if let fr = failureReason?.trimmingCharacters(in: .whitespacesAndNewlines), !fr.isEmpty {
            body["failureReason"] = fr
        }
        if let bog = bogToolVersionPayloadString {
            body["bogToolVersion"] = bog
        }

        Task {
            do {
                try await client.uploadHardwareRevisionChangeRecord(body: body)
            } catch {
                serverSettings.savePendingHardwareRevisionChange(body: body)
            }
        }
    }

    /// 日志/弹窗中与 payload `productionRulesVersion` 对齐的展示字符串。
    private var displayableSOPVersion: String {
        let v = productionRulesStore.rules.rulesVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? "N.A" : v
    }

    /// 构建与 API 一致的产测 payload（summary），供本地写入与上传共用。
    /// `stepsSummary` / 合并后的 `stepResults` 覆盖 **完整 SOP 顺序**（`currentTestSteps`），含规则中关闭的步骤。
    private func buildProductionTestPayload() -> [String: Any] {
        let roundTo3: (Double) -> Double = { Self.roundDoubleForJSON($0) }
        let sn = (capturedDeviceSN ?? ble.deviceSerialNumber)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endTime = lastTestEndTime ?? Date()
        let startTime = lastTestStartTime ?? endTime
        let durationSeconds = roundTo3(endTime.timeIntervalSince(startTime))
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startTimeStr = isoFormatter.string(from: startTime)
        let endTimeStr = isoFormatter.string(from: endTime)
        let sopSteps = currentTestSteps
        var executionOrdinalCounter = 0
        let stepsSummary: [[String: Any]] = sopSteps.enumerated().map { index, step in
            let status: String
            if !step.enabled {
                status = "skipped"
            } else {
                switch stepStatuses[step.id] ?? .pending {
                case .passed: status = "passed"
                case .failed: status = "failed"
                case .skipped: status = "skipped"
                case .pending, .running: status = "pending"
                }
            }
            let stepName = appLanguage.string("production_test_rules.\(step.key)_title")
            var row: [String: Any] = [
                "stepIndex": index + 1,
                "stepName": stepName,
                "stepId": step.id,
                "status": status,
            ]
            if step.enabled {
                executionOrdinalCounter += 1
                row["executionOrdinal"] = executionOrdinalCounter
            }
            return row
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
        var mergedStepResults = stepResults
        let disabledHint = appLanguage.string("production_test.step_disabled_in_rules")
        for step in sopSteps where !step.enabled {
            if mergedStepResults[step.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                mergedStepResults[step.id] = disabledHint
            }
        }
        if !mergedStepResults.isEmpty { body["stepResults"] = mergedStepResults }
        var testDetails: [String: Any] = [:]
        if let v = capturedRtcDeviceTime { testDetails["rtcDeviceTime"] = v }
        if let v = capturedRtcSystemTime { testDetails["rtcSystemTime"] = v }
        if let v = capturedRtcTimeDiffSeconds { testDetails["rtcTimeDiffSeconds"] = roundTo3(v) }
        if let v = capturedPressureClosedMbar { testDetails["pressureClosedMbar"] = roundTo3(v) }
        if let v = capturedPressureOpenMbar { testDetails["pressureOpenMbar"] = roundTo3(v) }
        if let v = capturedGasSystemStatus { testDetails["gasSystemStatus"] = v }
        if let v = capturedValveState { testDetails["valveState"] = v }
        if didRunGasLeakClosedStep {
            if let v = capturedGasLeakClosedDeltaMbar { testDetails["gasLeakClosedDeltaMbar"] = roundTo3(v) }
            if let v = capturedGasLeakClosedDurationSeconds { testDetails["gasLeakClosedDurationSeconds"] = roundTo3(v) }
            if let v = capturedGasLeakClosedPhase1AvgBar { testDetails["gasLeakClosedPhase1AvgBar"] = roundTo3(v) }
            if let v = capturedGasLeakClosedThresholdMbar { testDetails["gasLeakClosedThresholdMbar"] = roundTo3(v) }
            if let v = capturedGasLeakClosedLimitBar { testDetails["gasLeakClosedLimitBar"] = roundTo3(v) }
            if let v = capturedGasLeakClosedRefBar { testDetails["gasLeakClosedRefBar"] = roundTo3(v) }
            if let v = capturedGasLeakClosedLimitSource { testDetails["gasLeakClosedLimitSource"] = v }
            if let v = capturedGasLeakClosedPhase3FirstBar { testDetails["gasLeakClosedPhase3FirstBar"] = roundTo3(v) }
            if let v = capturedGasLeakClosedUserActionSeconds { testDetails["gasLeakClosedUserActionSeconds"] = roundTo3(v) }
            if let v = capturedGasLeakClosedSamples { testDetails["gasLeakClosedSamples"] = v }
        }
        if !testDetails.isEmpty { body["testDetails"] = testDetails }
        let rulesMeta = productionRulesStore.rules
        body["productionRulesVersion"] = rulesMeta.rulesVersion
        body["productionRulesSchemaVersion"] = rulesMeta.schemaVersion
        if let bog = bogToolVersionPayloadString {
            body["bogToolVersion"] = bog
        }
        if let runId = currentTestId {
            body["clientRunId"] = runId
        }
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
        let isFatal = stepFatalOnFailure[step.id] ?? false
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
        guard let rules = try? loadTestRules() else { return false }
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
        guard let rules = try? loadTestRules() else { return false }
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
        let deadline = Date().addingTimeInterval(max(0.1, valveTimeout))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            ble.readValveState()
            try? await Task.sleep(nanoseconds: 50_000_000)
            if ble.lastValveStateValue == targetState {
                self.log("电磁阀已切换为\(targetState)", level: .info)
                return true
            }
        }
        self.log("错误：电磁阀未能切换为\(targetState)（超时 \(String(format: "%.1f", valveTimeout))s）", level: .error)
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
    
    /// Disable diag 步骤专用：禁用自检后执行阀门开/关检查，并各自读取压力供观察；任何一次确认失败则返回 false。
    /// 阀门状态：发令后按 SOP `valve_open_timeout` 轮询读 valveState，直到 open/closed 或超时（同 `ensureValveState`）。
    private func runDisableDiagValveCheck(settleSeconds: Double, pressureReadDelaySeconds: Double) async -> Bool {
        // 前置状态检查
        guard isRunning, ble.isConnected, ble.areCharacteristicsReady else {
            log("Disable diag: 连接或 GATT 状态异常，无法执行阀门检查", level: .error)
            return false
        }
        
        // 1. 打开阀门并轮询确认（最多 valve_open_timeout 秒）
        log("Disable diag: 打开阀门以检查气路...", level: .info)
        guard await ensureValveState(open: true) else {
            log("Disable diag: 阀门打开后状态异常 (当前: \(ble.lastValveStateValue))", level: .error)
            return false
        }
        log("Disable diag: 阀门已打开 (state=open)", level: .info)
        // 开阀稳定后再读压（仅记录，不参与判定）
        try? await Task.sleep(nanoseconds: UInt64(max(0, settleSeconds) * 1_000_000_000))
        ble.readPressure(silent: true)
        ble.readPressureOpen(silent: true)
        try? await Task.sleep(nanoseconds: UInt64(max(0, pressureReadDelaySeconds) * 1_000_000_000))
        let openClosedBar = Self.parseBarFromPressureString(ble.lastPressureValue)
        let openOpenBar = Self.parseBarFromPressureString(ble.lastPressureOpenValue)
        let openClosedStr = openClosedBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
        let openOpenStr = openOpenBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
        log("Disable diag: 打开阀门后压力（关阀通道=\(openClosedStr)，开阀通道=\(openOpenStr)）[仅供观察，不参与判定]", level: .info)
        
        // 2. 关闭阀门并轮询确认
        log("Disable diag: 关闭阀门以检查气路...", level: .info)
        guard await ensureValveState(open: false) else {
            log("Disable diag: 阀门关闭后状态异常 (当前: \(ble.lastValveStateValue))", level: .error)
            return false
        }
        log("Disable diag: 阀门已关闭 (state=closed)", level: .info)
        try? await Task.sleep(nanoseconds: UInt64(max(0, settleSeconds) * 1_000_000_000))
        ble.readPressure(silent: true)
        ble.readPressureOpen(silent: true)
        try? await Task.sleep(nanoseconds: UInt64(max(0, pressureReadDelaySeconds) * 1_000_000_000))
        let closeClosedBar = Self.parseBarFromPressureString(ble.lastPressureValue)
        let closeOpenBar = Self.parseBarFromPressureString(ble.lastPressureOpenValue)
        let closeClosedStr = closeClosedBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
        let closeOpenStr = closeOpenBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
        log("Disable diag: 关闭阀门后压力（关阀通道=\(closeClosedStr)，开阀通道=\(closeOpenStr)）[仅供观察，不参与判定]", level: .info)
        
        return true
    }
    
    /// 从 ProductionRules(JSON) 加载「关阀压力」气体泄漏步骤配置（严格模式：缺键即抛错）
    private func loadProductionGasLeakConfig() throws -> ProductionGasLeakConfig {
        let rules = productionRulesStore.rules
        let targetId = TestStep.gasLeakClosed.id
        guard let cfg = rules.steps.first(where: { $0.id == targetId })?.config else {
            throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).config"])
        }
        guard let limitSourceRaw = cfg.limitSource else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).limit_source"]) }
        let limitSource = limitSourceRaw == kGasLeakLimitSourcePhase3First ? kGasLeakLimitSourcePhase3First : kGasLeakLimitSourcePhase1Avg
        guard let rawFloor = cfg.limitFloorBar else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).limit_floor_bar"]) }
        let limitFloorBar = max(0, rawFloor)
        guard let preCloseDurationSeconds = cfg.preCloseDurationSeconds else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).pre_close_duration_seconds"]) }
        guard let postCloseDurationSeconds = cfg.postCloseDurationSeconds else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).post_close_duration_seconds"]) }
        guard let intervalSeconds = cfg.intervalSeconds else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).interval_seconds"]) }
        guard let dropThresholdMbar = cfg.dropThresholdMbar else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).drop_threshold_mbar"]) }
        guard let startPressureMinMbar = cfg.startPressureMinMbar else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).start_pressure_min_mbar"]) }
        guard let requirePipelineReadyConfirm = cfg.requirePipelineReadyConfirm else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).require_pipeline_ready_confirm"]) }
        guard let requireValveClosedConfirm = cfg.requireValveClosedConfirm else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).require_valve_closed_confirm"]) }
        guard let phase4Enabled = cfg.phase4Enabled else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).phase4_enabled"]) }
        guard let phase4MonitorDurationSeconds = cfg.phase4MonitorDurationSeconds else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).phase4_monitor_duration_seconds"]) }
        guard let phase4DropWithinSeconds = cfg.phase4DropWithinSeconds else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).phase4_drop_within_seconds"]) }
        guard let phase4PressureBelowMbar = cfg.phase4PressureBelowMbar else { throw StrictRulesError.missingItems(["[JSON缺失] \(targetId).phase4_pressure_below_mbar"]) }
        return ProductionGasLeakConfig(
            preCloseDurationSeconds: preCloseDurationSeconds,
            postCloseDurationSeconds: postCloseDurationSeconds,
            intervalSeconds: intervalSeconds,
            dropThresholdMbar: dropThresholdMbar,
            startPressureMinMbar: startPressureMinMbar,
            requirePipelineReadyConfirm: requirePipelineReadyConfirm,
            requireValveClosedConfirm: requireValveClosedConfirm,
            limitSource: limitSource,
            limitFloorBar: limitFloorBar,
            phase4Enabled: phase4Enabled,
            phase4MonitorDurationSeconds: phase4MonitorDurationSeconds,
            phase4DropWithinSeconds: phase4DropWithinSeconds,
            phase4PressureBelowMbar: phase4PressureBelowMbar
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

        let preDur = max(0, config.preCloseDurationSeconds)
        let postDur = max(0, config.postCloseDurationSeconds)
        let interval = max(0.1, min(3.0, config.intervalSeconds))
        let thresholdMbar = max(0, config.dropThresholdMbar)
        
        self.log(
            "\(stepLabel)：判定压力=关阀，Phase 1=\(preDur)s，Phase 3=\(postDur)s，间隔=\(String(format: "%.2f", interval))s，阈值=\(String(format: "%.1f", thresholdMbar)) mbar，limitSource=\(config.limitSource)，floor=\(String(format: "%.0f", config.limitFloorBar * 1000)) mbar",
            level: .info
        )
        
        // 1. 阀门预置：关阀压力判定
        let valveOk = await ensureValveState(open: false)
        guard valveOk else {
            return (false, "电磁阀未能切换到判定压力对应状态")
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        ble.readPressure(silent: true)
        ble.readPressureOpen(silent: true)
        ble.readValveState()
        try? await Task.sleep(nanoseconds: 700_000_000)
        
        // 2. Phase 1 前气路确认（可选）；WiFi 自动模式或规则关闭时跳过
        let skipPhase1PipelineConfirm = !config.requirePipelineReadyConfirm || auxValveSettings.canUseAuxValveAutomation
        if skipPhase1PipelineConfirm {
            let skipNote = auxValveSettings.canUseAuxValveAutomation
                ? "（WiFi 自动气阀）"
                : ""
            self.log("\(stepLabel)：\(appLanguage.string("production_test.gas_leak_phase1_confirm_skipped"))\(skipNote)", level: .info)
        }
        if config.requirePipelineReadyConfirm && !skipPhase1PipelineConfirm {
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

        let phase1Keepalive = AuxValveProductionBridge.startPhase1Keepalive(settings: auxValveSettings)
        defer { phase1Keepalive?.cancel() }
        
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
        // 为后续判定流程缓存 Phase 1 平均值，避免多次独立计算导致日志与判定存在细微数值差异
        var cachedPhase1Avg: Double?

        /// 在截止时刻前完成 BLE 读与等待，避免固定 600ms 叠在 interval 上导致 Phase 超出配置时长。
        func readGasLeakSensorsAndWait(bleDeadline: Date) async -> (closeStr: String, openStr: String, valveStr: String, gasStr: String) {
            ble.readPressure(silent: true)
            ble.readPressureOpen(silent: true)
            ble.readValveState()
            ble.readGasSystemStatus(silent: true)
            let settle = GasLeakPhaseTiming.bleSettleSeconds(until: bleDeadline)
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            var closeStr = ble.lastPressureValue
            var openStr = ble.lastPressureOpenValue
            if closeStr.hasPrefix("Error") || closeStr == "0 mbar" || openStr.hasPrefix("Error") || openStr == "0 mbar" {
                if GasLeakPhaseTiming.canRetry(until: bleDeadline) {
                    ble.readPressure(silent: true)
                    ble.readPressureOpen(silent: true)
                    let retrySettle = min(GasLeakPhaseTiming.retryExtra, GasLeakPhaseTiming.bleSettleSeconds(until: bleDeadline))
                    if retrySettle > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(retrySettle * 1_000_000_000))
                    }
                    closeStr = ble.lastPressureValue
                    openStr = ble.lastPressureOpenValue
                }
            }
            return (closeStr, openStr, ble.lastValveStateValue, ble.lastGasSystemStatusValue)
        }
        // 关阀压力通道
        func value(for p: SamplePoint) -> Double? { p.pressureClosed }
        // Gas leak 连续采样中若连续两次读到 0，仅告警，不直接判失败
        var consecutiveZeroCount = 0
        var lastZeroWarnAt: String?
        func trackConsecutiveZero(_ decisionBar: Double?, phaseLabel: String, t: Double) {
            guard let bar = decisionBar else {
                consecutiveZeroCount = 0
                return
            }
            if bar == 0 {
                consecutiveZeroCount += 1
                if consecutiveZeroCount >= 2 {
                    let stamp = "\(phaseLabel)-\(String(format: "%.1f", t))"
                    if lastZeroWarnAt != stamp {
                        let channel = "关阀"
                        self.log("\(stepLabel)：[\(phaseLabel)] 连续采样检测到\(channel)压力为 0 mbar（仅告警，不直接判失败）", level: .warning)
                        lastZeroWarnAt = stamp
                    }
                }
            } else {
                consecutiveZeroCount = 0
            }
        }
        
        let phase1Start = Date()
        let phase1Times = GasLeakPhaseTiming.sampleTimes(durationSeconds: preDur, intervalSeconds: interval)
        for (index, sampleT) in phase1Times.enumerated() {
            guard isRunning, ble.isConnected, ble.areCharacteristicsReady else {
                return (false, "连接丢失或用户终止")
            }
            await GasLeakPhaseTiming.waitUntil(phaseStart: phase1Start, targetT: sampleT)
            let nextT = index + 1 < phase1Times.count ? phase1Times[index + 1] : nil
            let bleDeadline = GasLeakPhaseTiming.bleDeadline(
                phaseStart: phase1Start,
                sampleT: sampleT,
                nextSampleT: nextT,
                durationSeconds: preDur
            )
            let (closeStr, openStr, valveStr, gasStr) = await readGasLeakSensorsAndWait(bleDeadline: bleDeadline)
            let closeBar = Self.parseBarFromPressureString(closeStr)
            let openBar = Self.parseBarFromPressureString(openStr)
            if closeBar != nil || openBar != nil {
                let point = SamplePoint(t: sampleT, pressureClosed: closeBar, pressureOpen: openBar, valveState: valveStr.isEmpty ? nil : valveStr, gasSystemStatus: gasStr.isEmpty ? nil : gasStr)
                phase1Samples.append(point)
                trackConsecutiveZero(value(for: point), phaseLabel: "Phase 1", t: sampleT)
                let tStr = String(format: "%.1f", sampleT)
                let closeStr = closeBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                let openStr = openBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                self.log("\(stepLabel)：[Phase 1] t=\(tStr)s，关阀=\(closeStr)，开阀=\(openStr)，阀门=\(valveStr.isEmpty ? "--" : valveStr)，Gas=\(gasStr.isEmpty ? "--" : gasStr)", level: .debug)
            }
        }
        let phase1WallSeconds = Date().timeIntervalSince(phase1Start)
        self.log("\(stepLabel)：Phase 1 采样完成，共 \(phase1Samples.count) 点，配置 \(preDur)s，实际 \(String(format: "%.2f", phase1WallSeconds))s", level: .info)
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
        
        // 4. Phase 2：WiFi 关产线入口阀（§4.4）或人工确认关阀期间采样
        var userActionDuration: Double = 0
        if !config.requireValveClosedConfirm {
            self.log("\(stepLabel)：\(appLanguage.string("production_test.gas_leak_phase2_skipped"))", level: .info)
        }
        if config.requireValveClosedConfirm {
            let coordinator = AuxValveCoordinator(settings: auxValveSettings)
            if AuxValveProductionBridge.shouldAttemptWifi(settings: auxValveSettings) {
                self.log(
                    "\(stepLabel)：Phase 2 尝试 WiFi 关闭产线入口阀 (device_id=\(auxValveSettings.normalizedTargetDeviceId)，reachable=\(auxValveSettings.isAuxValveReachable))…",
                    level: .info
                )
            }
            let wifiCloseResult = await AuxValveProductionBridge.ensureLineValveClose(
                settings: auxValveSettings,
                coordinator: coordinator,
                presentFailureAlert: presentAuxValveFailureAlert
            )

            if wifiCloseResult == .wifiSucceeded {
                self.log("\(stepLabel)：WiFi 产线入口阀已关，跳过关阀确认弹窗（§4.4 单次 BLE 读压）", level: .info)
                let userActionStart = Date()
                let betweenPhaseStart = Date()
                let bleDeadline = betweenPhaseStart.addingTimeInterval(Double(preDur) + interval)
                let (closeStr, openStr, valveStr, gasStr) = await readGasLeakSensorsAndWait(bleDeadline: bleDeadline)
                let closeBar = Self.parseBarFromPressureString(closeStr)
                let openBar = Self.parseBarFromPressureString(openStr)
                let t = Double(preDur)
                if closeBar != nil || openBar != nil {
                    let point = SamplePoint(t: t, pressureClosed: closeBar, pressureOpen: openBar, valveState: valveStr.isEmpty ? nil : valveStr, gasSystemStatus: gasStr.isEmpty ? nil : gasStr)
                    betweenSamples.append(point)
                    trackConsecutiveZero(value(for: point), phaseLabel: "Phase 2", t: t)
                    let tStr = String(format: "%.1f", t)
                    let closeDisplay = closeBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                    let openDisplay = openBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                    self.log("\(stepLabel)：[Phase 2] t=\(tStr)s，关阀=\(closeDisplay)，开阀=\(openDisplay)，阀门=\(valveStr.isEmpty ? "--" : valveStr)，Gas=\(gasStr.isEmpty ? "--" : gasStr)", level: .debug)
                }
                userActionDuration = Date().timeIntervalSince(userActionStart)
                self.log("\(stepLabel)：Phase 2 WiFi 关阀后采样 1 点，耗时 \(String(format: "%.2f", userActionDuration)) 秒", level: .info)
            } else {
                self.log(
                    "\(stepLabel)：Phase 2 WiFi 未关阀成功 (\(wifiCloseResult))，enabled=\(auxValveSettings.enabled) manualRun=\(auxValveSettings.useManualValveForCurrentRun) → 人工关阀确认",
                    level: .warning
                )
                let userActionStart = Date()
                let betweenPhaseStart = Date()
                var betweenSampleIndex = 0
                var userConfirmed = false
                var userResponded = false

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
                    userResponded = true
                }

                while isRunning, ble.isConnected, ble.areCharacteristicsReady, !userResponded {
                    let betweenT = Double(betweenSampleIndex) * interval
                    if betweenT > 3600 { break }
                    await GasLeakPhaseTiming.waitUntil(phaseStart: betweenPhaseStart, targetT: betweenT)
                    let bleDeadline = betweenPhaseStart.addingTimeInterval(betweenT + interval)
                    let (closeStr, openStr, valveStr, gasStr) = await readGasLeakSensorsAndWait(bleDeadline: bleDeadline)
                    let closeBar = Self.parseBarFromPressureString(closeStr)
                    let openBar = Self.parseBarFromPressureString(openStr)
                    let t = Double(preDur) + betweenT
                    if closeBar != nil || openBar != nil {
                        let point = SamplePoint(t: t, pressureClosed: closeBar, pressureOpen: openBar, valveState: valveStr.isEmpty ? nil : valveStr, gasSystemStatus: gasStr.isEmpty ? nil : gasStr)
                        betweenSamples.append(point)
                        trackConsecutiveZero(value(for: point), phaseLabel: "Phase 2", t: t)
                        let tStr = String(format: "%.1f", t)
                        let closeDisplay = closeBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                        let openDisplay = openBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                        self.log("\(stepLabel)：[Phase 2] t=\(tStr)s，关阀=\(closeDisplay)，开阀=\(openDisplay)，阀门=\(valveStr.isEmpty ? "--" : valveStr)，Gas=\(gasStr.isEmpty ? "--" : gasStr)", level: .debug)
                    }
                    betweenSampleIndex += 1
                }

                await confirmationTask.value
                guard userConfirmed else {
                    let msg = appLanguage.string("debug.gas_leak_stop_reason_valve_not_confirmed")
                    self.log("\(stepLabel)：✗ \(msg)", level: .warning)
                    return (false, msg)
                }
                userActionDuration = Date().timeIntervalSince(userActionStart)
                self.log("\(stepLabel)：Phase 2 采样完成，共 \(betweenSamples.count) 点，耗时 \(String(format: "%.2f", userActionDuration)) 秒", level: .info)
            }
        }
        
        // 5. Phase 3 采样（关阀后）
        let phase3Start = Date()
        let phase3Times = GasLeakPhaseTiming.sampleTimes(durationSeconds: postDur, intervalSeconds: interval)
        var hasLoggedPhase3FirstRef = false
        for (index, sampleT) in phase3Times.enumerated() {
            guard isRunning, ble.isConnected, ble.areCharacteristicsReady else {
                return (false, "连接丢失或用户终止")
            }
            await GasLeakPhaseTiming.waitUntil(phaseStart: phase3Start, targetT: sampleT)
            let nextT = index + 1 < phase3Times.count ? phase3Times[index + 1] : nil
            let bleDeadline = GasLeakPhaseTiming.bleDeadline(
                phaseStart: phase3Start,
                sampleT: sampleT,
                nextSampleT: nextT,
                durationSeconds: postDur
            )
            let (closeStr, openStr, valveStr, gasStr) = await readGasLeakSensorsAndWait(bleDeadline: bleDeadline)
            let closeBar = Self.parseBarFromPressureString(closeStr)
            let openBar = Self.parseBarFromPressureString(openStr)
            let t = Double(preDur) + userActionDuration + sampleT
            if closeBar != nil || openBar != nil {
                let point = SamplePoint(t: t, pressureClosed: closeBar, pressureOpen: openBar, valveState: valveStr.isEmpty ? nil : valveStr, gasSystemStatus: gasStr.isEmpty ? nil : gasStr)
                phase2Samples.append(point)
                trackConsecutiveZero(value(for: point), phaseLabel: "Phase 3", t: t)
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
        }
        let phase3WallSeconds = Date().timeIntervalSince(phase3Start)
        self.log("\(stepLabel)：Phase 3 采样完成，共 \(phase2Samples.count) 点，配置 \(postDur)s，实际 \(String(format: "%.2f", phase3WallSeconds))s", level: .info)
        
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
        // 统一定义：Delta 始终为 referenceBar → Phase 3 最低值的压降（由 limitSource 决定参考值）
        capturedGasLeakClosedDeltaMbar = dropFromRefMbar
        capturedGasLeakClosedDurationSeconds = totalDurationSeconds
        capturedGasLeakClosedPhase1AvgBar = phase1Avg
        capturedGasLeakClosedThresholdMbar = thresholdMbar
        capturedGasLeakClosedLimitBar = effectiveLimitBar
        capturedGasLeakClosedLimitSource = config.limitSource
        capturedGasLeakClosedPhase3FirstBar = phase3First
        capturedGasLeakClosedUserActionSeconds = userActionDuration > 0 ? userActionDuration : nil
        capturedGasLeakClosedRefBar = referenceBar

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
            // Phase 4 参数由 SOP JSON 提供，loadProductionGasLeakConfig 已做缺键拦截
            let phase4Enabled = config.phase4Enabled
            if !phase4Enabled {
                self.log("\(stepLabel)：\(appLanguage.string("production_test.gas_leak_phase4_skipped"))", level: .info)
            }
            if phase4Enabled {
                let monitorDur = max(0, config.phase4MonitorDurationSeconds)
                let dropWithin = max(0, config.phase4DropWithinSeconds)
                let belowMbar = max(0, config.phase4PressureBelowMbar)
                self.log("\(stepLabel)：Phase 4 开阀泄压检测，监测 \(monitorDur)s，\(dropWithin)s 内开阀压力需低于 \(String(format: "%.0f", belowMbar)) mbar", level: .info)

                let valveOk = await ensureValveState(open: true)
                guard valveOk else {
                    self.log("\(stepLabel)：✗ Phase 4 电磁阀未能打开", level: .error)
                    return (false, "Phase 4：电磁阀未能打开")
                }
                try? await Task.sleep(nanoseconds: 700_000_000)

                var phase4Samples: [SamplePoint] = []
                var phase4DropAchieved = false
                var phase4ConsecutiveOpenZeroCount = 0
                let phase4Interval = GasLeakPhaseTiming.clampedInterval(interval)
                let phase4Start = Date()
                let phase4Times = GasLeakPhaseTiming.sampleTimes(durationSeconds: monitorDur, intervalSeconds: phase4Interval)

                for (index, sampleT) in phase4Times.enumerated() {
                    guard isRunning, ble.isConnected, ble.areCharacteristicsReady else {
                        return (false, "连接丢失或用户终止")
                    }
                    await GasLeakPhaseTiming.waitUntil(phaseStart: phase4Start, targetT: sampleT)
                    let nextT = index + 1 < phase4Times.count ? phase4Times[index + 1] : nil
                    let bleDeadline = GasLeakPhaseTiming.bleDeadline(
                        phaseStart: phase4Start,
                        sampleT: sampleT,
                        nextSampleT: nextT,
                        durationSeconds: monitorDur
                    )
                    let (closeStr, openStr, valveStr, gasStr) = await readGasLeakSensorsAndWait(bleDeadline: bleDeadline)
                    let closeBar = Self.parseBarFromPressureString(closeStr)
                    let openBar = Self.parseBarFromPressureString(openStr)
                    if openBar != nil || closeBar != nil {
                        let openMbar = (openBar ?? 0) * 1000
                        let point = SamplePoint(t: sampleT, pressureClosed: closeBar, pressureOpen: openBar, valveState: valveStr.isEmpty ? nil : valveStr, gasSystemStatus: gasStr.isEmpty ? nil : gasStr)
                        if sampleT <= Double(dropWithin) && openMbar < belowMbar {
                            phase4DropAchieved = true
                            phase4Samples.append(point)
                            let tStr = String(format: "%.1f", sampleT)
                            let openStrShort = String(format: "%.0f", openMbar)
                            let belowStrShort = String(format: "%.0f", belowMbar)
                            self.log("\(stepLabel)：[Phase 4] t=\(tStr)s 开阀压力 \(openStrShort) mbar < \(belowStrShort) mbar，达标，立即判定通过", level: .info)
                            break
                        }
                        if openMbar == 0 {
                            phase4ConsecutiveOpenZeroCount += 1
                            if phase4ConsecutiveOpenZeroCount >= 2 {
                                self.log("\(stepLabel)：[Phase 4] 连续采样出现开阀压力 0 mbar（仅告警，不直接判失败）", level: .warning)
                            }
                        } else {
                            phase4ConsecutiveOpenZeroCount = 0
                        }
                        phase4Samples.append(point)
                        let tStr = String(format: "%.1f", sampleT)
                        let closeStr = closeBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                        let openStr = openBar.map { String(format: "%.0f mbar", $0 * 1000) } ?? "--"
                        self.log("\(stepLabel)：[Phase 4] t=\(tStr)s，关阀=\(closeStr)，开阀=\(openStr)，阀门=\(valveStr.isEmpty ? "--" : valveStr)，Gas=\(gasStr.isEmpty ? "--" : gasStr)", level: .debug)
                    }
                }

                let phase4WallSeconds = Date().timeIntervalSince(phase4Start)
                self.log("\(stepLabel)：Phase 4 开阀泄压采样完成，共 \(phase4Samples.count) 点，配置 \(monitorDur)s，实际 \(String(format: "%.2f", phase4WallSeconds))s", level: .info)

                // 将 Phase 4 采样并入上传的 raw data（Phase 1～4 一起上传），无论 Phase 4 判定成功与否
                var closedSamples = capturedGasLeakClosedSamples ?? []
                for s in phase4Samples {
                    let pressureBar = s.pressureOpen ?? s.pressureClosed ?? 0
                    closedSamples.append(sampleToDetailDict(s, phase: 4, pressureBar: pressureBar))
                }
                capturedGasLeakClosedSamples = closedSamples.isEmpty ? nil : closedSamples

                if !phase4DropAchieved {
                    // Phase 1～3 的通过结论已在前面以 info 级别日志单独记录，这里仅用 Phase 4 的失败原因作为步骤结果，方便在报表中直观区分
                    let failMsg = String(format: "Phase 4：在 %d s 内开阀压力未低于 %.0f mbar", dropWithin, belowMbar)
                    self.log("\(stepLabel)：✗ \(failMsg)", level: .error)
                    return (false, failMsg)
                }
                self.log("\(stepLabel)：✓ Phase 4 通过（开阀压力已在 \(dropWithin)s 内低于 \(String(format: "%.0f", belowMbar)) mbar）", level: .info)
            }
        }

        let msg = stepId == TestStep.gasLeakClosed.id && config.phase4Enabled
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

        let sessionRunId = UUID().uuidString
        currentTestId = sessionRunId
        lastTestStartTime = Date()
        lastTestEndTime = nil
        auxValveSettings.resetManualValveForNewRun()

        // 如果未连接，先连接设备
        if !ble.isConnected {
            showResultOverlay = false
            needRetestAfterOtaReboot = false
            ble.clearLog()
            isRunning = true
            testLog.removeAll()
            stepLogRanges.removeAll()
            stepIndex = 0
            log("\(appLanguage.string("production_test.session_run_id")) \(sessionRunId)", level: .info)
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
            log("\(appLanguage.string("production_test.session_run_id")) \(sessionRunId)", level: .info)

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
        resetCapturedGasLeakValues()
        initializeStepStatuses()

        if currentTestId == nil {
            currentTestId = UUID().uuidString
        }
        journalEntries = []
        
        // 使用当前的测试步骤列表（已从UserDefaults加载）
        let enabledSteps = currentTestSteps.filter { $0.enabled }
        didFinishThisRun = false
        
        // 加载版本配置（用于步骤验证）
        let rules: (steps: [TestStep], bootloaderVersion: String, firmwareVersion: String, hardwareVersion: String, thresholds: TestThresholds, stepFatalOnFailure: [String: Bool])
        do {
            rules = try loadTestRules()
        } catch {
            self.log("错误：\(error.localizedDescription)", level: .error)
            isRunning = false
            updateTestResultStatus()
            return
        }
        
        self.log("开始产测流程（共 \(enabledSteps.count) 个步骤）", level: .info)
        self.log("——— 产测参数 ———", level: .info)
        self.log("步骤顺序与启用: \(rules.steps.map { "\($0.id)(\($0.enabled ? "开" : "关"))" }.joined(separator: " → "))", level: .info)
        self.log("版本配置: Bootloader=\(rules.bootloaderVersion.isEmpty ? "(空)" : rules.bootloaderVersion), FW=\(rules.firmwareVersion.isEmpty ? "(空)" : rules.firmwareVersion), HW=\(rules.hardwareVersion.isEmpty ? "(空)" : rules.hardwareVersion)", level: .info)
        let t = rules.thresholds
        self.log("步骤间延时: \(t.stepIntervalMs) ms", level: .info)
        if t.bluetoothPermissionWaitSeconds > 0 {
            self.log("蓝牙权限等待: \(String(format: "%.0f", t.bluetoothPermissionWaitSeconds)) s（连接后若出现弹窗请点击允许）", level: .info)
        }
        self.log("超时: 读序列号=\(t.serialReadTimeoutSeconds)s, 设备信息=\(t.deviceInfoReadTimeout)s, OTA启动=\(t.otaStartWaitTimeout)s, 重连=\(t.deviceReconnectTimeout)s, RTC读取=\(t.rtcReadTimeout)s, 阀门=\(t.valveOpenTimeout)s", level: .info)
        self.log("RTC: 通过阈值=\(t.rtcPassThreshold)s, 失败阈值=\(t.rtcFailThreshold)s, 写入=\(t.rtcWriteEnabled), 重试=\(t.rtcWriteRetryCount)次", level: .info)
        self.log("压力: 关阀 \(t.pressureClosedMin)~\(t.pressureClosedMax) mbar, 开阀 \(t.pressureOpenMin)~\(t.pressureOpenMax) mbar, 差值检查=\(t.pressureDiffCheckEnabled), 差值 \(t.pressureDiffMin)~\(t.pressureDiffMax) mbar", level: .info)
        self.log("OTA: 若 FW 不匹配则触发 \(t.firmwareUpgradeEnabled ? "是" : "否")", level: .info)
        self.log("———————————————", level: .info)

        /// 由 step_verify_firmware（确认固件版本）设置：FW 不匹配且「若 FW 不匹配则触发 OTA」开启时为 true；step_ota 据此决定是否执行 OTA
        var fwMismatchRequiresOTA = false
        
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

                case TestStep.readSerialNumber.id:
                    self.log(appLanguage.string("production_test.read_serial_step_log"), level: .info)
                    ble.refreshDeviceInformationSerialAndHardware()
                    let timeoutSeconds = rules.thresholds.serialReadTimeoutSeconds
                    let maxWaitCount = Int(timeoutSeconds * 10)
                    var waitCount = 0
                    while isRunning && waitCount < maxWaitCount {
                        if let raw = ble.deviceSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                            capturedDeviceSN = raw
                            capturedDeviceName = ble.connectedDeviceName
                            self.log(String(format: appLanguage.string("production_test.read_serial_ok_log"), raw), level: .info)
                            stepResults[step.id] = "SN: \(raw)"
                            stepStatuses[step.id] = .passed
                            recordStepOutcome(stepId: step.id, outcome: "passed")
                            break
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        waitCount += 1
                        if waitCount % 20 == 0 {
                            ble.refreshDeviceInformationSerialAndHardware()
                            let elapsed = Double(waitCount) / 10.0
                            self.log(String(format: appLanguage.string("production_test.read_serial_waiting_log"), elapsed, Int(timeoutSeconds)), level: .debug)
                        }
                    }
                    if stepStatuses[step.id] != .passed {
                        self.log(appLanguage.string("production_test.read_serial_fail_log"), level: .error)
                        stepResults[step.id] = appLanguage.string("production_test.read_serial_timeout")
                        stepStatuses[step.id] = .failed
                        recordStepOutcome(stepId: step.id, outcome: "failed")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    
                case "step_verify_firmware": // 确认固件版本
                    self.log("步骤2: 确认固件版本", level: .info)
                    
                    let serialStepEnabled = enabledSteps.contains(where: { $0.id == TestStep.readSerialNumber.id })
                    // 等待设备信息读取完成：若已单独执行「读序列号」则此处只等 FW/HW；否则与旧版一致等 SN、FW、HW
                    self.log(serialStepEnabled ? "等待读取设备信息（FW、HW 版本）..." : "等待读取设备信息（SN、FW、HW 版本）...", level: .info)
                    let timeoutSeconds = rules.thresholds.deviceInfoReadTimeout
                    let maxWaitCount = Int(timeoutSeconds * 10) // 每0.1秒检查一次
                    var waitCount = 0
                    while isRunning && waitCount < maxWaitCount {
                        let snTrim = ble.deviceSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let cachedSn = (capturedDeviceSN ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let snReady = serialStepEnabled ? (!cachedSn.isEmpty || !snTrim.isEmpty) : !snTrim.isEmpty
                        let fwReady = ble.currentFirmwareVersion != nil
                        let hwTrim = ble.deviceHardwareRevision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let hwReady = !hwTrim.isEmpty
                        if snReady && fwReady && hwReady { break }
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
                    
                    // 验证 SN（单独「读序列号」步骤已启用时，优先使用已缓存的 SN）
                    var resultMessages: [String] = []
                    let joinFirmwareStepFailureBody: (String) -> String = { tail in
                        let head = resultMessages.filter { !$0.isEmpty }.joined(separator: "\n")
                        return head.isEmpty ? tail : head + "\n" + tail
                    }
                    
                    let snCandidate: String?
                    if serialStepEnabled {
                        let cached = (capturedDeviceSN ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let bleSn = ble.deviceSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !cached.isEmpty {
                            snCandidate = cached
                        } else if !bleSn.isEmpty {
                            snCandidate = bleSn
                        } else {
                            snCandidate = nil
                        }
                    } else {
                        snCandidate = ble.deviceSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    
                    if let sn = snCandidate, !sn.isEmpty {
                        self.log("✓ SN 验证通过: \(sn)", level: .info)
                        // 本步骤已校验 SN；仅当未单独启用「读序列号」步骤时，才在步骤结果里再写一行 SN（否则与上一步重复；上传仍用 capturedDeviceSN）
                        if !serialStepEnabled {
                            resultMessages.append("SN: \(sn)")
                        }
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
                                    stepResults[step.id] = joinFirmwareStepFailureBody(appLanguage.string("production_test.bootloader_version_mismatch"))
                                    if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                                    break
                                }
                            } else {
                                // 规则解析不到有效数字时，退回旧逻辑
                                if let num = blNum, num < 2 {
                                    self.log("错误：Bootloader 版本过低（当前: \(blVersionStr)，要求 ≥ 2）", level: .error)
                                    stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                                    stepResults[step.id] = joinFirmwareStepFailureBody(appLanguage.string("production_test.bootloader_too_old"))
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
                                stepResults[step.id] = joinFirmwareStepFailureBody(appLanguage.string("production_test.bootloader_too_old"))
                                if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                                break
                            }
                            resultMessages.append("BL: \(blVersionStr)")
                        }
                    } else {
                        self.log("错误：无法读取 Bootloader 版本", level: .error)
                        stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = joinFirmwareStepFailureBody(appLanguage.string("production_test.bootloader_unreadable"))
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
                                    stepResults[step.id] = joinFirmwareStepFailureBody(String(format: appLanguage.string("production_test.server_no_firmware"), rules.firmwareVersion))
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
                            resultMessages.append("FW: \(fwVersion)")
                        }
                    } else {
                        self.log("警告：无法读取 FW 版本", level: .warning)
                        resultMessages.append("FW: ⚠️")
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
                    
                case "step_verify_hw_rev": // 读取 HW_REV（2A27）；读到非空即通过；出货区写入在 step_hw_rev_shipping_region
                    self.log("步骤: 读取 HW_REV", level: .info)
                    let readTimeout = rules.thresholds.hwRevReadTimeoutSeconds
                    let pollNs = UInt64(max(10, rules.thresholds.hwRevReadPollIntervalMs)) * 1_000_000

                    if ble.deviceHardwareRevision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                        ble.refreshDeviceInformationSerialAndHardware()
                    }
                    var waited: Double = 0
                    while isRunning && (ble.deviceHardwareRevision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && waited < readTimeout {
                        try? await Task.sleep(nanoseconds: pollNs)
                        waited += Double(max(10, rules.thresholds.hwRevReadPollIntervalMs)) / 1000.0
                    }
                    guard let currentHwRaw = ble.deviceHardwareRevision?.trimmingCharacters(in: .whitespacesAndNewlines), !currentHwRaw.isEmpty else {
                        self.log("错误：无法读取 HW_REV（2A27）", level: .error)
                        stepStatuses[step.id] = .failed
                        recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = appLanguage.string("production_test.hardware_version_unreadable")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }

                    self.log("✓ 已读取 HW_REV: \(currentHwRaw)", level: .info)
                    stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                    stepResults[step.id] = "HW: \(currentHwRaw)"
                    capturedHardwareRevision = currentHwRaw

                case TestStep.hwRevShippingRegion.id: // 出货区域 HW_REV（美/欧）：按 destination 写入目标并回读确认
                    self.log("步骤: 出货区域 HW_REV", level: .info)
                    let destLabel = rules.thresholds.shippingDestination == "eu"
                        ? appLanguage.string("production_test_rules.shipping_destination_eu")
                        : appLanguage.string("production_test_rules.shipping_destination_us")
                    let targetHw = (rules.thresholds.shippingDestination == "eu")
                        ? rules.thresholds.shippingHwRevEu
                        : rules.thresholds.shippingHwRevUs
                    let readTimeout = rules.thresholds.shippingHwRevReadTimeoutSeconds
                    let verifyTimeout = rules.thresholds.shippingHwRevWriteVerifyTimeoutSeconds
                    let pollNs = UInt64(max(10, rules.thresholds.shippingHwRevWriteVerifyPollIntervalMs)) * 1_000_000

                    if ble.deviceHardwareRevision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                        ble.refreshDeviceInformationSerialAndHardware()
                    }
                    var shipWaited: Double = 0
                    while isRunning && (ble.deviceHardwareRevision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && shipWaited < readTimeout {
                        try? await Task.sleep(nanoseconds: pollNs)
                        shipWaited += Double(max(10, rules.thresholds.shippingHwRevWriteVerifyPollIntervalMs)) / 1000.0
                    }
                    guard let shipCurrentRaw = ble.deviceHardwareRevision?.trimmingCharacters(in: .whitespacesAndNewlines), !shipCurrentRaw.isEmpty else {
                        self.log("错误：无法读取 HW_REV（2A27）", level: .error)
                        stepStatuses[step.id] = .failed
                        recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = appLanguage.string("production_test.hardware_version_unreadable")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }

                    if shipCurrentRaw == targetHw {
                        self.log("✓ 出货区域 HW_REV 一致（\(destLabel)）: \(shipCurrentRaw)", level: .info)
                        stepStatuses[step.id] = .passed
                        recordStepOutcome(stepId: step.id, outcome: "passed")
                        stepResults[step.id] = "\(destLabel) HW: \(shipCurrentRaw)"
                        capturedHardwareRevision = shipCurrentRaw
                        break
                    }

                    self.log("出货区域 HW_REV 不一致（\(destLabel) 期望: \(targetHw), 实际: \(shipCurrentRaw)）", level: .warning)
                    guard rules.thresholds.shippingHwRevAutoWriteWhenMismatch else {
                        stepStatuses[step.id] = .failed
                        recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = appLanguage.string("production_test.hardware_version_mismatch")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }

                    self.log("尝试写入出货区域 HW_REV -> \(targetHw)（\(destLabel)）", level: .info)
                    let hwRevBeforeWriteNorm: String? = {
                        let n = BLEManager.normalizedProductHardwareRevision(shipCurrentRaw)
                            ?? shipCurrentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                        return n.isEmpty ? nil : n
                    }()
                    let shipWriteResult = await ble.sendDevAccessChangeHardwareRevision(to: targetHw)
                    switch shipWriteResult {
                    case .completed:
                        self.log("出货区域 HW_REV 写入命令已发送，等待回读确认", level: .info)
                    case .invalidFormat:
                        self.log("错误：目标 HW_REV 格式不合法（需 PXXVXXRXX）", level: .error)
                        reportHardwareRevisionChangeToServer(
                            previousHardwareRevision: hwRevBeforeWriteNorm,
                            newHardwareRevision: targetHw,
                            changeSuccess: false,
                            failureReason: "invalid_format"
                        )
                        stepStatuses[step.id] = .failed
                        recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = appLanguage.string("production_test.hardware_version_invalid_format")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    case .emptyValue, .notReady, .rejectedByVersion:
                        self.log("错误：HW_REV 写入失败（\(String(describing: shipWriteResult))）", level: .error)
                        reportHardwareRevisionChangeToServer(
                            previousHardwareRevision: hwRevBeforeWriteNorm,
                            newHardwareRevision: targetHw,
                            changeSuccess: false,
                            failureReason: "device_write_failed"
                        )
                        stepStatuses[step.id] = .failed
                        recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = appLanguage.string("production_test.hardware_version_write_failed")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    if stepStatuses[step.id] == .failed { break }

                    var shipVerifyElapsed: Double = 0
                    while isRunning && shipVerifyElapsed < verifyTimeout {
                        let got = ble.deviceHardwareRevision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if got == targetHw {
                            self.log("✓ 出货区域 HW_REV 回读确认通过: \(got)", level: .info)
                            reportHardwareRevisionChangeToServer(
                                previousHardwareRevision: hwRevBeforeWriteNorm,
                                newHardwareRevision: targetHw,
                                changeSuccess: true,
                                failureReason: nil
                            )
                            stepStatuses[step.id] = .passed
                            recordStepOutcome(stepId: step.id, outcome: "passed")
                            stepResults[step.id] = "\(destLabel) HW: \(got)"
                            capturedHardwareRevision = got
                            break
                        }
                        ble.refreshDeviceInformationSerialAndHardware()
                        try? await Task.sleep(nanoseconds: pollNs)
                        shipVerifyElapsed += Double(max(10, rules.thresholds.shippingHwRevWriteVerifyPollIntervalMs)) / 1000.0
                    }
                    if stepStatuses[step.id] != .passed {
                        let shipActual = ble.deviceHardwareRevision?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "--"
                        self.log("错误：出货区域 HW_REV 回读确认失败（期望: \(targetHw), 实际: \(shipActual)）", level: .error)
                        reportHardwareRevisionChangeToServer(
                            previousHardwareRevision: hwRevBeforeWriteNorm,
                            newHardwareRevision: targetHw,
                            changeSuccess: false,
                            failureReason: "readback_mismatch"
                        )
                        stepStatuses[step.id] = .failed
                        recordStepOutcome(stepId: step.id, outcome: "failed")
                        stepResults[step.id] = appLanguage.string("production_test.hardware_version_verify_failed")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }

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
                        // WiFi 产线入口阀已开则跳过气路确认弹窗（§4.7）；失败或未启用时仍走人工确认
                        let skipPipelineConfirm = await self.tryOpenLineValveViaWiFiBeforePressureStep()
                        if !skipPipelineConfirm {
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
                        
                        // 1. 打开阀门：发令后最多 valve_open_timeout 秒内轮询 valveState 直至 open（同 ensureValveState）
                        self.log("打开阀门...", level: .info)
                        if await ensureValveState(open: true) {
                            self.log("阀门已打开", level: .info)
                        } else {
                            self.log("警告：阀门状态异常（当前: \(ble.lastValveStateValue)）", level: .warning)
                        }
                        
                        // 2. 读取开阀压力（清空旧值后发起读取，轮询等待设备响应，避免固定 500ms 未收到回调导致仍为 "--"）
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        self.log("读取开启状态压力...", level: .info)
                        ble.clearLastPressureOpenValue()
                        ble.readPressureOpen()
                        var openPressureStr = await waitForPressureValue(
                            getValue: { ble.lastPressureOpenValue },
                            timeoutSeconds: rules.thresholds.pressureReadTimeoutSeconds,
                            pollIntervalMs: rules.thresholds.pressureReadPollIntervalMs,
                            label: "开阀压力"
                        )
                        if openPressureStr.isEmpty || openPressureStr == "--" {
                            self.log(appLanguage.string("production_test.pressure_read_timeout_open"), level: .warning)
                        } else {
                            self.log("开启压力: \(openPressureStr)", level: .info)
                        }
                        // 若为错误或0值，快速重读一次；若两次均为 0，则记录标记
                        if openPressureStr.hasPrefix("Error") || openPressureStr == "0 mbar" {
                            self.log("检测到开阀压力异常(\(openPressureStr))，快速重读一次", level: .warning)
                            ble.clearLastPressureOpenValue()
                            ble.readPressureOpen()
                            openPressureStr = await waitForPressureValue(
                                getValue: { ble.lastPressureOpenValue },
                                timeoutSeconds: rules.thresholds.pressureRetryReadTimeoutSeconds,
                                pollIntervalMs: rules.thresholds.pressureRetryReadPollIntervalMs,
                                label: "开阀压力[重读]"
                            )
                            self.log("开阀压力[重读]结果: \(openPressureStr)", level: .info)
                        }
                        openPressureValue = Self.parseBarFromPressureString(openPressureStr)
                        
                        // 3. 关闭阀门：发令后最多 valve_open_timeout 秒内轮询直至 closed
                        self.log("关闭阀门...", level: .info)
                        if await ensureValveState(open: false) {
                            self.log("阀门已关闭", level: .info)
                        } else {
                            self.log("警告：阀门状态异常（当前: \(ble.lastValveStateValue)）", level: .warning)
                        }
                        
                        // 4. 读取关闭状态压力（同样轮询等待响应）
                        self.log("读取关闭状态压力...", level: .info)
                        ble.clearLastPressureValue()
                        ble.readPressure()
                        var closedPressureStr = await waitForPressureValue(
                            getValue: { ble.lastPressureValue },
                            timeoutSeconds: rules.thresholds.pressureReadTimeoutSeconds,
                            pollIntervalMs: rules.thresholds.pressureReadPollIntervalMs,
                            label: "关阀压力"
                        )
                        if closedPressureStr.isEmpty || closedPressureStr == "--" {
                            self.log(appLanguage.string("production_test.pressure_read_timeout_closed"), level: .warning)
                        } else {
                            self.log("关闭压力: \(closedPressureStr)", level: .info)
                        }
                        // 若为错误或0值，快速重读一次；若两次均为 0，则记录标记
                        if closedPressureStr.hasPrefix("Error") || closedPressureStr == "0 mbar" {
                            self.log("检测到关阀压力异常(\(closedPressureStr))，快速重读一次", level: .warning)
                            ble.clearLastPressureValue()
                            ble.readPressure()
                            closedPressureStr = await waitForPressureValue(
                                getValue: { ble.lastPressureValue },
                                timeoutSeconds: rules.thresholds.pressureRetryReadTimeoutSeconds,
                                pollIntervalMs: rules.thresholds.pressureRetryReadPollIntervalMs,
                                label: "关阀压力[重读]"
                            )
                            self.log("关阀压力[重读]结果: \(closedPressureStr)", level: .info)
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
                        
                        // 将各条压力结论用换行拼接，提升报表可读性
                        let pressureSummary = pressureMessages.joined(separator: "\n")
                        stepResults[step.id] = pressureSummary + "\n" + appLanguage.string("production_test.pressure_criteria_hint")
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
                    let valveCheckEnabled = rules.thresholds.disableDiagValveCheckEnabled
                    let valveCheckSettleSeconds = max(0, rules.thresholds.disableDiagValveCheckSettleSeconds)
                    let valveCheckPressureReadDelaySeconds = max(0, rules.thresholds.disableDiagValveCheckPressureReadDelaySeconds)
                    let expectedStatuses: [Int] = rules.thresholds.disableDiagExpectedGasStatuses
                    let expectedDescription = expectedStatuses.map(String.init).joined(separator: ",")
                    let waitSecondsStr = String(format: "%.1f", rules.thresholds.disableDiagWaitSeconds)
                    let pollTimeoutSec = max(0.1, rules.thresholds.disableDiagPollTimeoutSeconds)
                    let pollWindowStr = String(format: "%.1f", pollTimeoutSec)
                    let sopVersionLabel = productionRulesStore.rules.rulesVersion.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rulesLabelForMessage = sopVersionLabel.isEmpty ? "—" : sopVersionLabel

                    self.log("Disable diag 判定准则：向 CO2 Pressure Limits 写入 12×0x00 后，等待 \(waitSecondsStr) 秒，再在 \(pollWindowStr) 秒轮询内，Gas system status 必须变为期望值集合中的任意一个：\(expectedDescription)。", level: .info)
                    ble.writeCo2PressureLimitsZeros()
                    let waitSec = max(0, rules.thresholds.disableDiagWaitSeconds)
                    if waitSec > 0 {
                        self.log("等待 \(String(format: "%.1f", waitSec)) 秒…", level: .info)
                        try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
                    }
                    if rules.thresholds.disableDiagPollGasStatusEnabled {
                        self.log("轮询 Gas system status 直至为集合中的任意一个值 [\(expectedDescription)]（超时 \(pollWindowStr)s）…", level: .info)
                        let pollStart = Date()
                        var gasReached = false
                        var matchedGasRawForDisableDiag: String?
                        while isRunning, ble.isConnected, ble.areCharacteristicsReady, Date().timeIntervalSince(pollStart) < pollTimeoutSec {
                            ble.readGasSystemStatus(silent: true)
                            try? await Task.sleep(nanoseconds: UInt64(max(1, rules.thresholds.disableDiagPollIntervalMs)) * 1_000_000)
                            let raw = ble.lastGasSystemStatusValue
                            let parsed: Int? = raw.split(separator: " ").first.flatMap { Int(String($0)) }
                            if let v = parsed, expectedStatuses.contains(v) {
                                gasReached = true
                                matchedGasRawForDisableDiag = raw
                                self.log("Gas system status 已满足期望集合 [\(expectedDescription)]: \(raw)", level: .info)
                                break
                            }
                        }
                        if gasReached {
                            let gasReadoutForSummary = (matchedGasRawForDisableDiag ?? ble.lastGasSystemStatusValue).trimmingCharacters(in: .whitespacesAndNewlines)
                            let gasReadoutDisplay = gasReadoutForSummary.isEmpty ? "—" : gasReadoutForSummary
                            let passPolledSummary = String(
                                format: appLanguage.string("production_test_rules.step_disable_diag_pass_polled"),
                                rulesLabelForMessage, waitSecondsStr, pollWindowStr, gasReadoutDisplay, expectedDescription
                            )
                            // 自检成功禁用后，再执行一次阀门开/关检查与压力读取（仅记录）
                            if valveCheckEnabled {
                                let valveOkForDisableDiag = await runDisableDiagValveCheck(settleSeconds: valveCheckSettleSeconds, pressureReadDelaySeconds: valveCheckPressureReadDelaySeconds)
                                if valveOkForDisableDiag {
                                    stepResults[step.id] = passPolledSummary
                                    stepStatuses[step.id] = .passed
                                    recordStepOutcome(stepId: step.id, outcome: "passed")
                                } else {
                                    let msg = "Disable diag: Gas system status 已达预期，但阀门开/关检查未通过，请检查气路与电磁阀状态。"
                                    self.log(msg, level: .error)
                                    stepResults[step.id] = msg
                                    stepStatuses[step.id] = .failed
                                    recordStepOutcome(stepId: step.id, outcome: "failed")
                                    if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                                }
                            } else {
                                stepResults[step.id] = passPolledSummary
                                stepStatuses[step.id] = .passed
                                recordStepOutcome(stepId: step.id, outcome: "passed")
                            }
                        } else {
                            let elapsed = String(format: "%.1f", Date().timeIntervalSince(pollStart))
                            self.log("错误：\(pollWindowStr)s 内 Gas system status 未进入期望集合 [\(expectedDescription)]（当前: \(ble.lastGasSystemStatusValue)）", level: .error)
                            stepResults[step.id] = String(format: appLanguage.string("production_test_rules.step_disable_diag_fail_timeout"), elapsed, expectedDescription, rulesLabelForMessage)
                            stepStatuses[step.id] = .failed
                            recordStepOutcome(stepId: step.id, outcome: "failed")
                            if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        }
                    } else {
                        // 不轮询 Gas status 的场景：写入 12×0x00 后，同样在禁用自检后执行阀门检查
                        let passNoPollSummary = String(
                            format: appLanguage.string("production_test_rules.step_disable_diag_pass_no_poll"),
                            rulesLabelForMessage, waitSecondsStr, expectedDescription
                        )
                        if valveCheckEnabled {
                            let valveOkForDisableDiag = await runDisableDiagValveCheck(settleSeconds: valveCheckSettleSeconds, pressureReadDelaySeconds: valveCheckPressureReadDelaySeconds)
                            if valveOkForDisableDiag {
                                stepResults[step.id] = passNoPollSummary
                                stepStatuses[step.id] = .passed
                                recordStepOutcome(stepId: step.id, outcome: "passed")
                            } else {
                                let msg = "Disable diag: 已写入 12×0x00，但阀门开/关检查未通过，请检查气路与电磁阀状态。"
                                self.log(msg, level: .error)
                                stepResults[step.id] = msg
                                stepStatuses[step.id] = .failed
                                recordStepOutcome(stepId: step.id, outcome: "failed")
                                if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                            }
                        } else {
                            stepResults[step.id] = passNoPollSummary
                            stepStatuses[step.id] = .passed
                            recordStepOutcome(stepId: step.id, outcome: "passed")
                        }
                    }
                    
                case "step_gas_system_status":
                    self.log("步骤: 读取 Gas system status", level: .info)
                    let allowedGasStatuses: [Int] = rules.thresholds.gasSystemStatusExpectedValues
                    let allowedGasDesc = allowedGasStatuses.map(String.init).joined(separator: ",")
                    self.log("Gas system status 允许值集合: [\(allowedGasDesc)]", level: .info)
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
                        let parsedCode: Int? = gasStatusStr.split(separator: " ").first.flatMap { Int(String($0)) }
                        let inAllowed = parsedCode.map { allowedGasStatuses.contains($0) } ?? false
                        if inAllowed {
                            self.log("✓ Gas system status 验证通过: \(gasStatusStr)（在允许集合 [\(allowedGasDesc)] 内）", level: .info)
                            stepResults[step.id] = String(format: appLanguage.string("production_test_rules.gas_status_pass"), gasStatusStr)
                            stepStatuses[step.id] = .passed
                    recordStepOutcome(stepId: step.id, outcome: "passed")
                        } else {
                            self.log("Gas system status 检查失败: \(gasStatusStr)，允许集合 [\(allowedGasDesc)]", level: .error)
                            stepResults[step.id] = "\(String(format: appLanguage.string("production_test_rules.gas_status_fail_expected"), gasStatusStr))（SOP 允许: \(allowedGasDesc)）"
                            stepStatuses[step.id] = .failed
                    recordStepOutcome(stepId: step.id, outcome: "failed")
                            if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        }
                        capturedGasSystemStatus = gasStatusStr.isEmpty || gasStatusStr == "--" ? nil : gasStatusStr
                    }
                    
                case "step_gas_leak_closed": // 气体泄漏检测（关阀压力）
                    self.log("步骤: 气体泄漏检测（关阀压力）", level: .info)
                    let configClosed: ProductionGasLeakConfig
                    do {
                        configClosed = try loadProductionGasLeakConfig()
                    } catch {
                        let msg = "规则错误：\(error.localizedDescription)"
                        self.log(msg, level: .error)
                        stepResults[step.id] = msg
                        stepStatuses[step.id] = .failed
                        recordStepOutcome(stepId: step.id, outcome: "failed")
                        if await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                        break
                    }
                    let resultClosed = await runProductionGasLeakStep(stepId: step.id, stepLabel: appLanguage.string("production_test_rules.step_gas_leak_closed_title"), config: configClosed)
                    stepResults[step.id] = resultClosed.message
                    stepStatuses[step.id] = resultClosed.passed ? .passed : .failed
                    didRunGasLeakClosedStep = true
                    if stepStatuses[step.id] == .failed, await handleStepFailureShouldExit(step: step, enabledSteps: enabledSteps, thresholds: rules.thresholds, stepFatalOnFailure: rules.stepFatalOnFailure) { return }
                    
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
        emitProductionTestReport()
        lastTestEndTime = Date()
        let body = buildProductionTestPayload()
        if let tid = currentTestId {
            saveProductionTestRecordToLocalFile(testId: tid, summary: body, journal: journalEntries)
        }
        if serverSettings.uploadToServerEnabled {
            Task { await uploadProductionTestResultIfNeeded(body: body) }
        }
        showResultOverlay = true
    }
    
    /// 产测结束时生成报表并写入日志区，按步骤结果使用不同 log 等级（通过=info、失败=error、跳过=warning）。
    /// 列出 **完整** SOP（`currentTestSteps`），含规则中关闭的步骤。
    private func emitProductionTestReport() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_POSIX")
        let timeStr = formatter.string(from: Date())
        let disabledHint = appLanguage.string("production_test.step_disabled_in_rules")
        
        self.log("", level: .info)
        self.log("", level: .info)
        self.log("────────── 产测报表 ──────────", level: .info)
        self.log("时间: \(timeStr)", level: .info)
        self.log(String(format: appLanguage.string("production_test.report_meta_sop"), displayableSOPVersion), level: .info)
        self.log(String(format: appLanguage.string("production_test.report_meta_schema"), productionRulesStore.rules.schemaVersion), level: .info)
        if let bog = bogToolVersionPayloadString {
            self.log(String(format: appLanguage.string("production_test.report_meta_bog_tool"), bog), level: .info)
        }
        if needRetestAfterOtaReboot {
            self.log("需要重测（本次因当前固件不支持恢复出厂/重启而在 OTA 后发送了 reboot，请重测以执行后续步骤）", level: .warning)
        }
        self.log("步骤:", level: .info)
        for (index, step) in currentTestSteps.enumerated() {
            let status: StepTestStatus
            if !step.enabled {
                status = .skipped
            } else {
                status = stepStatuses[step.id] ?? .pending
            }
            var result = stepResults[step.id] ?? ""
            if !step.enabled && result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = disabledHint
            }
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
            
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            // 标题行：只展示步骤名称与结果符号
            self.log("  \(index + 1). \(title) \(statusStr)", level: stepLevel)
            // 详情行：按原有 result 中的换行拆分，每行单独输出并缩进，提升可读性
            if !trimmed.isEmpty {
                let lines = trimmed.components(separatedBy: .newlines)
                for line in lines {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    guard !l.isEmpty else { continue }
                    self.log("       \(l)", level: stepLevel)
                }
            }
        }
        self.log("──────────────────────────────", level: .info)
        self.log("", level: .info)
        self.log("", level: .info)
    }
}

// MARK: - 产测结果 Overlay（多行高可读性：失败行红色突出，其余中性/轻强调）
private struct ProductionTestResultOverlay: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    let passed: Bool
    let criteria: [(name: String, ok: Bool, isWarning: Bool, detail: String?)]
    let timeString: String
    let needRetest: Bool
    let sopVersionDisplay: String
    let rulesSchemaVersion: Int
    let bogToolVersionDisplay: String?
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
    
    /// 行标题图标/文字颜色：仅失败用红色，其余使用系统 label 颜色；警告用轻微橙色点缀
    private func rowIconColor(ok: Bool, isWarning: Bool) -> Color {
        if !ok { return Color(red: 0.78, green: 0.22, blue: 0.22) }       // 红色（失败）
        if isWarning { return Color(red: 0.85, green: 0.55, blue: 0.20) } // 橙色（警告）
        return Color(NSColor.secondaryLabelColor)                         // 中性（通过）
    }
    
    /// 行背景色：失败用浅红底，其余用很淡的分隔背景
    private func rowBackgroundColor(ok: Bool, isWarning: Bool) -> Color {
        if !ok { return Color(red: 0.99, green: 0.90, blue: 0.90) }       // 失败：浅红底
        if isWarning { return Color(red: 1.0, green: 0.97, blue: 0.90) }  // 警告：浅橙底
        return Color(NSColor.controlBackgroundColor)                      // 通过：中性背景
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: appLanguage.string("production_test.report_meta_sop"), sopVersionDisplay))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                            Text(String(format: appLanguage.string("production_test.report_meta_schema"), rulesSchemaVersion))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                            if let bog = bogToolVersionDisplay {
                                Text(String(format: appLanguage.string("production_test.report_meta_bog_tool"), bog))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Color(NSColor.secondaryLabelColor))
                            }
                        }
                        if needRetest {
                            Text(appLanguage.string("production_test.need_retest_detail"))
                                .font(.subheadline)
                                .foregroundStyle(Color(NSColor.secondaryLabelColor))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(criteria.enumerated()), id: \.offset) { _, item in
                                    let iconColor = rowIconColor(ok: item.ok, isWarning: item.isWarning)
                                    let bgColor = rowBackgroundColor(ok: item.ok, isWarning: item.isWarning)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .center, spacing: 8) {
                                            Text(item.ok ? "✓" : "✗")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(iconColor)
                                            Text(item.name)
                                                .font(.subheadline)
                                                .foregroundStyle(item.ok ? Color(NSColor.labelColor) : Color(red: 0.78, green: 0.22, blue: 0.22))
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
