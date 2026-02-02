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
    /// 最近一次产测结束时间（用于 overlay 报表显示）
    @State private var lastTestEndTime: Date?
    
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

            // 测试结果摘要卡片 - 根据测试结果更新颜色
            testResultSummaryCard
            
            // 控制按钮区域
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                Spacer(minLength: UIDesignSystem.Spacing.lg)
                Button(action: runProductionTest) {
                    HStack(spacing: UIDesignSystem.Spacing.sm) {
                        if isRunning {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(.white)
                        } else {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                        }
                        Text(isRunning ? appLanguage.string("production_test.running") : appLanguage.string("production_test.start"))
                            .fontWeight(.semibold)
                    }
                    .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                    .foregroundColor(.white)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRunning || ble.isOTAInProgress)
                .shadow(color: .blue.opacity(0.3), radius: 4, x: 0, y: 2)
            }
            
            // 产测 OTA 由主窗口 overlay 接管时不再在此处显示 inline 区域（避免重复）
            if (ble.isOTAInProgress || ble.isOTACompletedWaitingReboot || ble.isOTAFailed || ble.isOTACancelled || ble.isOTARebootDisconnected) && !ble.otaInitiatedByProductionTest {
                productionTestOTAArea
            }
            
            // 测试步骤功能区 - 垂直滚动布局
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
                }
                .frame(maxHeight: 400) // 限制最大高度，超出可滚动
            }
            .padding(UIDesignSystem.Padding.sm)
            .background(
                LinearGradient(
                    colors: [Color.secondary.opacity(0.05), Color.secondary.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(UIDesignSystem.CornerRadius.sm)

            // 未连接时提示；产测日志统一在主日志区查看，此处不再展示 test log
            if !ble.isConnected {
                HStack {
                    Spacer()
                    VStack(spacing: UIDesignSystem.Spacing.sm) {
                        Image(systemName: "link.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(appLanguage.string("production_test.connect_first"))
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, UIDesignSystem.Padding.lg)
            }
        }
        .padding(UIDesignSystem.Padding.md)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    
                    // 相关日志
                    if let logRange = stepLogRanges[step.id] {
                        let stepLogs = Array(testLog[logRange.start..<min(logRange.end, testLog.count)])
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
    
    /// 测试结果摘要卡片 - 根据测试结果更新颜色和内容
    private var testResultSummaryCard: some View {
        let enabledSteps = currentTestSteps.filter { $0.enabled }
        let passedCount = enabledSteps.filter { stepStatuses[$0.id] == .passed }.count
        let failedCount = enabledSteps.filter { stepStatuses[$0.id] == .failed }.count
        let skippedCount = enabledSteps.filter { stepStatuses[$0.id] == .skipped }.count
        let runningCount = enabledSteps.filter { stepStatuses[$0.id] == .running }.count
        
        // 根据测试结果状态确定颜色
        let (bgColors, iconColor, iconName): ([Color], Color, String) = {
            switch testResultStatus {
            case .notStarted:
                return ([Color.blue.opacity(0.1), Color.purple.opacity(0.05)], .blue, "list.bullet.clipboard")
            case .running:
                return ([Color.orange.opacity(0.1), Color.yellow.opacity(0.05)], .orange, "hourglass")
            case .allPassed:
                return ([Color.green.opacity(0.15), Color.green.opacity(0.05)], .green, "checkmark.seal.fill")
            case .partialPassed:
                return ([Color.orange.opacity(0.15), Color.yellow.opacity(0.05)], .orange, "exclamationmark.triangle.fill")
            case .allFailed:
                return ([Color.red.opacity(0.15), Color.red.opacity(0.05)], .red, "xmark.circle.fill")
            }
        }()
        
        return VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                Text(appLanguage.string("production_test.test_result_summary"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            
            HStack(spacing: UIDesignSystem.Spacing.md) {
                // 版本信息（仅在未开始或进行中时显示）
                if testResultStatus == .notStarted || testResultStatus == .running {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(testRules.firmwareVersion.isEmpty ? "—" : testRules.firmwareVersion, systemImage: "number.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(testRules.hardwareVersion, systemImage: "cpu.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // 测试完成后显示测试结果统计
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                                Text("\(passedCount)")
                                    .font(.caption.weight(.semibold))
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                Text("\(failedCount)")
                                    .font(.caption.weight(.semibold))
                            }
                            if skippedCount > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.gray)
                                        .font(.caption)
                                    Text("\(skippedCount)")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                        }
                        Text(appLanguage.string("production_test.test_results"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                // 步骤统计
                VStack(alignment: .trailing, spacing: 4) {
                    if testResultStatus == .notStarted || testResultStatus == .running {
                        HStack(spacing: 4) {
                            Image(systemName: runningCount > 0 ? "hourglass" : "checkmark.circle.fill")
                                .foregroundStyle(runningCount > 0 ? .orange : .green)
                                .font(.caption)
                            Text("\(testRules.enabledStepsCount)")
                                .font(.caption.weight(.semibold))
                        }
                        Text(appLanguage.string("production_test.enabled_steps"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        // 测试完成后显示通过率
                        HStack(spacing: 4) {
                            Image(systemName: testResultStatus == .allPassed ? "checkmark.seal.fill" : testResultStatus == .allFailed ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(iconColor)
                                .font(.caption)
                            Text("\(passedCount)/\(enabledSteps.count)")
                                .font(.caption.weight(.semibold))
                        }
                        Text(appLanguage.string("production_test.passed_steps"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(
            LinearGradient(
                colors: bgColors,
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .cornerRadius(UIDesignSystem.CornerRadius.sm)
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
        let connectOk = !enabled.contains(where: { $0.id == TestStep.connectDevice.id }) || stepStatuses[TestStep.connectDevice.id] == .passed
        let rtcOk = !enabled.contains(where: { $0.id == TestStep.readRTC.id }) || stepStatuses[TestStep.readRTC.id] == .passed
        let fwStepEnabled = enabled.contains(where: { $0.id == TestStep.verifyFirmware.id })
        let otaStepEnabled = enabled.contains(where: { $0.id == TestStep.otaBeforeDisconnect.id })
        let fwOk: Bool
        if !fwStepEnabled {
            fwOk = true
        } else if stepStatuses[TestStep.verifyFirmware.id] == .passed {
            fwOk = true
        } else if otaStepEnabled, stepStatuses[TestStep.otaBeforeDisconnect.id] == .passed {
            fwOk = true // FW 不一致但 OTA 成功
        } else {
            fwOk = false
        }
        let pressureOk = !enabled.contains(where: { $0.id == TestStep.readPressure.id }) || stepStatuses[TestStep.readPressure.id] == .passed
        let gasSystemStatusOk = !enabled.contains(where: { $0.id == TestStep.readGasSystemStatus.id }) || stepStatuses[TestStep.readGasSystemStatus.id] == .passed
        let valveOk = !enabled.contains(where: { $0.id == TestStep.ensureValveOpen.id }) || stepStatuses[TestStep.ensureValveOpen.id] == .passed
        return connectOk && rtcOk && fwOk && pressureOk && gasSystemStatusOk && valveOk
    }
    
    /// 用于 overlay 报表的判定项列表：(名称, 是否通过)
    private var overallTestCriteria: [(name: String, ok: Bool)] {
        let enabled = currentTestSteps.filter { $0.enabled }
        var list: [(String, Bool)] = []
        if enabled.contains(where: { $0.id == TestStep.connectDevice.id }) {
            list.append((appLanguage.string("production_test_rules.step1_title"), stepStatuses[TestStep.connectDevice.id] == .passed))
        }
        if enabled.contains(where: { $0.id == TestStep.readRTC.id }) {
            list.append((appLanguage.string("production_test_rules.step3_title"), stepStatuses[TestStep.readRTC.id] == .passed))
        }
        if enabled.contains(where: { $0.id == TestStep.verifyFirmware.id }) {
            let fwPass = stepStatuses[TestStep.verifyFirmware.id] == .passed
            let otaPass = enabled.contains(where: { $0.id == TestStep.otaBeforeDisconnect.id }) && stepStatuses[TestStep.otaBeforeDisconnect.id] == .passed
            list.append((appLanguage.string("production_test.result_criteria_fw"), fwPass || otaPass))
        }
        if enabled.contains(where: { $0.id == TestStep.readPressure.id }) {
            list.append((appLanguage.string("production_test_rules.step4_title"), stepStatuses[TestStep.readPressure.id] == .passed))
        }
        if enabled.contains(where: { $0.id == TestStep.readGasSystemStatus.id }) {
            list.append((appLanguage.string("production_test_rules.step_gas_system_status_title"), stepStatuses[TestStep.readGasSystemStatus.id] == .passed))
        }
        if enabled.contains(where: { $0.id == TestStep.ensureValveOpen.id }) {
            list.append((appLanguage.string("production_test_rules.step_valve_title"), stepStatuses[TestStep.ensureValveOpen.id] == .passed))
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
        // 加载步骤顺序和启用状态（含断开前 OTA、确保电磁阀开启等步骤）
        let stepMap = [TestStep.connectDevice, .verifyFirmware, .readRTC, .readPressure, .readGasSystemStatus, .tbd, .ensureValveOpen, .otaBeforeDisconnect, .disconnectDevice]
            .reduce(into: [:]) { $0[$1.id] = $1 }
        
        var steps: [TestStep] = []
        if let saved = UserDefaults.standard.array(forKey: "production_test_steps_order") as? [String] {
            for id in saved {
                if let step = stepMap[id] {
                    steps.append(step)
                }
            }
        } else {
            steps = [.connectDevice, .verifyFirmware, .readRTC, .readPressure, .readGasSystemStatus, .ensureValveOpen, .tbd, .otaBeforeDisconnect, .disconnectDevice]
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
        
        // 加载每个步骤的启用状态
        if let enabledDict = UserDefaults.standard.dictionary(forKey: "production_test_steps_enabled") as? [String: Bool] {
            for i in 0..<steps.count {
                if let enabled = enabledDict[steps[i].id] {
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
    
    /// 确保电磁阀处于 OPEN 状态：先读取状态，已开启则直接通过；否则发送开启命令后等待，超时 5s（可配置）。
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
    
    private func runProductionTest() {
        guard !isRunning else { return }
        
        // 检查是否有选中的设备
        guard let selectedDeviceId = ble.selectedDeviceId,
              let device = ble.discoveredDevices.first(where: { $0.id == selectedDeviceId }) else {
            // 没有选中设备，提示用户
            testLog.removeAll()
            stepIndex = 0
            log("错误：请先选中设备", level: .error)
            return
        }
        
        // 如果未连接，先连接设备
        if !ble.isConnected {
            showResultOverlay = false
            ble.clearLog()
            isRunning = true
            testLog.removeAll()
            stepIndex = 0
            log("正在连接设备: \(device.name)...", level: .info)
            ble.connect(to: device)
            
            // 等待连接完成，且 GATT 特征就绪（发现服务/特征需要时间），才认为连接完成
            Task { @MainActor in
                var waitCount = 0
                while !ble.isConnected && waitCount < 100 { // 最多等待10秒
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
                    waitCount += 1
                }
                if !ble.isConnected {
                    log("错误：设备连接失败", level: .error)
                    isRunning = false
                    return
                }
                log("已连接，等待 GATT 特征就绪...", level: .info)
                waitCount = 0
                while !ble.areCharacteristicsReady && waitCount < 100 { // 最多再等10秒
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waitCount += 1
                }
                if !ble.areCharacteristicsReady {
                    log("错误：连接后 GATT 特征未就绪（10秒）", level: .error)
                    isRunning = false
                    return
                }
                log("GATT 就绪，开始产测", level: .info)
                await executeProductionTest()
            }
        } else {
            // 已连接，直接执行产测流程
            showResultOverlay = false
            ble.clearLog()
            isRunning = true
            testLog.removeAll()
            stepIndex = 0
            stepResults.removeAll()
            initializeStepStatuses()
            
            Task { @MainActor in
                await executeProductionTest()
            }
        }
    }
    
    private func executeProductionTest() async {
        // 确保状态已初始化（使用最新的步骤列表）
        stepResults.removeAll()
        stepLogRanges.removeAll()
        expandedSteps.removeAll()
        initializeStepStatuses()
        
        // 使用当前的测试步骤列表（已从UserDefaults加载）
        let enabledSteps = currentTestSteps.filter { $0.enabled }
        
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
                        while !ble.areCharacteristicsReady && charWaitCount < maxCharWait {
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
                    while (ble.deviceSerialNumber == nil || ble.currentFirmwareVersion == nil || ble.deviceHardwareRevision == nil) && waitCount < maxWaitCount {
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
                        isRunning = false
                        currentStepId = nil
                        return
                    }
                    
                    // 验证 Bootloader 版本
                    if !rules.bootloaderVersion.isEmpty {
                        if let blVersion = ble.bootloaderVersion, blVersion == rules.bootloaderVersion {
                            self.log("✓ Bootloader 版本验证通过: \(blVersion)", level: .info)
                            resultMessages.append("BL: \(blVersion)")
                        } else {
                            self.log("警告：Bootloader 版本不匹配（期望: \(rules.bootloaderVersion), 实际: \(ble.bootloaderVersion ?? "未知")）", level: .warning)
                            resultMessages.append("BL: ⚠️")
                        }
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
                                    isRunning = false
                                    currentStepId = nil
                                    return
                                }
                            } else {
                                // 固件升级已禁用，仅记录警告
                                self.log("警告：FW 版本不匹配，但固件升级已禁用（期望: \(rules.firmwareVersion), 实际: \(fwVersion)）", level: .warning)
                                resultMessages.append("FW: \(fwVersion) ⚠️ (升级已禁用)")
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
                    while (ble.lastRTCValue.isEmpty || ble.lastRTCValue == "--") && waitCount < maxRtcWaitCount {
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
                                    while (ble.lastRTCValue.isEmpty || ble.lastRTCValue == "--") && waitCount < maxRtcWaitCount {
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
                        
                        // 更新步骤结果和状态
                        if rtcPassed {
                            stepResults[step.id] = "RTC: \(deviceRTCString)\n时间差: \(timeDiffString) ✓"
                            stepStatuses[step.id] = .passed
                        } else {
                            stepResults[step.id] = "RTC: \(deviceRTCString)\n时间差: \(timeDiffString) ✗"
                            stepStatuses[step.id] = .failed
                        }
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
                    
                case "step_gas_system_status": // 读取 Gas system status，解码后须为 1 (ok)
                    self.log("步骤: 读取 Gas system status", level: .info)
                    ble.readGasSystemStatus()
                    let gasStatusTimeoutSeconds = rules.thresholds.deviceInfoReadTimeout
                    let maxGasStatusWaitCount = Int(gasStatusTimeoutSeconds * 10)
                    var gasStatusWaitCount = 0
                    while (ble.lastGasSystemStatusValue.isEmpty || ble.lastGasSystemStatusValue == "--") && gasStatusWaitCount < maxGasStatusWaitCount {
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
                    }
                    
                case "step_valve": // 确保电磁阀是开启的
                    self.log("步骤: 确保电磁阀是开启的", level: .info)
                    let valveOpened = await ensureValveOpen()
                    if valveOpened {
                        stepResults[step.id] = appLanguage.string("production_test_rules.step_valve_criteria")
                        stepStatuses[step.id] = .passed
                    } else {
                        self.log("电磁阀打开失败或超时", level: .error)
                        stepResults[step.id] = "电磁阀: 打开失败或超时"
                        stepStatuses[step.id] = .failed
                    }
                    
                case "step_ota": // 断开连接前 OTA（是否执行由 step2 的「若 FW 不匹配则触发 OTA」+ FW 比对结果决定；OTA 步骤始终在 SOP 中，无法由用户单独关闭）
                    self.log("步骤: 断开前 OTA", level: .info, category: "OTA")
                    
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
                    
                    self.log("使用已选固件，启动 OTA", level: .info, category: "OTA")
                    if let reason = ble.startOTA(firmwareURL: otaURL, initiatedByProductionTest: true) {
                        self.log("错误：OTA 未启动（\(reason)）", level: .error, category: "OTA")
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
            
        // 统计测试结果
        let passedCount = enabledSteps.filter { stepStatuses[$0.id] == .passed }.count
        let failedCount = enabledSteps.filter { stepStatuses[$0.id] == .failed }.count
        let skippedCount = enabledSteps.filter { stepStatuses[$0.id] == .skipped }.count
        
        self.log("产测流程结束", level: .info)
        self.log("测试结果统计：通过 \(passedCount)，失败 \(failedCount)，跳过 \(skippedCount)，总计 \(enabledSteps.count)", level: .info)
        
        // 无论通过或失败，均在日志区输出完整报表，便于主日志区按等级过滤查看
        emitProductionTestReport(enabledSteps: enabledSteps)
        
        isRunning = false
        currentStepId = nil
        // 更新测试结果状态
        updateTestResultStatus()
        // 显示结果 overlay（绿/红弹窗报表）
        lastTestEndTime = Date()
        showResultOverlay = true
    }
    
    /// 产测成功结束时生成报表并写入日志区，所有行使用 .info 等级
    private func emitProductionTestReport(enabledSteps: [TestStep]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_POSIX")
        let timeStr = formatter.string(from: Date())
        
        self.log("────────── 产测报表 ──────────", level: .info)
        self.log("时间: \(timeStr)", level: .info)
        let passedCount = enabledSteps.filter { stepStatuses[$0.id] == .passed }.count
        let skippedCount = enabledSteps.filter { stepStatuses[$0.id] == .skipped }.count
        self.log("结果: 通过 \(passedCount)，跳过 \(skippedCount)，总计 \(enabledSteps.count)", level: .info)
        self.log("步骤:", level: .info)
        for (index, step) in enabledSteps.enumerated() {
            let status = stepStatuses[step.id] ?? .pending
            let result = stepResults[step.id] ?? ""
            let title = appLanguage.string("production_test_rules.\(step.key)_title")
            let statusStr: String
            switch status {
            case .passed: statusStr = "✓"
            case .failed: statusStr = "✗"
            case .skipped: statusStr = "−"
            case .pending, .running: statusStr = "?"
            }
            let oneLine = result.replacingOccurrences(of: "\n", with: " ")
            if oneLine.isEmpty {
                self.log("  \(index + 1). \(title) \(statusStr)", level: .info)
            } else {
                self.log("  \(index + 1). \(title) \(statusStr) \(oneLine)", level: .info)
            }
        }
        self.log("──────────────────────────────", level: .info)
    }
}

// MARK: - 产测结果 Overlay（绿/红弹窗报表）
private struct ProductionTestResultOverlay: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    let passed: Bool
    let criteria: [(name: String, ok: Bool)]
    let timeString: String
    let onDismiss: () -> Void
    
    private var accentColor: Color { passed ? Color.green : Color.red }
    private var titleKey: String { passed ? "production_test.result_overlay_title_pass" : "production_test.result_overlay_title_fail" }
    private var iconName: String { passed ? "checkmark.seal.fill" : "xmark.circle.fill" }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }
            
            VStack(spacing: 0) {
                // 顶部色条（绿/红）
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [accentColor, accentColor.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 6)
                
                VStack(spacing: UIDesignSystem.Spacing.lg) {
                    // 图标 + 标题
                    HStack(spacing: UIDesignSystem.Spacing.sm) {
                        Image(systemName: iconName)
                            .font(.system(size: 36))
                            .foregroundStyle(accentColor)
                        Text(appLanguage.string(titleKey))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color(NSColor.labelColor))
                    }
                    .padding(.top, UIDesignSystem.Padding.lg)
                    
                    Text(timeString)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Color(NSColor.secondaryLabelColor))
                    
                    // 判定项列表
                    VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
                        ForEach(Array(criteria.enumerated()), id: \.offset) { _, item in
                            HStack(spacing: UIDesignSystem.Spacing.sm) {
                                Image(systemName: item.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(item.ok ? Color.green : Color.red)
                                    .font(.body)
                                Text(item.name)
                                    .font(.subheadline)
                                    .foregroundStyle(Color(NSColor.labelColor))
                                Spacer()
                            }
                            .padding(.horizontal, UIDesignSystem.Padding.sm)
                            .padding(.vertical, 6)
                            .background(Color(NSColor.separatorColor).opacity(0.25))
                            .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal)
                    
                    Button(appLanguage.string("production_test.result_overlay_dismiss")) {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accentColor)
                    .padding(.bottom, UIDesignSystem.Padding.lg)
                }
                .frame(minWidth: 320, maxWidth: 420)
                .background(Color(NSColor.controlBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 12)
        }
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
