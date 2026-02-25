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

/// 产测模式：连接后执行 开→关→开，并在开前/开后/关后各读一次压力
struct ProductionTestView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @EnvironmentObject private var serverSettings: ServerSettings
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
                
                ScrollView {
                    testStepsSection
                        .padding(.horizontal, UIDesignSystem.Padding.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 320, maxHeight: .infinity)
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
                        
                        // 展开/折叠图标
                        if status != .pending && status != .running {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
                // 只有非pending和非running状态的步骤才能展开
                if status != .pending && status != .running {
                    if isExpanded {
                        expandedSteps.remove(step.id)
                    } else {
                        expandedSteps.insert(step.id)
                    }
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
    
    // MARK: - 整体通过判定（连接、RTC、固件一致或 OTA 成功、压力、电磁阀）
    
    /// 产测整体是否通过：连接成功、RTC 成功、固件一致或 FW 不一致但 OTA 成功、压力通过、电磁阀打开，全部满足才为通过
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
        let gasSystemStatusOk = !enabled.contains(where: { $0.id == TestStep.readGasSystemStatus.id }) || stepStatuses[TestStep.readGasSystemStatus.id] == .passed
        let valveOk = !enabled.contains(where: { $0.id == TestStep.ensureValveOpen.id }) || stepStatuses[TestStep.ensureValveOpen.id] == .passed
        // 恢复出厂 / 重启：若步骤启用则必须真正执行通过，未执行（如版本不支持而跳过）则整体判失败
        let factoryResetOk = !enabled.contains(where: { $0.id == TestStep.factoryReset.id }) || stepStatuses[TestStep.factoryReset.id] == .passed
        let resetOk = !enabled.contains(where: { $0.id == TestStep.reset.id }) || stepStatuses[TestStep.reset.id] == .passed
        return connectOk && rtcOk && fwOk && pressureOk && gasSystemStatusOk && valveOk && factoryResetOk && resetOk
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
        // Gas system status
        if enabled.contains(where: { $0.id == TestStep.readGasSystemStatus.id }) {
            list.append((appLanguage.string("production_test_rules.step_gas_system_status_title"), stepStatuses[TestStep.readGasSystemStatus.id] == .passed, false, detail(for: TestStep.readGasSystemStatus.id)))
        } else if currentTestSteps.contains(where: { $0.id == TestStep.readGasSystemStatus.id }) {
            list.append((appLanguage.string("production_test_rules.step_gas_system_status_title"), true, true, skippedDetail))
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
    private func loadTestRules() -> (steps: [TestStep], bootloaderVersion: String, firmwareVersion: String, hardwareVersion: String, thresholds: TestThresholds) {
        // 加载步骤顺序和启用状态（含断开前 OTA、确保电磁阀开启、重启、恢复出厂等步骤）
        let stepMap = [TestStep.connectDevice, .verifyFirmware, .readRTC, .readPressure, .readGasSystemStatus, .tbd, .ensureValveOpen, .reset, .factoryReset, .otaBeforeDisconnect, .disconnectDevice]
            .reduce(into: [:]) { $0[$1.id] = $1 }
        
        var steps: [TestStep] = []
        if let saved = UserDefaults.standard.array(forKey: "production_test_steps_order") as? [String] {
            for id in saved {
                if let step = stepMap[id] {
                    steps.append(step)
                }
            }
        } else {
            steps = [.connectDevice, .verifyFirmware, .readRTC, .readPressure, .readGasSystemStatus, .ensureValveOpen, .reset, .factoryReset, .tbd, .otaBeforeDisconnect, .disconnectDevice]
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
        // 迁移：若旧配置中无「读取 Gas system status」步骤，则插入在读取压力之后、确保电磁阀之前
        if !steps.contains(where: { $0.id == TestStep.readGasSystemStatus.id }) {
            if let idx = steps.firstIndex(where: { $0.id == TestStep.readPressure.id }) {
                steps.insert(TestStep.readGasSystemStatus, at: idx + 1)
            } else if let idx = steps.firstIndex(where: { $0.id == TestStep.ensureValveOpen.id }) {
                steps.insert(TestStep.readGasSystemStatus, at: idx)
            } else {
                steps.insert(TestStep.readGasSystemStatus, at: steps.count - 1)
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
        
        // 加载每个步骤的启用状态（step_reset 产测中不许启用，始终为 false）
        if let enabledDict = UserDefaults.standard.dictionary(forKey: "production_test_steps_enabled") as? [String: Bool] {
            for i in 0..<steps.count {
                if steps[i].id == TestStep.reset.id {
                    steps[i] = TestStep(id: steps[i].id, key: steps[i].key, isLocked: steps[i].isLocked, enabled: false)
                } else if let enabled = enabledDict[steps[i].id] {
                    steps[i] = TestStep(id: steps[i].id, key: steps[i].key, isLocked: steps[i].isLocked, enabled: enabled)
                }
            }
        }
        
        // 加载版本配置
        let bootloaderVersion = UserDefaults.standard.string(forKey: "production_test_bootloader_version") ?? ""
        let firmwareVersion = UserDefaults.standard.string(forKey: "production_test_firmware_version") ?? "1.0.5"
        let hardwareVersion = UserDefaults.standard.string(forKey: "production_test_hardware_version") ?? "P02V02R00"
        
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
            pressureClosedMin: UserDefaults.standard.object(forKey: "production_test_pressure_closed_min") as? Double ?? 1100,
            pressureClosedMax: UserDefaults.standard.object(forKey: "production_test_pressure_closed_max") as? Double ?? 1350,
            pressureOpenMin: UserDefaults.standard.object(forKey: "production_test_pressure_open_min") as? Double ?? 1300,
            pressureOpenMax: UserDefaults.standard.object(forKey: "production_test_pressure_open_max") as? Double ?? 1500,
            pressureDiffCheckEnabled: UserDefaults.standard.object(forKey: "production_test_pressure_diff_check_enabled") as? Bool ?? true,
            pressureDiffMin: UserDefaults.standard.object(forKey: "production_test_pressure_diff_min") as? Double ?? 30,
            pressureDiffMax: UserDefaults.standard.object(forKey: "production_test_pressure_diff_max") as? Double ?? 400,
            firmwareUpgradeEnabled: UserDefaults.standard.object(forKey: "production_test_firmware_upgrade_enabled") as? Bool ?? true
        )
        
        return (steps: steps, bootloaderVersion: bootloaderVersion, firmwareVersion: firmwareVersion, hardwareVersion: hardwareVersion, thresholds: thresholds)
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
        let pressureClosedMin: Double        // 关闭状态压力下限（mbar）
        let pressureClosedMax: Double        // 关闭状态压力上限（mbar）
        let pressureOpenMin: Double          // 开启状态压力下限（mbar）
        let pressureOpenMax: Double          // 开启状态压力上限（mbar）
        let pressureDiffCheckEnabled: Bool   // 是否启用压力差值检查
        let pressureDiffMin: Double          // 压力差值下限（mbar）
        let pressureDiffMax: Double          // 压力差值上限（mbar）
        let firmwareUpgradeEnabled: Bool     // 是否启用固件版本升级
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
                stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria") + "（未确认断开）"
            case .timeout(pairingRemoved: true):
                stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test_rules.step_factory_reset_confirmed_pairing_removed")
            case .timeout(pairingRemoved: false):
                stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria") + "（未确认断开）"
            }
        case .rejectedByVersion:
            self.log("固件版本不支持恢复出厂命令，步骤跳过", level: .warning)
            stepResults[TestStep.factoryReset.id] = appLanguage.string("production_test.overlay_step_skipped") + "（版本不支持）"
            stepStatuses[TestStep.factoryReset.id] = .skipped
        case .notReady:
            stepResults[TestStep.factoryReset.id] = "恢复出厂: 未连接或特征未就绪"
            stepStatuses[TestStep.factoryReset.id] = .failed
        }
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
    
    /// 用户点击「TESTING.」时终止产测
    private func stopProductionTest() {
        guard isRunning else { return }
        isRunning = false
        currentStepId = nil
        log("用户终止测试", level: .info)
    }
    
    private func runProductionTest() {
        guard !isRunning else { return }
        
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
                while isRunning && !ble.isConnected && waitCount < 100 { // 最多等待10秒
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
                    waitCount += 1
                }
                if !ble.isConnected {
                    log("错误：设备连接失败", level: .error)
                    isRunning = false
                    return
                }
                guard isRunning else { return }
                log("已连接，等待 GATT 特征就绪...", level: .info)
                waitCount = 0
                while isRunning && !ble.areCharacteristicsReady && waitCount < 100 { // 最多再等10秒
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waitCount += 1
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
        initializeStepStatuses()
        
        // 使用当前的测试步骤列表（已从UserDefaults加载）
        let enabledSteps = currentTestSteps.filter { $0.enabled }
        lastTestStartTime = Date()
        
        // 加载版本配置（用于步骤验证）
        let rules = loadTestRules()
        
        self.log("开始产测流程（共 \(enabledSteps.count) 个步骤）", level: .info)
        self.log("——— 产测参数 ———", level: .info)
        self.log("步骤顺序与启用: \(rules.steps.map { "\($0.id)(\($0.enabled ? "开" : "关"))" }.joined(separator: " → "))", level: .info)
        self.log("版本配置: Bootloader=\(rules.bootloaderVersion.isEmpty ? "(空)" : rules.bootloaderVersion), FW=\(rules.firmwareVersion), HW=\(rules.hardwareVersion)", level: .info)
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
        
        /// 由 step2（确认固件版本）设置：FW 不匹配且「若 FW 不匹配则触发 OTA」开启时为 true；step_ota 据此决定是否执行 OTA
        var fwMismatchRequiresOTA = false
        
        for step in enabledSteps {
                guard isRunning else {
                    currentStepId = nil
                    self.log("用户终止测试", level: .info)
                    return
                }
                // 记录步骤开始时的日志索引
                let logStartIndex = testLog.count
                
                // 更新当前步骤状态
                currentStepId = step.id
                stepStatuses[step.id] = .running
                
                // 产测过程中若蓝牙连接丢失，直接报错并终止（仅对需要连接的步骤检查，step1/最后一步断开除外）
                let stepRequiresConnection = (step.id != TestStep.connectDevice.id && step.id != TestStep.disconnectDevice.id)
                if stepRequiresConnection && !ble.isConnected {
                    self.log("错误：蓝牙连接已丢失，产测终止", level: .error)
                    stepResults[step.id] = "蓝牙连接丢失"
                    stepStatuses[step.id] = .failed
                    stepLogRanges[step.id] = (start: logStartIndex, end: testLog.count)
                    currentStepId = nil
                    isRunning = false
                    updateTestResultStatus()
                    return
                }
                
                switch step.id {
                case "step1": // 连接设备：已连接且 GATT 就绪才认为连接完成
                    self.log("步骤1: 连接设备", level: .info)
                    if !ble.isConnected {
                        self.log("错误：未连接", level: .error)
                        stepResults[step.id] = "连接失败：未连接"
                        stepStatuses[step.id] = .failed
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
                            stepResults[step.id] = "连接失败：GATT 未就绪"
                            stepStatuses[step.id] = .failed
                            break
                        }
                    }
                    self.log("已连接，GATT 就绪", level: .info)
                    stepResults[step.id] = appLanguage.string("production_test.connected") + "，GATT 就绪"
                    stepStatuses[step.id] = .passed
                    
                case "step2": // 确认固件版本
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
                    } else {
                        self.log("错误：SN 无效或为空", level: .error)
                        stepStatuses[step.id] = .failed
                        stepResults[step.id] = appLanguage.string("production_test.sn_invalid")
                        await runFactoryResetIfEnabledBeforeExit(enabledSteps: enabledSteps, thresholds: rules.thresholds)
                        isRunning = false
                        currentStepId = nil
                        return
                    }
                    
                    // 验证 Bootloader 版本（小于 2 直接报错）
                    if let blVersionStr = ble.bootloaderVersion {
                        let blNum = Int(blVersionStr.trimmingCharacters(in: .whitespaces))
                        if let num = blNum, num < 2 {
                            self.log("错误：Bootloader 版本过低（当前: \(blVersionStr)，要求 ≥ 2）", level: .error)
                            stepStatuses[step.id] = .failed
                            stepResults[step.id] = resultMessages.joined(separator: "\n") + "\n" + appLanguage.string("production_test.bootloader_too_old")
                            await runFactoryResetIfEnabledBeforeExit(enabledSteps: enabledSteps, thresholds: rules.thresholds)
                            isRunning = false
                            currentStepId = nil
                            return
                        }
                        if !rules.bootloaderVersion.isEmpty {
                            if blVersionStr == rules.bootloaderVersion {
                                self.log("✓ Bootloader 版本验证通过: \(blVersionStr)", level: .info)
                                resultMessages.append("BL: \(blVersionStr)")
                            } else {
                                self.log("警告：Bootloader 版本不匹配（期望: \(rules.bootloaderVersion), 实际: \(blVersionStr)）", level: .warning)
                                resultMessages.append("BL: ⚠️")
                            }
                        } else {
                            resultMessages.append("BL: \(blVersionStr)")
                        }
                    } else {
                        self.log("错误：无法读取 Bootloader 版本", level: .error)
                        stepStatuses[step.id] = .failed
                        stepResults[step.id] = resultMessages.joined(separator: "\n") + "\n" + appLanguage.string("production_test.bootloader_unreadable")
                        await runFactoryResetIfEnabledBeforeExit(enabledSteps: enabledSteps, thresholds: rules.thresholds)
                        isRunning = false
                        currentStepId = nil
                        return
                    }
                    
                    // 验证 FW 版本（仅检查是否需要升级，不在此步执行 OTA；OTA 在「断开前 OTA」步骤执行）
                    if let fwVersion = ble.currentFirmwareVersion {
                        self.log("当前 FW 版本: \(fwVersion)", level: .info)
                        if fwVersion != rules.firmwareVersion {
                            if rules.thresholds.firmwareUpgradeEnabled {
                                fwMismatchRequiresOTA = true
                                self.log("FW 版本不匹配，需要 OTA（期望: \(rules.firmwareVersion), 实际: \(fwVersion)），将在「断开前 OTA」步骤执行", level: .warning, category: "OTA")
                                resultMessages.append("FW: \(fwVersion) → 待OTA")
                                // 提前校验固件管理中是否有目标版本，避免到 OTA 步骤才报错
                                if firmwareManager.url(forVersion: rules.firmwareVersion) == nil {
                                    self.log("错误：未在固件管理中找到版本 \(rules.firmwareVersion) 的固件，请先在「固件」菜单中添加", level: .error, category: "OTA")
                                    stepStatuses[step.id] = .failed
                                    stepResults[step.id] = resultMessages.joined(separator: "\n") + "\n错误：未找到 \(rules.firmwareVersion) 固件（请在固件管理中添加）"
                                    await runFactoryResetIfEnabledBeforeExit(enabledSteps: enabledSteps, thresholds: rules.thresholds)
                                    isRunning = false
                                    currentStepId = nil
                                    return
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
                    
                    // 验证 HW 版本
                    if let hwVersion = ble.deviceHardwareRevision {
                        if hwVersion == rules.hardwareVersion {
                            self.log("✓ HW 版本验证通过: \(hwVersion)", level: .info)
                            resultMessages.append("HW: \(hwVersion) ✓")
                        } else {
                            self.log("警告：HW 版本不匹配（期望: \(rules.hardwareVersion), 实际: \(hwVersion)）", level: .warning)
                            resultMessages.append("HW: \(hwVersion) ⚠️")
                        }
                    } else {
                        // HW 为可选：设备若未实现 GATT 2A27（Hardware Revision String）则无法读取，属正常
                        self.log("HW 版本未提供（设备可能未实现 2A27 特征）", level: .info)
                        resultMessages.append("HW: −")
                    }
                    
                    stepResults[step.id] = resultMessages.joined(separator: "\n")
                    stepStatuses[step.id] = .passed
                    // 缓存设备信息，供产测结束后上传使用（与是否仍连接无关）
                    capturedDeviceSN = ble.deviceSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
                    capturedDeviceName = ble.connectedDeviceName
                    capturedFirmwareVersion = ble.currentFirmwareVersion
                    capturedBootloaderVersion = ble.bootloaderVersion
                    capturedHardwareRevision = ble.deviceHardwareRevision
                    
                case "step3": // 检查 RTC - 步骤1 已保证连接且 GATT 就绪，此处直接读 RTC
                    self.log("步骤3: 检查 RTC", level: .info)
                    
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
                        stepResults[step.id] = "RTC检查失败：无法读取"
                        stepStatuses[step.id] = .failed
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
                            stepResults[step.id] = "RTC: \(deviceRTCString)\n时间差: \(timeDiffString) ✓"
                            stepStatuses[step.id] = .passed
                        } else {
                            stepResults[step.id] = "RTC: \(deviceRTCString)\n时间差: \(timeDiffString) ✗"
                            stepStatuses[step.id] = .failed
                        }
                        capturedRtcDeviceTime = (ble.lastRTCValue.isEmpty || ble.lastRTCValue == "--") ? deviceRTCString : ble.lastRTCValue
                        capturedRtcSystemTime = (ble.lastSystemTimeAtRTCRead.isEmpty || ble.lastSystemTimeAtRTCRead == "--") ? systemTimeString : ble.lastSystemTimeAtRTCRead
                        let diffStr = (ble.lastTimeDiffFromRTCRead.isEmpty || ble.lastTimeDiffFromRTCRead == "--") ? timeDiffString : ble.lastTimeDiffFromRTCRead
                        capturedRtcTimeDiffSeconds = (diffStr != "--" ? parseTimeDiff(diffStr) : nil)
                    }
                    
                case "step4": // 读取压力值 - 复用debug mode的方法，并验证阈值
                    self.log("步骤4: 读取压力值", level: .info)
                    
                    let pressureClosedMin = rules.thresholds.pressureClosedMin
                    let pressureClosedMax = rules.thresholds.pressureClosedMax
                    let pressureOpenMin = rules.thresholds.pressureOpenMin
                    let pressureOpenMax = rules.thresholds.pressureOpenMax
                    
                    // 读取关闭状态压力（复用debug mode的readPressure方法）
                    self.log("读取关闭状态压力...", level: .info)
                    ble.readPressure()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let closedPressureStr = ble.lastPressureValue
                    if closedPressureStr.isEmpty || closedPressureStr == "--" {
                        self.log("警告：关闭压力读取失败或为空", level: .warning)
                    } else {
                        self.log("关闭压力: \(closedPressureStr)", level: .info)
                    }
                    
                    // 解析关闭压力值（格式：X.XXX bar）
                    var closedPressureValue: Double? = nil
                    if let barRange = closedPressureStr.range(of: "bar") {
                        let valueStr = String(closedPressureStr[..<barRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                        closedPressureValue = Double(valueStr)
                    }
                    
                    // 打开阀门（复用BLEManager的setValve方法，与debug mode一致）
                    self.log("打开阀门...", level: .info)
                    ble.setValve(open: true)
                    // setValve内部已经等待0.5秒并读取状态，但为了确保压力读取准确，再等待一下
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    
                    // 检查阀门状态
                    if ble.lastValveStateValue == "open" {
                        self.log("阀门已打开", level: .info)
                    } else {
                        self.log("警告：阀门状态异常（当前: \(ble.lastValveStateValue)）", level: .warning)
                    }
                    
                    // 读取开启状态压力（复用debug mode的readPressureOpen方法）
                    self.log("读取开启状态压力...", level: .info)
                    ble.readPressureOpen()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let openPressureStr = ble.lastPressureOpenValue
                    if openPressureStr.isEmpty || openPressureStr == "--" {
                        self.log("警告：开启压力读取失败或为空", level: .warning)
                    } else {
                        self.log("开启压力: \(openPressureStr)", level: .info)
                    }
                    
                    // 解析开启压力值（格式：X.XXX bar）
                    var openPressureValue: Double? = nil
                    if let barRange = openPressureStr.range(of: "bar") {
                        let valueStr = String(openPressureStr[..<barRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                        openPressureValue = Double(valueStr)
                    }
                    
                    // 验证压力值（转换为mbar进行比较：1 bar = 1000 mbar）
                    var pressurePassed = true
                    var pressureMessages: [String] = []
                    
                    if let closedBar = closedPressureValue {
                        let closedMbar = closedBar * 1000.0
                        if closedMbar >= pressureClosedMin && closedMbar <= pressureClosedMax {
                            self.log("✓ 关闭压力验证通过: \(closedMbar) mbar（\(pressureClosedMin)~\(pressureClosedMax) mbar）", level: .info)
                            pressureMessages.append("关闭: \(closedPressureStr) ✓")
                        } else {
                            self.log("✗ 关闭压力验证失败: \(closedMbar) mbar（应在 \(pressureClosedMin)~\(pressureClosedMax) mbar）", level: .error)
                            pressureMessages.append("关闭: \(closedPressureStr) ✗")
                            pressurePassed = false
                        }
                    } else {
                        self.log("警告：无法解析关闭压力值", level: .warning)
                        pressureMessages.append("关闭: \(closedPressureStr) ⚠️")
                        pressurePassed = false
                    }
                    
                    if let openBar = openPressureValue {
                        let openMbar = openBar * 1000.0
                        if openMbar >= pressureOpenMin && openMbar <= pressureOpenMax {
                            self.log("✓ 开启压力验证通过: \(openMbar) mbar（\(pressureOpenMin)~\(pressureOpenMax) mbar）", level: .info)
                            pressureMessages.append("开启: \(openPressureStr) ✓")
                        } else {
                            self.log("✗ 开启压力验证失败: \(openMbar) mbar（应在 \(pressureOpenMin)~\(pressureOpenMax) mbar）", level: .error)
                            pressureMessages.append("开启: \(openPressureStr) ✗")
                            pressurePassed = false
                        }
                    } else {
                        self.log("警告：无法解析开启压力值", level: .warning)
                        pressureMessages.append("开启: \(openPressureStr) ⚠️")
                        pressurePassed = false
                    }
                    
                    // 压力差值检查（如果启用）：差值需在 [pressureDiffMin, pressureDiffMax] 范围内
                    if rules.thresholds.pressureDiffCheckEnabled {
                        if let closedMbar = closedPressureValue.map({ $0 * 1000.0 }),
                           let openMbar = openPressureValue.map({ $0 * 1000.0 }) {
                            let diff = abs(openMbar - closedMbar)
                            let diffMin = rules.thresholds.pressureDiffMin
                            let diffMax = rules.thresholds.pressureDiffMax
                            if diff >= diffMin && diff <= diffMax {
                                self.log("✓ 压力差值验证通过: \(String(format: "%.0f", diff)) mbar（\(Int(diffMin))~\(Int(diffMax)) mbar）", level: .info)
                                pressureMessages.append("差值: \(String(format: "%.0f", diff)) mbar ✓")
                            } else {
                                self.log("✗ 压力差值验证失败: \(String(format: "%.0f", diff)) mbar（应在 \(Int(diffMin))~\(Int(diffMax)) mbar）", level: .error)
                                pressureMessages.append("差值: \(String(format: "%.0f", diff)) mbar ✗")
                                pressurePassed = false
                            }
                        } else {
                            self.log("警告：无法计算压力差值（缺少压力值）", level: .warning)
                            pressureMessages.append("差值: 无法计算 ⚠️")
                            pressurePassed = false
                        }
                    }
                    
                    stepResults[step.id] = pressureMessages.joined(separator: "\n")
                    stepStatuses[step.id] = pressurePassed ? .passed : .failed
                    capturedPressureClosedMbar = closedPressureValue.map { $0 * 1000.0 }
                    capturedPressureOpenMbar = openPressureValue.map { $0 * 1000.0 }
                    
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
                        stepResults[step.id] = "Gas system status: 读取超时或无效"
                        stepStatuses[step.id] = .failed
                    } else {
                        self.log("Gas system status 读取值: \(gasStatusStr)", level: .info)
                        // 解码：1 = ok 为通过，其余均为失败
                        let isOk = gasStatusStr.hasPrefix("1 (ok)")
                        if isOk {
                            self.log("✓ Gas system status 验证通过: \(gasStatusStr)", level: .info)
                            stepResults[step.id] = "Gas system status: \(gasStatusStr) ✓"
                            stepStatuses[step.id] = .passed
                        } else {
                            self.log("Gas system status 检查失败: \(gasStatusStr)，期望 1 (ok)", level: .error)
                            stepResults[step.id] = "Gas system status: \(gasStatusStr)，期望 1 (ok)"
                            stepStatuses[step.id] = .failed
                        }
                        capturedGasSystemStatus = gasStatusStr.isEmpty || gasStatusStr == "--" ? nil : gasStatusStr
                    }
                    
                case "step_valve": // 确保电磁阀是开启的
                    self.log("步骤: 确保电磁阀是开启的", level: .info)
                    let valveOpened = await ensureValveOpen()
                    if valveOpened {
                        stepResults[step.id] = appLanguage.string("production_test_rules.step_valve_criteria")
                        stepStatuses[step.id] = .passed
                        capturedValveState = ble.lastValveStateValue
                    } else {
                        self.log("电磁阀打开失败或超时", level: .error)
                        stepResults[step.id] = "电磁阀: 打开失败或超时"
                        stepStatuses[step.id] = .failed
                    }
                    
                case "step_reset": // 重启设备（Testing 0x00000001）
                    self.log("步骤: 重启设备", level: .info)
                    let result = await ble.sendTestingRebootCommand()
                    switch result {
                    case .sent:
                        stepResults[step.id] = appLanguage.string("production_test_rules.step_reset_criteria")
                        stepStatuses[step.id] = .passed
                        _ = await reconnectAfterTestingReboot(rules: rules.thresholds)
                    case .timeout:
                        self.log("警告：重启命令已发送但未在约定时间内确认断开", level: .warning)
                        stepResults[step.id] = appLanguage.string("production_test_rules.step_reset_criteria") + "（未确认断开）"
                        stepStatuses[step.id] = .passed
                        _ = await reconnectAfterTestingReboot(rules: rules.thresholds)
                    case .rejectedByVersion:
                        self.log("固件版本不支持重启命令，步骤跳过", level: .warning)
                        stepResults[step.id] = appLanguage.string("production_test.overlay_step_skipped") + "（版本不支持）"
                        stepStatuses[step.id] = .skipped
                    case .notReady:
                        stepResults[step.id] = "重启: 未连接或特征未就绪"
                        stepStatuses[step.id] = .failed
                    }
                    
                case "step_factory_reset": // 恢复出厂（Testing 0x00000002）；重连若得到「Peer removed pairing」则判定恢复出厂成功
                    self.log("步骤: 恢复出厂设置", level: .info)
                    let result = await ble.sendTestingFactoryResetCommand()
                    switch result {
                    case .sent:
                        stepStatuses[step.id] = .passed
                        let reconnectResult = await reconnectAfterTestingReboot(rules: rules.thresholds, expectPairingRemoved: true)
                        switch reconnectResult {
                        case .reconnected, .skipped:
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria")
                        case .timeout(pairingRemoved: true):
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_confirmed_pairing_removed")
                        case .timeout(pairingRemoved: false):
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria")
                        }
                    case .timeout:
                        self.log("警告：恢复出厂命令已发送但未在约定时间内确认断开", level: .warning)
                        stepStatuses[step.id] = .passed
                        let reconnectResult = await reconnectAfterTestingReboot(rules: rules.thresholds, expectPairingRemoved: true)
                        switch reconnectResult {
                        case .reconnected, .skipped:
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria") + "（未确认断开）"
                        case .timeout(pairingRemoved: true):
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_confirmed_pairing_removed")
                        case .timeout(pairingRemoved: false):
                            stepResults[step.id] = appLanguage.string("production_test_rules.step_factory_reset_criteria") + "（未确认断开）"
                        }
                    case .rejectedByVersion:
                        self.log("固件版本不支持恢复出厂命令，步骤跳过", level: .warning)
                        stepResults[step.id] = appLanguage.string("production_test.overlay_step_skipped") + "（版本不支持）"
                        stepStatuses[step.id] = .skipped
                    case .notReady:
                        stepResults[step.id] = "恢复出厂: 未连接或特征未就绪"
                        stepStatuses[step.id] = .failed
                    }
                    
                case "step_ota": // 断开连接前 OTA（是否执行由 step2 的「若 FW 不匹配则触发 OTA」+ FW 比对结果决定；OTA 步骤始终在 SOP 中，无法由用户单独关闭）
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
                        break
                    }
                    
                    // 产测按 SOP 期望版本从固件管理中选择目标固件
                    guard let otaURL = firmwareManager.url(forVersion: rules.firmwareVersion) else {
                        self.log("错误：未在固件管理中找到版本 \(rules.firmwareVersion) 的固件，请先在「固件」菜单中添加", level: .error, category: "OTA")
                        stepStatuses[step.id] = .failed
                        stepResults[step.id] = "OTA: 未找到 \(rules.firmwareVersion) 固件（请在固件管理中添加）"
                        break
                    }
                    // 产测：由规则决定是否跳过（当前已是目标版本则跳过）；OTA 只接收 URL 执行，不做版本比对
                    if let currentFw = ble.currentFirmwareVersion, currentFw == rules.firmwareVersion {
                        self.log("固件版本已与期望一致（\(currentFw)），跳过 OTA", level: .info, category: "OTA")
                        stepResults[step.id] = "OTA: 已跳过（FW \(currentFw) ✓）"
                        stepStatuses[step.id] = .passed
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
                        stepResults[step.id] = "OTA: \(reason)"
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
                            stepResults[step.id] = "OTA: 启动超时（\(reason)）"
                        } else {
                            stepResults[step.id] = "OTA: 启动超时"
                        }
                        stepStatuses[step.id] = .failed
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
                        stepResults[step.id] = "OTA: 失败或已取消"
                        break
                    }
                    
                    if ble.otaProgress >= 1.0 && !ble.isOTAFailed {
                        self.log("OTA 传输完成", level: .info, category: "OTA")
                        stepResults[step.id] = "OTA: 完成 ✓"
                        stepStatuses[step.id] = .passed
                    } else {
                        self.log("错误：OTA 未完成", level: .error, category: "OTA")
                        needRetestAfterOtaReboot = false
                        stepStatuses[step.id] = .failed
                        stepResults[step.id] = "OTA: 未完成"
                        break
                    }
                    
                case "step5": // 待定
                    self.log("步骤5: 待定步骤（跳过）", level: .info)
                    stepStatuses[step.id] = .skipped
                    
                case "step_disconnect": // 安全断开连接（阀门状态已在「确保电磁阀是开启的」步骤中确认，此处仅执行断开）
                    self.log("最后步骤: 安全断开连接", level: .info)
                    
                    if ble.isOTARebootDisconnected {
                        // 设备已因 OTA 重启断开，断开步骤直接视为通过
                        self.log("设备已因 OTA 重启断开，断开步骤视为通过", level: .info)
                        stepResults[step.id] = appLanguage.string("production_test.disconnected_after_ota")
                        stepStatuses[step.id] = .passed
                    } else {
                        self.log("断开连接...", level: .info)
                        ble.disconnect()
                        try? await Task.sleep(nanoseconds: 1000_000_000)
                        self.log("已断开连接", level: .info)
                        stepResults[step.id] = appLanguage.string("production_test.disconnected")
                        stepStatuses[step.id] = .passed
                    }
                    
                default:
                    self.log("未知步骤: \(step.id)", level: .error)
                    stepStatuses[step.id] = .failed
                }
                
                // 记录步骤结束时的日志索引
                let logEndIndex = testLog.count
                stepLogRanges[step.id] = (start: logStartIndex, end: logEndIndex)
                
                // 清除当前步骤标记
                currentStepId = nil
                
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
        // 无论通过或失败，均在日志区输出完整报表，便于主日志区按等级过滤查看
        emitProductionTestReport(enabledSteps: enabledSteps)
        
        // 若已开启「上传至服务器」，则异步上报本次产测结果
        if serverSettings.uploadToServerEnabled {
            Task { await uploadProductionTestResultIfNeeded(enabledSteps: enabledSteps) }
        }
        
        isRunning = false
        currentStepId = nil
        // 更新测试结果状态
        updateTestResultStatus()
        // 显示结果 overlay（绿/红弹窗报表）
        lastTestEndTime = Date()
        showResultOverlay = true
    }
    
    /// 若「上传至服务器」已开启，将本次产测结果 POST 到服务器（使用产测过程中缓存的设备信息，与当前是否连接无关）
    private func uploadProductionTestResultIfNeeded(enabledSteps: [TestStep]) async {
        guard serverSettings.uploadToServerEnabled,
              let url = serverSettings.productionTestReportURL else { return }
        let sn = (capturedDeviceSN ?? ble.deviceSerialNumber)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sn.isEmpty else {
            self.log("上传跳过：无设备 SN（步骤2 未通过或未执行）", level: .warning)
            return
        }
        let endTime = lastTestEndTime ?? Date()
        let startTime = lastTestStartTime ?? endTime
        let durationSeconds = endTime.timeIntervalSince(startTime)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startTimeStr = isoFormatter.string(from: startTime)
        let endTimeStr = isoFormatter.string(from: endTime)
        let stepsSummary: [[String: String]] = enabledSteps.map { step in
            let status: String
            switch stepStatuses[step.id] ?? .pending {
            case .passed: status = "passed"
            case .failed: status = "failed"
            case .skipped: status = "skipped"
            case .pending, .running: status = "pending"
            }
            return ["stepId": step.id, "status": status]
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
        if !stepResults.isEmpty {
            body["stepResults"] = stepResults
        }
        var testDetails: [String: Any] = [:]
        if let v = capturedRtcDeviceTime { testDetails["rtcDeviceTime"] = v }
        if let v = capturedRtcSystemTime { testDetails["rtcSystemTime"] = v }
        if let v = capturedRtcTimeDiffSeconds { testDetails["rtcTimeDiffSeconds"] = v }
        if let v = capturedPressureClosedMbar { testDetails["pressureClosedMbar"] = v }
        if let v = capturedPressureOpenMbar { testDetails["pressureOpenMbar"] = v }
        if let v = capturedGasSystemStatus { testDetails["gasSystemStatus"] = v }
        if let v = capturedValveState { testDetails["valveState"] = v }
        if !testDetails.isEmpty { body["testDetails"] = testDetails }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30
        let maxAttempts = 3
        let retryDelaySeconds: UInt64 = 2
        self.log("正在上传产测结果至服务器（后台）…", level: .info)
        for attempt in 1...maxAttempts {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    self.log("产测结果已上传至服务器", level: .info)
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                // 4xx 视为不可重试，直接落盘并结束
                if (400..<500).contains(code) {
                    self.log("上传失败：服务器返回 \(code)（客户端错误），不重试；结果已写入本地，下次启动将自动重传", level: .error)
                    serverSettings.savePendingUpload(body: body)
                    return
                }
                // 5xx 或其它可重试
                if attempt < maxAttempts {
                    self.log("上传服务器返回 \(code)，\(retryDelaySeconds) 秒后重试（\(attempt)/\(maxAttempts)）", level: .warning)
                    try? await Task.sleep(nanoseconds: retryDelaySeconds * 1_000_000_000)
                } else {
                    self.log("上传服务器返回 \(code)，已重试 \(maxAttempts) 次；结果已写入本地，下次启动将自动重传", level: .error)
                    serverSettings.savePendingUpload(body: body)
                }
            } catch {
                let retriable = Self.isRetriableNetworkError(error)
                if retriable && attempt < maxAttempts {
                    self.log("上传失败（\(attempt)/\(maxAttempts)）: \(error.localizedDescription)，\(retryDelaySeconds) 秒后重试", level: .warning)
                    try? await Task.sleep(nanoseconds: retryDelaySeconds * 1_000_000_000)
                } else {
                    if !retriable {
                        self.log("上传失败（不可重试）: \(error.localizedDescription)；结果已写入本地，下次启动将自动重传", level: .error)
                    } else {
                        self.log("上传失败（已重试 \(maxAttempts) 次）: \(error.localizedDescription)；结果已写入本地，下次启动将自动重传", level: .error)
                    }
                    serverSettings.savePendingUpload(body: body)
                    return
                }
            }
        }
    }

    /// 仅对超时、连接错误等可重试错误返回 true；4xx 由上层根据 statusCode 判断；非 URLError 视为不可重试
    private static func isRetriableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed, .resourceUnavailable,
             .internationalRoamingOff, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
    
    /// 产测结束时生成报表并写入日志区，按步骤结果使用不同 log 等级（通过=info、失败=error、跳过=warning）
    private func emitProductionTestReport(enabledSteps: [TestStep]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_POSIX")
        let timeStr = formatter.string(from: Date())
        
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
        if needRetest { return Color(nsColor: .systemRed) }
        return passed ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed)
    }
    
    private func rowColor(ok: Bool, isWarning: Bool) -> Color {
        if !ok { return Color(nsColor: .systemRed) }
        if isWarning { return Color(nsColor: .systemOrange) }
        return Color(nsColor: .systemGreen)
    }
    
    /// 较深的背景色，用于每行通过/失败/警告的底色（比 system 色 + 低透明度更醒目）
    private func rowBackgroundColor(ok: Bool, isWarning: Bool) -> Color {
        if !ok { return Color(red: 0.85, green: 0.25, blue: 0.22) }   // 深红
        if isWarning { return Color(red: 0.9, green: 0.55, blue: 0.2) } // 深橙
        return Color(red: 0.22, green: 0.6, blue: 0.35)                 // 深绿
    }
    
    /// Close 按钮使用的深色（通过=深绿，失败/需要重测=深红）
    private var closeButtonColor: Color {
        if needRetest { return Color(red: 0.7, green: 0.18, blue: 0.18) }
        return passed ? Color(red: 0.15, green: 0.5, blue: 0.25) : Color(red: 0.7, green: 0.18, blue: 0.18)
    }
    
    var body: some View {
        ZStack {
            // 半透明遮罩：仅覆盖主功能区，不参与命中测试
            Color.black.opacity(0.3)
                .allowsHitTesting(false)
            
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
                .frame(minWidth: 320, maxWidth: 440)
                .background(Color(NSColor.windowBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 16, x: 0, y: 8)
            .allowsHitTesting(true)
            .contentShape(RoundedRectangle(cornerRadius: 12))
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
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(UIDesignSystem.Padding.lg)
        .frame(minWidth: 360)
    }
}
