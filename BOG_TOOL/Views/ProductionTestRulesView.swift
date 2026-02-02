import SwiftUI

/// 产测规则变化通知名称
extension Notification.Name {
    static let productionTestRulesDidChange = Notification.Name("productionTestRulesDidChange")
}

/// 测试步骤定义
struct TestStep: Identifiable, Equatable {
    let id: String
    let key: String  // 本地化key前缀，如 "step2"
    let isLocked: Bool  // 是否锁定（第一步连接设备）
    var enabled: Bool  // 是否启用此步骤
    
    static let connectDevice = TestStep(id: "step1", key: "step1", isLocked: true, enabled: true)
    static let verifyFirmware = TestStep(id: "step2", key: "step2", isLocked: false, enabled: true)
    static let readRTC = TestStep(id: "step3", key: "step3", isLocked: false, enabled: true)
    static let readPressure = TestStep(id: "step4", key: "step4", isLocked: false, enabled: true)
    /// 读取 Gas system status（0 initially closed, 1 ok, 2 leak…；产测要求 1 ok）
    static let readGasSystemStatus = TestStep(id: "step_gas_system_status", key: "step_gas_system_status", isLocked: false, enabled: true)
    static let tbd = TestStep(id: "step5", key: "step5", isLocked: false, enabled: false)
    /// 确保电磁阀是开启的（可调顺序、有使能开关）
    static let ensureValveOpen = TestStep(id: "step_valve", key: "step_valve", isLocked: false, enabled: true)
    /// 断开连接前的 OTA 步骤（默认启用，不许用户取消）
    static let otaBeforeDisconnect = TestStep(id: "step_ota", key: "step_ota", isLocked: true, enabled: true)
    static let disconnectDevice = TestStep(id: "step_disconnect", key: "step_disconnect", isLocked: false, enabled: true)
}

