import SwiftUI

/// 测试步骤定义
struct TestStep: Identifiable, Equatable {
    let id: String
    let key: String  // 本地化key前缀，如 "step2"
    let isLocked: Bool  // 是否锁定（第一步连接设备）
    
    static let connectDevice = TestStep(id: "step1", key: "step1", isLocked: true)
    static let verifyFirmware = TestStep(id: "step2", key: "step2", isLocked: false)
    static let readRTC = TestStep(id: "step3", key: "step3", isLocked: false)
    static let readPressure = TestStep(id: "step4", key: "step4", isLocked: false)
    static let tbd = TestStep(id: "step5", key: "step5", isLocked: false)
    static let disconnectDevice = TestStep(id: "step_disconnect", key: "step_disconnect", isLocked: false)
}

/// 产测规则视图：定义产测SOP（标准操作程序）
struct ProductionTestRulesView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @State private var firmwareVersion: String = {
        UserDefaults.standard.string(forKey: "production_test_firmware_version") ?? "1.1.1"
    }()
    
    // 默认步骤顺序：第一步锁定，最后一步断开连接
    private static let defaultSteps: [TestStep] = [
        .connectDevice,
        .verifyFirmware,
        .readRTC,
        .readPressure,
        .tbd,
        .disconnectDevice
    ]
    
    @State private var testSteps: [TestStep] = {
        // 从UserDefaults加载保存的顺序，如果没有则使用默认顺序
        if let saved = UserDefaults.standard.array(forKey: "production_test_steps_order") as? [String] {
            let stepMap = [TestStep.connectDevice, .verifyFirmware, .readRTC, .readPressure, .tbd, .disconnectDevice]
                .reduce(into: [:]) { $0[$1.id] = $1 }
            var steps: [TestStep] = []
            for id in saved {
                if let step = stepMap[id] {
                    steps.append(step)
                }
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
            return steps.isEmpty ? defaultSteps : steps
        }
        return defaultSteps
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 软件版本配置
                    firmwareVersionSection
                    
                    // 产测流程说明
                    testProcedureSection
                    
                    // 测试步骤详情
                    testStepsSection
                    
                    // 注意事项
                    notesSection
                }
                .padding()
            }
        }
        .frame(minWidth: 520, minHeight: 500)
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(appLanguage.string("production_test_rules.title"))
                    .font(.title2.weight(.semibold))
                Spacer()
            }
        }
        .padding()
    }
    
    private var firmwareVersionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appLanguage.string("production_test_rules.firmware_version_title"))
                .font(.headline)
                .foregroundStyle(.primary)
            
            HStack(spacing: 12) {
                Text(appLanguage.string("production_test_rules.firmware_version_label"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                
                TextField(
                    appLanguage.string("production_test_rules.firmware_version_placeholder"),
                    text: $firmwareVersion
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onChange(of: firmwareVersion) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "production_test_firmware_version")
                }
                
                Text(appLanguage.string("production_test_rules.firmware_version_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    private var testProcedureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appLanguage.string("production_test_rules.procedure_title"))
                .font(.headline)
                .foregroundStyle(.primary)
            
            Text(appLanguage.string("production_test_rules.procedure_description"))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    private var testStepsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(appLanguage.string("production_test_rules.steps_title"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(appLanguage.string("production_test_rules.drag_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(testSteps.enumerated()), id: \.element.id) { index, step in
                    let isLocked = (index == 0 && step.id == TestStep.connectDevice.id) || 
                                  (index == testSteps.count - 1 && step.id == TestStep.disconnectDevice.id)
                    HStack(spacing: 8) {
                        // 上下移动按钮（锁定步骤不显示）
                        if !isLocked {
                            VStack(spacing: 4) {
                                Button {
                                    moveStepUp(at: index)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .disabled(index <= 1) // 不能移动到第一步之前
                                
                                Button {
                                    moveStepDown(at: index)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .disabled(index >= testSteps.count - 2) // 不能移动到最后一步之后
                            }
                            .frame(width: 24)
                        } else {
                            Spacer()
                                .frame(width: 24)
                        }
                        
                        stepItem(
                            number: index + 1,
                            step: step,
                            isLocked: isLocked
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    private func moveStepUp(at index: Int) {
        // 不能移动第一步或最后一步
        guard index > 0 && index < testSteps.count - 1 else { return }
        // 不能移动到第一步的位置
        guard index > 1 else { return }
        
        testSteps.swapAt(index, index - 1)
        saveStepsOrder()
    }
    
    private func moveStepDown(at index: Int) {
        // 不能移动第一步或最后一步
        guard index > 0 && index < testSteps.count - 1 else { return }
        // 不能移动到最后一步的位置
        guard index < testSteps.count - 2 else { return }
        
        testSteps.swapAt(index, index + 1)
        saveStepsOrder()
    }
    
    private func saveStepsOrder() {
        let order = testSteps.map { $0.id }
        UserDefaults.standard.set(order, forKey: "production_test_steps_order")
    }
    
    private func stepItem(number: Int, step: TestStep, isLocked: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // 步骤编号
            ZStack {
                Text("\(number)")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(isLocked ? Color.gray : Color.accentColor)
                    .clipShape(Circle())
                
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .offset(x: 10, y: -10)
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(appLanguage.string("production_test_rules.\(step.key)_title"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(appLanguage.string("production_test_rules.\(step.key)_desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                let criteriaKey = "production_test_rules.\(step.key)_criteria"
                let criteria = appLanguage.string(criteriaKey)
                if !criteria.isEmpty && criteria != criteriaKey { // 检查是否真的存在本地化字符串
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .padding(.top, 2)
                        Text(criteria)
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
            }
            
            Spacer()
        }
        .contentShape(Rectangle()) // 使整个区域可点击/拖动
    }
    
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appLanguage.string("production_test_rules.notes_title"))
                .font(.headline)
                .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                noteItem(appLanguage.string("production_test_rules.note1"))
                noteItem(appLanguage.string("production_test_rules.note2"))
                noteItem(appLanguage.string("production_test_rules.note3"))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    private func noteItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ProductionTestRulesView()
        .environmentObject(AppLanguage())
        .frame(width: 560, height: 500)
}
