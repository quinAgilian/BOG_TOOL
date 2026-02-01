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
            
            // 简化的OTA状态显示（仅在OTA进行中时显示）
            if ble.isOTAInProgress || ble.isOTACompletedWaitingReboot || ble.isOTAFailed || ble.isOTACancelled {
                simplifiedOTAStatusView
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

            // 测试日志区域
            if !testLog.isEmpty {
                VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
                    HStack {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundStyle(.blue)
                        Text(appLanguage.string("production_test.log_title"))
                            .font(UIDesignSystem.Typography.caption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
                                ForEach(Array(testLog.enumerated()), id: \.offset) { i, line in
                                    HStack(alignment: .top, spacing: 4) {
                                        if line.contains("✓") || line.contains("验证通过") {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                                .font(.caption)
                                        } else if line.contains("警告") || line.contains("错误") || line.contains("Warning") || line.contains("Error") || line.contains("Failed") {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(.orange)
                                                .font(.caption)
                                        } else {
                                            Image(systemName: "circle.fill")
                                                .foregroundStyle(.gray.opacity(0.3))
                                                .font(.system(size: 4))
                                                .padding(.top, 6)
                                        }
                                        Text(line)
                                            .font(UIDesignSystem.Typography.monospacedCaption)
                                    }
                                    .id(i)
                                }
                            }
                        }
                        .frame(height: UIDesignSystem.Component.testLogHeight)
                        .onChange(of: testLog.count) { _ in
                            if let last = testLog.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
                .padding(UIDesignSystem.Padding.sm)
                .background(
                    LinearGradient(
                        colors: [Color.secondary.opacity(0.1), Color.secondary.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .cornerRadius(UIDesignSystem.CornerRadius.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: UIDesignSystem.CornerRadius.sm)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                )
            } else if !ble.isConnected {
                // 未连接时的提示
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
    
    /// 简化的OTA状态视图（仅显示进度和状态）
    private var simplifiedOTAStatusView: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
            HStack(spacing: UIDesignSystem.Spacing.sm) {
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
                
                Text(otaStatusText)
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
            }
            
            if ble.isOTAInProgress {
                ProgressView(value: ble.otaProgress)
                    .progressViewStyle(.linear)
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(UIDesignSystem.CornerRadius.sm)
    }
    
    /// OTA状态文本
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
        let stepMap = [TestStep.connectDevice, .verifyFirmware, .readRTC, .readPressure, .tbd, .ensureValveOpen, .otaBeforeDisconnect, .disconnectDevice]
            .reduce(into: [:]) { $0[$1.id] = $1 }
        
        var steps: [TestStep] = []
        if let saved = UserDefaults.standard.array(forKey: "production_test_steps_order") as? [String] {
            for id in saved {
                if let step = stepMap[id] {
                    steps.append(step)
                }
            }
        } else {
            steps = [.connectDevice, .verifyFirmware, .readRTC, .readPressure, .ensureValveOpen, .tbd, .otaBeforeDisconnect, .disconnectDevice]
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
            rtcPassThreshold: UserDefaults.standard.object(forKey: "production_test_rtc_pass_threshold") as? Double ?? 2.0,
            rtcFailThreshold: UserDefaults.standard.object(forKey: "production_test_rtc_fail_threshold") as? Double ?? 5.0,
            rtcWriteEnabled: UserDefaults.standard.object(forKey: "production_test_rtc_write_enabled") as? Bool ?? true,
            rtcWriteRetryCount: UserDefaults.standard.object(forKey: "production_test_rtc_write_retry_count") as? Int ?? 3,
            rtcReadTimeout: UserDefaults.standard.object(forKey: "production_test_rtc_read_timeout") as? Double ?? 2.0,
            deviceInfoReadTimeout: UserDefaults.standard.object(forKey: "production_test_device_info_timeout") as? Double ?? 3.0,
            otaStartWaitTimeout: UserDefaults.standard.object(forKey: "production_test_ota_start_timeout") as? Double ?? 5.0,
            deviceReconnectTimeout: UserDefaults.standard.object(forKey: "production_test_reconnect_timeout") as? Double ?? 5.0,
            valveOpenTimeout: UserDefaults.standard.object(forKey: "production_test_valve_open_timeout") as? Double ?? 3.0,
            pressureClosedMin: UserDefaults.standard.object(forKey: "production_test_pressure_closed_min") as? Double ?? 1.300,
            pressureOpenMin: UserDefaults.standard.object(forKey: "production_test_pressure_open_min") as? Double ?? 1.1,
            pressureDiffCheckEnabled: UserDefaults.standard.object(forKey: "production_test_pressure_diff_check_enabled") as? Bool ?? false,
            pressureDiffThreshold: UserDefaults.standard.object(forKey: "production_test_pressure_diff_threshold") as? Double ?? 0.1,
            firmwareUpgradeEnabled: UserDefaults.standard.object(forKey: "production_test_firmware_upgrade_enabled") as? Bool ?? true
        )
        
        return (steps: steps, bootloaderVersion: bootloaderVersion, firmwareVersion: firmwareVersion, hardwareVersion: hardwareVersion, thresholds: thresholds)
    }
    
    /// 测试阈值配置结构
    struct TestThresholds {
        let rtcPassThreshold: Double          // RTC时间差通过阈值（秒）
        let rtcFailThreshold: Double         // RTC时间差失败阈值（秒）
        let rtcWriteEnabled: Bool             // 是否启用RTC写入
        let rtcWriteRetryCount: Int          // RTC写入重试次数
        let rtcReadTimeout: Double            // RTC读取超时（秒）
        let deviceInfoReadTimeout: Double      // 设备信息读取超时（秒）
        let otaStartWaitTimeout: Double       // OTA启动等待超时（秒）
        let deviceReconnectTimeout: Double    // 设备重新连接超时（秒）
        let valveOpenTimeout: Double          // 阀门打开超时（秒）
        let pressureClosedMin: Double        // 关闭状态压力最小值（mbar）
        let pressureOpenMin: Double          // 开启状态压力最小值（mbar）
        let pressureDiffCheckEnabled: Bool   // 是否启用压力差值检查
        let pressureDiffThreshold: Double    // 压力差值阈值（mbar）
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
    
    /// 确保阀门打开 - 复用debug mode的逻辑，使用BLEManager方法
    private func ensureValveOpen() async -> Bool {
        // 加载阈值配置
        let rules = loadTestRules()
        let valveTimeout = rules.thresholds.valveOpenTimeout
        
        // 先读取当前阀门状态（复用debug mode的方法）
        ble.readValveState()
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // 如果已经是打开状态，直接返回
        if ble.lastValveStateValue == "open" {
            return true
        }
        
        self.log("确保阀门打开...", level: .info)
        
        // 使用BLEManager的setValve方法（与debug mode一致）
        ble.setValve(open: true)
        
        // 等待并验证，使用配置的超时时间
        let targetState = "open"
        let startTime = Date()
        var checkCount = 0
        let maxChecks = Int(valveTimeout * 10) // 每0.1秒检查一次
        
        while checkCount < maxChecks {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
            checkCount += 1
            
                // 检查是否达到目标状态
                if ble.lastValveStateValue == targetState {
                    self.log("阀门已打开", level: .info)
                    return true
                }
                
                // 检查超时
                if Date().timeIntervalSince(startTime) >= valveTimeout {
                    self.log("警告：阀门打开失败（超时，\(Int(valveTimeout))秒）", level: .warning)
                    return false
                }
            }
            
            self.log("警告：阀门打开失败（超时，\(Int(valveTimeout))秒）", level: .warning)
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
            isRunning = true
            testLog.removeAll()
            stepIndex = 0
            log("正在连接设备: \(device.name)...", level: .info)
            ble.connect(to: device)
            
            // 等待连接完成
            Task { @MainActor in
                var waitCount = 0
                while !ble.isConnected && waitCount < 100 { // 最多等待10秒
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1秒
                    waitCount += 1
                }
                
                if ble.isConnected {
                    // 连接成功，继续执行产测流程
                    await executeProductionTest()
                } else {
                    // 连接失败
                    log("错误：设备连接失败", level: .error)
                    isRunning = false
                }
            }
        } else {
            // 已连接，直接执行产测流程
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
        
        for step in enabledSteps {
                // 记录步骤开始时的日志索引
                let logStartIndex = testLog.count
                
                // 更新当前步骤状态
                currentStepId = step.id
                stepStatuses[step.id] = .running
                
                switch step.id {
                case "step1": // 连接设备（已连接，跳过）
                    self.log("步骤1: 连接设备 - 已连接", level: .info)
                    stepResults[step.id] = appLanguage.string("production_test.connected")
                    stepStatuses[step.id] = .passed
                    
                case "step2": // 确认固件版本
                    self.log("步骤2: 确认固件版本", level: .info)
                    
                    // 等待设备信息读取完成（使用配置的超时时间）
                    self.log("等待读取设备信息（SN、FW版本）...", level: .info)
                    let timeoutSeconds = rules.thresholds.deviceInfoReadTimeout
                    let maxWaitCount = Int(timeoutSeconds * 10) // 每0.1秒检查一次
                    var waitCount = 0
                    while (ble.deviceSerialNumber == nil || ble.currentFirmwareVersion == nil) && waitCount < maxWaitCount {
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
                        self.log("警告：无法读取 HW 版本", level: .warning)
                        resultMessages.append("HW: ⚠️")
                    }
                    
                    stepResults[step.id] = resultMessages.joined(separator: "\n")
                    stepStatuses[step.id] = .passed
                    
                case "step3": // 检查 RTC - 按照新逻辑：2秒内通过，2-5秒循环写入读取，超过5秒失败
                    self.log("步骤3: 检查 RTC", level: .info)
                    
                    let passThreshold = rules.thresholds.rtcPassThreshold
                    let failThreshold = rules.thresholds.rtcFailThreshold
                    let rtcWriteEnabled = rules.thresholds.rtcWriteEnabled
                    let maxRetries = rules.thresholds.rtcWriteRetryCount
                    let rtcTimeoutSeconds = rules.thresholds.rtcReadTimeout
                    let maxRtcWaitCount = Int(rtcTimeoutSeconds * 10) // 每0.1秒检查一次
                    
                    // 读取RTC
                    self.log("读取 RTC...", level: .info)
                    ble.writeTestingUnlock()
                    ble.readRTC()
                    
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
                                    
                                    // 执行RTC写入（写入当前系统时间，7字节）
                                    let logCountBeforeWrite = ble.logEntries.count
                                    // 确保Testing特征已解锁，以便写入后可以读取验证
                                    ble.writeTestingUnlock()
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
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
                                    self.log("重新读取后时间差: \(timeDiffString)", level: .info)
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
                    let pressureOpenMin = rules.thresholds.pressureOpenMin
                    
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
                        if closedMbar >= pressureClosedMin {
                            self.log("✓ 关闭压力验证通过: \(closedMbar) mbar（≥ \(pressureClosedMin) mbar）", level: .info)
                            pressureMessages.append("关闭: \(closedPressureStr) ✓")
                        } else {
                            self.log("✗ 关闭压力验证失败: \(closedMbar) mbar（< \(pressureClosedMin) mbar）", level: .error)
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
                        if openMbar >= pressureOpenMin {
                            self.log("✓ 开启压力验证通过: \(openMbar) mbar（≥ \(pressureOpenMin) mbar）", level: .info)
                            pressureMessages.append("开启: \(openPressureStr) ✓")
                        } else {
                            self.log("✗ 开启压力验证失败: \(openMbar) mbar（< \(pressureOpenMin) mbar）", level: .error)
                            pressureMessages.append("开启: \(openPressureStr) ✗")
                            pressurePassed = false
                        }
                    } else {
                        self.log("警告：无法解析开启压力值", level: .warning)
                        pressureMessages.append("开启: \(openPressureStr) ⚠️")
                        pressurePassed = false
                    }
                    
                    // 压力差值检查（如果启用）
                    if rules.thresholds.pressureDiffCheckEnabled {
                        if let closedMbar = closedPressureValue.map({ $0 * 1000.0 }),
                           let openMbar = openPressureValue.map({ $0 * 1000.0 }) {
                            let diff = abs(openMbar - closedMbar)
                            let diffThreshold = rules.thresholds.pressureDiffThreshold
                            
                            if diff >= diffThreshold {
                                self.log("✓ 压力差值验证通过: \(String(format: "%.3f", diff)) mbar（≥ \(diffThreshold) mbar）", level: .info)
                                pressureMessages.append("差值: \(String(format: "%.3f", diff)) mbar ✓")
                            } else {
                                self.log("✗ 压力差值验证失败: \(String(format: "%.3f", diff)) mbar（< \(diffThreshold) mbar）", level: .error)
                                pressureMessages.append("差值: \(String(format: "%.3f", diff)) mbar ✗")
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
                    
                case "step_valve": // 确保电磁阀是开启的
                    self.log("步骤: 确保电磁阀是开启的", level: .info)
                    let valveOpened = await ensureValveOpen()
                    if valveOpened {
                        stepResults[step.id] = appLanguage.string("production_test_rules.step_valve_criteria")
                        stepStatuses[step.id] = .passed
                    } else {
                        self.log("电磁阀打开失败或超时", level: .warning)
                        stepResults[step.id] = "电磁阀: 打开失败或超时"
                        stepStatuses[step.id] = .failed
                    }
                    
                case "step_ota": // 断开连接前 OTA（默认启用，仅当固件版本与期望不一致时才执行 OTA）
                    self.log("步骤: 断开前 OTA", level: .info, category: "OTA")
                    
                    // 产测按 SOP 期望版本从固件管理中选择目标固件
                    guard let otaURL = firmwareManager.url(forVersion: rules.firmwareVersion) else {
                        self.log("错误：未在固件管理中找到版本 \(rules.firmwareVersion) 的固件，请先在「固件」菜单中添加", level: .error, category: "OTA")
                        stepStatuses[step.id] = .failed
                        stepResults[step.id] = "OTA: 未找到 \(rules.firmwareVersion) 固件（请在固件管理中添加）"
                        isRunning = false
                        currentStepId = nil
                        return
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
                    if let reason = ble.startOTA(firmwareURL: otaURL) {
                        self.log("错误：OTA 未启动（\(reason)）", level: .error, category: "OTA")
                        stepStatuses[step.id] = .failed
                        stepResults[step.id] = "OTA: \(reason)"
                        isRunning = false
                        currentStepId = nil
                        return
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
                        isRunning = false
                        currentStepId = nil
                        return
                    }
                    
                    self.log("OTA 已启动，传输进行中...", level: .info, category: "OTA")
                    while ble.isOTAInProgress {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    
                    if ble.isOTAFailed || ble.isOTACancelled {
                        self.log("错误：OTA 失败或已取消", level: .error, category: "OTA")
                        stepStatuses[step.id] = .failed
                        stepResults[step.id] = "OTA: 失败或已取消"
                        isRunning = false
                        currentStepId = nil
                        return
                    }
                    
                    if ble.otaProgress >= 1.0 && !ble.isOTAFailed {
                        self.log("OTA 传输完成，等待设备重启...", level: .info, category: "OTA")
                        try? await Task.sleep(nanoseconds: 5000_000_000)
                        self.log("等待设备重新连接（超时: \(Int(rules.thresholds.deviceReconnectTimeout))秒）...", level: .info, category: "OTA")
                        let reconnectTimeoutSeconds = rules.thresholds.deviceReconnectTimeout
                        let maxReconnectWaitCount = Int(reconnectTimeoutSeconds * 2)
                        var reconnectWaitCount = 0
                        while !ble.isConnected && reconnectWaitCount < maxReconnectWaitCount {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            reconnectWaitCount += 1
                            if reconnectWaitCount % 4 == 0 {
                                let elapsed = Double(reconnectWaitCount) / 2.0
                                self.log("等待设备重新连接中...（已等待 \(String(format: "%.1f", elapsed))秒）", level: .debug, category: "OTA")
                            }
                        }
                        if ble.isConnected {
                            self.log("设备已重新连接，OTA 步骤完成", level: .info, category: "OTA")
                            if let newFw = ble.currentFirmwareVersion {
                                stepResults[step.id] = "OTA: \(newFw) ✓"
                            } else {
                                stepResults[step.id] = "OTA: 完成 ✓"
                            }
                            stepStatuses[step.id] = .passed
                        } else {
                            self.log("错误：设备重新连接超时", level: .error)
                            stepStatuses[step.id] = .failed
                            stepResults[step.id] = "OTA: 设备未重新连接"
                            isRunning = false
                            currentStepId = nil
                            return
                        }
                    } else {
                        self.log("错误：OTA 未完成", level: .error, category: "OTA")
                        stepStatuses[step.id] = .failed
                        stepResults[step.id] = "OTA: 未完成"
                        isRunning = false
                        currentStepId = nil
                        return
                    }
                    
                case "step5": // 待定
                    self.log("步骤5: 待定步骤（跳过）", level: .info)
                    stepStatuses[step.id] = .skipped
                    
                case "step_disconnect": // 断开连接
                    self.log("最后步骤: 安全断开连接", level: .info)
                    
                    // 断开连接前确保阀门打开（复用debug mode的逻辑）
                    let valveOpened = await ensureValveOpen()
                    if !valveOpened {
                        self.log("警告：断开前阀门打开失败，继续断开...", level: .warning)
                    }
                    
                    self.log("断开连接...", level: .info)
                    ble.disconnect()
                    try? await Task.sleep(nanoseconds: 1000_000_000)
                    self.log("已断开连接", level: .info)
                    stepResults[step.id] = appLanguage.string("production_test.disconnected")
                    stepStatuses[step.id] = .passed
                    
                default:
                    self.log("未知步骤: \(step.id)", level: .error)
                    stepStatuses[step.id] = .failed
                }
                
                // 记录步骤结束时的日志索引
                let logEndIndex = testLog.count
                stepLogRanges[step.id] = (start: logStartIndex, end: logEndIndex)
                
                // 清除当前步骤标记
                currentStepId = nil
                
                // 步骤间延时
                if step.id != enabledSteps.last?.id {
                    self.log("步骤完成，等待 \(String(format: "%.1f", 0.3))秒后继续下一步骤...", level: .debug)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            
        // 统计测试结果
        let passedCount = enabledSteps.filter { stepStatuses[$0.id] == .passed }.count
        let failedCount = enabledSteps.filter { stepStatuses[$0.id] == .failed }.count
        let skippedCount = enabledSteps.filter { stepStatuses[$0.id] == .skipped }.count
        
        self.log("产测流程结束", level: .info)
        self.log("测试结果统计：通过 \(passedCount)，失败 \(failedCount)，跳过 \(skippedCount)，总计 \(enabledSteps.count)", level: .info)
        isRunning = false
        currentStepId = nil
        // 更新测试结果状态
        updateTestResultStatus()
    }
}