/// 产测规则视图：定义产测SOP（标准操作程序）
struct ProductionTestRulesView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    @ObservedObject var firmwareManager: FirmwareManager
    @State private var bootloaderVersion: String = {
        UserDefaults.standard.string(forKey: "production_test_bootloader_version") ?? ""
    }()
    @State private var firmwareVersion: String = {
        UserDefaults.standard.string(forKey: "production_test_firmware_version") ?? "1.0.5"
    }()
    @State private var hardwareVersion: String = {
        UserDefaults.standard.string(forKey: "production_test_hardware_version") ?? "P02V02R00"
    }()
    // 固件版本升级开关
    @State private var firmwareUpgradeEnabled: Bool = {
        UserDefaults.standard.object(forKey: "production_test_firmware_upgrade_enabled") as? Bool ?? true
    }()
    @State private var isEditingOrder: Bool = false
    // 步骤展开状态（用于显示配置项）
    @State private var expandedSteps: Set<String> = []
    
    // RTC时间差阈值配置（单位：秒）
    @State private var rtcTimeDiffPassThreshold: Double = {
        UserDefaults.standard.object(forKey: "production_test_rtc_pass_threshold") as? Double ?? 2.0
    }()
    @State private var rtcTimeDiffFailThreshold: Double = {
        UserDefaults.standard.object(forKey: "production_test_rtc_fail_threshold") as? Double ?? 5.0
    }()
    // RTC写入配置
    @State private var rtcWriteEnabled: Bool = {
        UserDefaults.standard.object(forKey: "production_test_rtc_write_enabled") as? Bool ?? true
    }()
    @State private var rtcWriteRetryCount: Int = {
        UserDefaults.standard.object(forKey: "production_test_rtc_write_retry_count") as? Int ?? 3
    }()
    
    // 等待超时配置（单位：秒）
    @State private var rtcReadTimeout: Double = {
        UserDefaults.standard.object(forKey: "production_test_rtc_read_timeout") as? Double ?? 2.0
    }()
    @State private var deviceInfoReadTimeout: Double = {
        UserDefaults.standard.object(forKey: "production_test_device_info_timeout") as? Double ?? 3.0
    }()
    @State private var otaStartWaitTimeout: Double = {
        UserDefaults.standard.object(forKey: "production_test_ota_start_timeout") as? Double ?? 5.0
    }()
    @State private var deviceReconnectTimeout: Double = {
        UserDefaults.standard.object(forKey: "production_test_reconnect_timeout") as? Double ?? 5.0
    }()
    @State private var valveOpenTimeout: Double = {
        UserDefaults.standard.object(forKey: "production_test_valve_open_timeout") as? Double ?? 5.0
    }()
    /// 每个测试步骤之间的等待时间（SOP 定义，单位 ms）
    @State private var stepIntervalMs: Int = {
        UserDefaults.standard.object(forKey: "production_test_step_interval_ms") as? Int ?? 100
    }()
    /// 连接设备步骤完成后、下一步前等待秒数（供用户处理系统蓝牙权限/配对弹窗，0=不等待）
    @State private var bluetoothPermissionWaitSeconds: Double = {
        UserDefaults.standard.object(forKey: "production_test_bluetooth_permission_wait_seconds") as? Double ?? 0
    }()
    
    // 压力阈值配置（单位：mbar）
    @State private var pressureClosedMin: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_closed_min") as? Double ?? 1100
    }()
    @State private var pressureClosedMax: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_closed_max") as? Double ?? 1350
    }()
    @State private var pressureOpenMin: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_open_min") as? Double ?? 1300
    }()
    @State private var pressureOpenMax: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_open_max") as? Double ?? 1500
    }()
    // 压力差值检查配置
    @State private var pressureDiffCheckEnabled: Bool = {
        UserDefaults.standard.object(forKey: "production_test_pressure_diff_check_enabled") as? Bool ?? true
    }()
    @State private var pressureDiffMin: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_diff_min") as? Double ?? 30
    }()
    @State private var pressureDiffMax: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_diff_max") as? Double ?? 400
    }()
    
    // 默认步骤顺序：第一步连接，断开前 OTA，最后一步断开连接；中间含「读取 Gas system status」「确保电磁阀开启」等可调顺序步骤
    private static let defaultSteps: [TestStep] = [
        .connectDevice,
        .verifyFirmware,
        .readRTC,
        .readPressure,
        .readGasSystemStatus,
        .ensureValveOpen,
        .tbd,
        .otaBeforeDisconnect,
        .disconnectDevice
    ]
    
    @State private var testSteps: [TestStep] = {
        // 从UserDefaults加载保存的顺序和启用状态，如果没有则使用默认值
        let stepMap = [TestStep.connectDevice, .verifyFirmware, .readRTC, .readPressure, .readGasSystemStatus, .tbd, .ensureValveOpen, .otaBeforeDisconnect, .disconnectDevice]
            .reduce(into: [:]) { $0[$1.id] = $1 }
        
        // 加载步骤顺序
        var steps: [TestStep] = []
        if let saved = UserDefaults.standard.array(forKey: "production_test_steps_order") as? [String] {
            for id in saved {
                if let step = stepMap[id] {
                    steps.append(step)
                }
            }
        } else {
            steps = defaultSteps
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
        // OTA 步骤必须在「确认固件版本」(step2) 之后
        ProductionTestRulesView.ensureOtaAfterFirmwareVerify(steps: &steps)
        
        // 加载每个步骤的启用状态（step_ota 不许用户关闭，始终为 true）
        if let enabledDict = UserDefaults.standard.dictionary(forKey: "production_test_steps_enabled") as? [String: Bool] {
            for i in 0..<steps.count {
                if steps[i].id == TestStep.otaBeforeDisconnect.id {
                    steps[i] = TestStep(id: steps[i].id, key: steps[i].key, isLocked: steps[i].isLocked, enabled: true)
                } else if let enabled = enabledDict[steps[i].id] {
                    steps[i] = TestStep(id: steps[i].id, key: steps[i].key, isLocked: steps[i].isLocked, enabled: enabled)
                }
            }
        }
        
        return steps.isEmpty ? defaultSteps : steps
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 产测流程说明
                    testProcedureSection
                    
                    // 全局延时设定（步骤间延时，适用于整个产测流程）
                    globalStepDelaySection
                    
                    // 测试步骤详情（包含各步骤的配置）
                    testStepsSection
                    
                    // 注意事项
                    notesSection
                }
                .padding()
            }
        }
        .frame(minWidth: 720, minHeight: 500)
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
    
    /// 全局延时设定：步骤间延时（适用于所有步骤之间，非步骤2专属）
    private var globalStepDelaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appLanguage.string("production_test_rules.global_step_delay_section"))
                .font(.headline)
                .foregroundStyle(.primary)
            
            thresholdIntRow(
                label: appLanguage.string("production_test_rules.step_interval_ms"),
                value: $stepIntervalMs,
                key: "production_test_step_interval_ms"
            )
            thresholdRow(
                label: appLanguage.string("production_test_rules.bluetooth_permission_wait_seconds"),
                value: $bluetoothPermissionWaitSeconds,
                unit: appLanguage.string("production_test_rules.unit_seconds"),
                key: "production_test_bluetooth_permission_wait_seconds"
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    
    private func thresholdRow(label: String, value: Binding<Double>, unit: String, key: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            
            TextField("", value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .onChange(of: value.wrappedValue) { newValue in
                    UserDefaults.standard.set(newValue, forKey: key)
                    NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                }
            
            Text(unit)
                .font(.body)
                .foregroundStyle(.secondary)
            
            Spacer()
        }
    }
    
    private func thresholdIntRow(label: String, value: Binding<Int>, key: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .onChange(of: value.wrappedValue) { newValue in
                    UserDefaults.standard.set(newValue, forKey: key)
                    NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                }
            
            Spacer()
        }
    }
    
    private var testStepsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(appLanguage.string("production_test_rules.steps_title"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    isEditingOrder.toggle()
                } label: {
                    Text(isEditingOrder ? appLanguage.string("production_test_rules.done_editing") : appLanguage.string("production_test_rules.edit_order"))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                Text(appLanguage.string("production_test_rules.drag_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(testSteps.enumerated()), id: \.element.id) { index, step in
                    let isPositionLocked = (index == 0 && step.id == TestStep.connectDevice.id) ||
                                           (index == testSteps.count - 1 && step.id == TestStep.disconnectDevice.id)
                    let isEnableLocked = isPositionLocked || step.id == TestStep.otaBeforeDisconnect.id // step_ota 不许用户关闭，仅隐藏开关
                    HStack(spacing: 8) {
                        // 拖拽手柄（编辑模式下显示）
                        if isEditingOrder && !isPositionLocked {
                            Image(systemName: "line.3.horizontal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                        } else {
                            Spacer()
                                .frame(width: 20)
                        }
                        
                        // 上下移动按钮（位置锁定步骤不显示）
                        if !isPositionLocked {
                            VStack(spacing: 4) {
                                Button {
                                    moveStepUp(at: index)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .disabled(index <= 1 || (step.id == TestStep.otaBeforeDisconnect.id && index > 0 && testSteps[index - 1].id == TestStep.verifyFirmware.id))
                                
                                Button {
                                    moveStepDown(at: index)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .disabled(index >= testSteps.count - 2 || (step.id == TestStep.verifyFirmware.id && index + 1 < testSteps.count && testSteps[index + 1].id == TestStep.otaBeforeDisconnect.id))
                            }
                            .frame(width: 24)
                        } else {
                            Spacer()
                                .frame(width: 24)
                        }
                        
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 0) {
                                // 可点击的步骤项区域（排除Toggle开关）
                                stepItem(
                                    number: index + 1,
                                    step: step,
                                    isLocked: isEnableLocked,
                                    isExpanded: expandedSteps.contains(step.id)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // 非编辑模式下，点击步骤项展开/折叠配置
                                    if !isEditingOrder {
                                        if expandedSteps.contains(step.id) {
                                            expandedSteps.remove(step.id)
                                        } else {
                                            expandedSteps.insert(step.id)
                                        }
                                    }
                                }
                                
                                Spacer()
                                
                                // 启用/禁用开关（位置锁定或 step_ota 不显示开关，始终视为启用）
                                if !isEnableLocked {
                                    Toggle("", isOn: Binding(
                                        get: { testSteps[index].enabled },
                                        set: { newValue in
                                            var updatedSteps = testSteps
                                            updatedSteps[index] = TestStep(
                                                id: updatedSteps[index].id,
                                                key: updatedSteps[index].key,
                                                isLocked: updatedSteps[index].isLocked,
                                                enabled: newValue
                                            )
                                            testSteps = updatedSteps
                                            saveStepsEnabled()
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .frame(width: 40)
                                } else {
                                    Spacer()
                                        .frame(width: 40)
                                }
                            }
                            
                            // 展开时显示配置项（编辑模式下隐藏）
                            if expandedSteps.contains(step.id) && !isEditingOrder {
                                stepConfigurationView(step: step)
                                    .padding(.leading, 52) // 与步骤内容对齐
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .background(isEditingOrder && !isPositionLocked ? Color.blue.opacity(0.05) : Color.clear)
                    .gesture(
                        isEditingOrder && !isPositionLocked ? DragGesture(minimumDistance: 10)
                            .onChanged { value in
                                // 拖拽过程中可以添加视觉反馈
                            }
                            .onEnded { value in
                                // 计算拖拽的目标位置
                                let dragDistance = value.translation.height
                                let rowHeight: CGFloat = 80 // 估算每行高度（包括间距）
                                let targetOffset = Int(round(dragDistance / rowHeight))
                                let targetIndex = index + targetOffset
                                
                                // 确保目标位置有效（不能是第一步或最后一步）
                                if targetIndex > 0 && targetIndex < testSteps.count - 1 && targetIndex != index {
                                    moveStep(from: IndexSet([index]), to: targetIndex)
                                }
                            } : nil
                    )
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    /// OTA 步骤必须在「确认固件版本」(step2) 之后；若违反则把 step_ota 移到 step2 之后
    private static func ensureOtaAfterFirmwareVerify(steps: inout [TestStep]) {
        guard let fwIndex = steps.firstIndex(where: { $0.id == TestStep.verifyFirmware.id }),
              let otaIndex = steps.firstIndex(where: { $0.id == TestStep.otaBeforeDisconnect.id }) else { return }
        if otaIndex <= fwIndex {
            let ota = steps.remove(at: otaIndex)
            let insertIndex = steps.firstIndex(where: { $0.id == TestStep.verifyFirmware.id }).map { $0 + 1 } ?? steps.count - 1
            steps.insert(ota, at: min(insertIndex, steps.count))
        }
    }
    
    private func moveStep(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }
        
        // 不能移动第一步或最后一步
        guard sourceIndex > 0 && sourceIndex < testSteps.count - 1 else { return }
        // 不能移动到第一步或最后一步的位置
        guard destination > 0 && destination < testSteps.count - 1 else { return }
        
        // 如果目标位置在源位置之后，需要调整索引（因为先删除后插入）
        let adjustedDestination = destination > sourceIndex ? destination - 1 : destination
        
        var updatedSteps = testSteps
        let step = updatedSteps.remove(at: sourceIndex)
        updatedSteps.insert(step, at: adjustedDestination)
        
        // 确保第一步和最后一步在正确位置
        if updatedSteps[0].id != TestStep.connectDevice.id {
            updatedSteps.removeAll { $0.id == TestStep.connectDevice.id }
            updatedSteps.insert(TestStep.connectDevice, at: 0)
        }
        if updatedSteps.last?.id != TestStep.disconnectDevice.id {
            updatedSteps.removeAll { $0.id == TestStep.disconnectDevice.id }
            updatedSteps.append(TestStep.disconnectDevice)
        }
        Self.ensureOtaAfterFirmwareVerify(steps: &updatedSteps)
        
        testSteps = updatedSteps
        saveStepsOrder()
    }
    
    private func moveStepUp(at index: Int) {
        // 不能移动第一步或最后一步
        guard index > 0 && index < testSteps.count - 1 else { return }
        // 不能移动到第一步的位置
        guard index > 1 else { return }
        // OTA 步骤不能在「确认固件版本」之前
        if testSteps[index].id == TestStep.otaBeforeDisconnect.id && testSteps[index - 1].id == TestStep.verifyFirmware.id { return }
        
        testSteps.swapAt(index, index - 1)
        saveStepsOrder()
    }
    
    private func moveStepDown(at index: Int) {
        // 不能移动第一步或最后一步
        guard index > 0 && index < testSteps.count - 1 else { return }
        // 不能移动到最后一步的位置
        guard index < testSteps.count - 2 else { return }
        // 「确认固件版本」不能在 OTA 步骤之后
        if testSteps[index].id == TestStep.verifyFirmware.id && testSteps[index + 1].id == TestStep.otaBeforeDisconnect.id { return }
        
        testSteps.swapAt(index, index + 1)
        saveStepsOrder()
    }
    
    private func saveStepsOrder() {
        let order = testSteps.map { $0.id }
        UserDefaults.standard.set(order, forKey: "production_test_steps_order")
        // 发送通知，通知产测视图更新步骤列表
        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
    }
    
    private func saveStepsEnabled() {
        var enabledDict = testSteps.reduce(into: [String: Bool]()) { $0[$1.id] = $1.enabled }
        enabledDict[TestStep.otaBeforeDisconnect.id] = true // step_ota 不许用户关闭，持久化时强制为 true
        UserDefaults.standard.set(enabledDict, forKey: "production_test_steps_enabled")
        // 发送通知，通知产测视图更新步骤列表
        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
    }
    
    private func stepItem(number: Int, step: TestStep, isLocked: Bool, isExpanded: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // 步骤编号
            ZStack {
                Text("\(number)")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(isLocked ? Color.gray : (step.enabled ? Color.accentColor : Color.gray.opacity(0.5)))
                    .clipShape(Circle())
                
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .offset(x: 10, y: -10)
                } else if !step.enabled {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .offset(x: 10, y: -10)
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(appLanguage.string("production_test_rules.\(step.key)_title"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(step.enabled ? .primary : .secondary)
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if !step.enabled {
                        Text("(已禁用)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // 展开/折叠图标
                    if !isEditingOrder {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(appLanguage.string("production_test_rules.\(step.key)_desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(step.enabled ? 1.0 : 0.6)
                
                let criteriaKey = "production_test_rules.\(step.key)_criteria"
                let criteria = appLanguage.string(criteriaKey)
                if !criteria.isEmpty && criteria != criteriaKey && step.enabled { // 检查是否真的存在本地化字符串
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
        .opacity(step.enabled ? 1.0 : 0.6)
    }
    
    /// 步骤配置视图（展开时显示）
    private func stepConfigurationView(step: TestStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.vertical, 4)
            
            switch step.id {
            case "step2": // 确认固件版本
                versionConfigurationView
            case "step3": // 检查RTC
                rtcConfigurationView
            case "step4": // 读取压力值
                pressureConfigurationView
            default:
                EmptyView()
            }
        }
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
        .padding(.vertical, 4)
    }
    
    /// 版本配置视图（步骤2）
    private var versionConfigurationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appLanguage.string("production_test_rules.firmware_version_title"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                // Bootloader 版本
                HStack(spacing: 12) {
                    Text(appLanguage.string("production_test_rules.bootloader_version_label"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)
                    
                    TextField(
                        appLanguage.string("production_test_rules.bootloader_version_placeholder"),
                        text: $bootloaderVersion
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onChange(of: bootloaderVersion) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "production_test_bootloader_version")
                        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                    }
                }
                
                // FW 版本：从固件管理下拉选择，产测 OTA 步骤直接使用此版本，无需再选
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text(appLanguage.string("production_test_rules.firmware_version_label"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .leading)
                        
                        Picker("", selection: $firmwareVersion) {
                            Text(appLanguage.string("ota.not_selected")).tag("")
                            ForEach(firmwareManager.entries) { e in
                                Text("\(e.parsedVersion) – \((e.pathDisplay as NSString).lastPathComponent)")
                                    .tag(e.parsedVersion)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minWidth: 200, alignment: .leading)
                        .onChange(of: firmwareVersion) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "production_test_firmware_version")
                            NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                        }
                        
                        Spacer()
                    }
                    
                    Text(appLanguage.string("production_test_rules.firmware_version_hint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 112)
                    
                    if firmwareManager.entries.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            Text(appLanguage.string("production_test_rules.firmware_version_no_entries"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 112)
                    }
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    // 固件版本升级开关（靠右对齐）
                    HStack(spacing: 12) {
                        Text(appLanguage.string("production_test_rules.firmware_upgrade_enabled"))
                            .font(.body)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        Toggle("", isOn: $firmwareUpgradeEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: firmwareUpgradeEnabled) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "production_test_firmware_upgrade_enabled")
                                NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                            }
                    }
                }
                
                // HW 版本
                HStack(spacing: 12) {
                    Text(appLanguage.string("production_test_rules.hardware_version_label"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)
                    
                    TextField(
                        appLanguage.string("production_test_rules.hardware_version_placeholder"),
                        text: $hardwareVersion
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onChange(of: hardwareVersion) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "production_test_hardware_version")
                        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                    }
                }
                
                // SN 验证提示（另起一行，小字体）
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(appLanguage.string("production_test_rules.serial_number_hint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
                
                Divider()
                    .padding(.vertical, 4)
                
                // 超时配置（步骤2：设备信息/OTA/重连等）
                Text(appLanguage.string("production_test_rules.timeouts"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                
                thresholdRow(
                    label: appLanguage.string("production_test_rules.device_info_timeout"),
                    value: $deviceInfoReadTimeout,
                    unit: appLanguage.string("production_test_rules.unit_seconds"),
                    key: "production_test_device_info_timeout"
                )
                thresholdRow(
                    label: appLanguage.string("production_test_rules.ota_start_timeout"),
                    value: $otaStartWaitTimeout,
                    unit: appLanguage.string("production_test_rules.unit_seconds"),
                    key: "production_test_ota_start_timeout"
                )
                thresholdRow(
                    label: appLanguage.string("production_test_rules.reconnect_timeout"),
                    value: $deviceReconnectTimeout,
                    unit: appLanguage.string("production_test_rules.unit_seconds"),
                    key: "production_test_reconnect_timeout"
                )
            }
        }
        .padding(8)
    }
    
    /// RTC配置视图（步骤3）
    private var rtcConfigurationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appLanguage.string("production_test_rules.rtc_time_diff"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                thresholdRow(
                    label: appLanguage.string("production_test_rules.rtc_pass_threshold"),
                    value: $rtcTimeDiffPassThreshold,
                    unit: appLanguage.string("production_test_rules.unit_seconds"),
                    key: "production_test_rtc_pass_threshold"
                )
                thresholdRow(
                    label: appLanguage.string("production_test_rules.rtc_fail_threshold"),
                    value: $rtcTimeDiffFailThreshold,
                    unit: appLanguage.string("production_test_rules.unit_seconds"),
                    key: "production_test_rtc_fail_threshold"
                )
                
                Divider()
                    .padding(.vertical, 4)
                
                // RTC写入开关（靠右对齐）
                HStack(spacing: 12) {
                    Text(appLanguage.string("production_test_rules.rtc_write_enabled"))
                        .font(.body)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    Toggle("", isOn: $rtcWriteEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: rtcWriteEnabled) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "production_test_rtc_write_enabled")
                            NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                        }
                }
                
                if rtcWriteEnabled {
                    thresholdIntRow(
                        label: appLanguage.string("production_test_rules.rtc_write_retry_count"),
                        value: $rtcWriteRetryCount,
                        key: "production_test_rtc_write_retry_count"
                    )
                    .padding(.leading, 32) // 缩进以显示层级关系
                }
                
                thresholdRow(
                    label: appLanguage.string("production_test_rules.rtc_read_timeout"),
                    value: $rtcReadTimeout,
                    unit: appLanguage.string("production_test_rules.unit_seconds"),
                    key: "production_test_rtc_read_timeout"
                )
            }
        }
        .padding(8)
    }
    
    /// 压力配置视图（步骤4）
    private var pressureConfigurationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appLanguage.string("production_test_rules.pressure_thresholds"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                thresholdRow(
                    label: appLanguage.string("production_test_rules.pressure_closed_min"),
                    value: $pressureClosedMin,
                    unit: appLanguage.string("production_test_rules.unit_mbar"),
                    key: "production_test_pressure_closed_min"
                )
                thresholdRow(
                    label: appLanguage.string("production_test_rules.pressure_closed_max"),
                    value: $pressureClosedMax,
                    unit: appLanguage.string("production_test_rules.unit_mbar"),
                    key: "production_test_pressure_closed_max"
                )
                thresholdRow(
                    label: appLanguage.string("production_test_rules.pressure_open_min"),
                    value: $pressureOpenMin,
                    unit: appLanguage.string("production_test_rules.unit_mbar"),
                    key: "production_test_pressure_open_min"
                )
                thresholdRow(
                    label: appLanguage.string("production_test_rules.pressure_open_max"),
                    value: $pressureOpenMax,
                    unit: appLanguage.string("production_test_rules.unit_mbar"),
                    key: "production_test_pressure_open_max"
                )
                
                Divider()
                    .padding(.vertical, 4)
                
                // 压力差值检查
                HStack(spacing: 12) {
                    Toggle("", isOn: $pressureDiffCheckEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: pressureDiffCheckEnabled) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "production_test_pressure_diff_check_enabled")
                            NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                        }
                    
                    Text(appLanguage.string("production_test_rules.pressure_diff_check"))
                        .font(.body)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                }
                
                if pressureDiffCheckEnabled {
                    thresholdRow(
                        label: appLanguage.string("production_test_rules.pressure_diff_min"),
                        value: $pressureDiffMin,
                        unit: appLanguage.string("production_test_rules.unit_mbar"),
                        key: "production_test_pressure_diff_min"
                    )
                    .padding(.leading, 32)
                    thresholdRow(
                        label: appLanguage.string("production_test_rules.pressure_diff_max"),
                        value: $pressureDiffMax,
                        unit: appLanguage.string("production_test_rules.unit_mbar"),
                        key: "production_test_pressure_diff_max"
                    )
                    .padding(.leading, 32)
                }
                
                Divider()
                    .padding(.vertical, 4)
                
                // 阀门打开超时（步骤4相关）
                thresholdRow(
                    label: appLanguage.string("production_test_rules.valve_open_timeout"),
                    value: $valveOpenTimeout,
                    unit: appLanguage.string("production_test_rules.unit_seconds"),
                    key: "production_test_valve_open_timeout"
                )
            }
        }
        .padding(8)
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
    ProductionTestRulesView(ble: BLEManager(), firmwareManager: FirmwareManager.shared)
        .environmentObject(AppLanguage())
        .frame(width: 720, height: 500)
}
