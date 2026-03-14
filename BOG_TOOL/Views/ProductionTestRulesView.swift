import SwiftUI
import AppKit

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
    
    static let connectDevice = TestStep(id: "step_connect", key: "step1", isLocked: true, enabled: true)
    static let verifyFirmware = TestStep(id: "step_verify_firmware", key: "step2", isLocked: false, enabled: true)
    static let readRTC = TestStep(id: "step_read_rtc", key: "step3", isLocked: false, enabled: true)
    static let readPressure = TestStep(id: "step_read_pressure", key: "step4", isLocked: false, enabled: true)
    /// 屏蔽系统气体自检：向 co2PressureLimits 写入 12 个 0x00（与 Debug 区「Disable diag」共用 BLEManager.writeCo2PressureLimitsZeros）
    static let disableDiag = TestStep(id: "step_disable_diag", key: "step_disable_diag", isLocked: false, enabled: true)
    /// 读取 Gas system status（0 initially closed, 1 ok, 2 leak…；产测要求 1 ok）
    static let readGasSystemStatus = TestStep(id: "step_gas_system_status", key: "step_gas_system_status", isLocked: false, enabled: true)
    /// 气体泄漏检测（开阀压力）：第一个泄漏检测步骤，默认用开阀压力判定；可独立启用与配置
    static let gasLeakOpen = TestStep(id: "step_gas_leak_open", key: "step_gas_leak_open", isLocked: false, enabled: false)
    /// 气体泄漏检测（关阀压力）：第二个泄漏检测步骤，默认用关阀压力判定；可独立启用与配置
    static let gasLeakClosed = TestStep(id: "step_gas_leak_closed", key: "step_gas_leak_closed", isLocked: false, enabled: true)
    static let tbd = TestStep(id: "step5", key: "step5", isLocked: false, enabled: false)
    /// 确保电磁阀是开启的（可调顺序、有使能开关）
    static let ensureValveOpen = TestStep(id: "step_valve", key: "step_valve", isLocked: false, enabled: true)
    /// 重启设备（Testing 特征 0x00000001，固件 1.1.2+ 或 0.x > 0.4.1）；产测中默认禁用且不允许启用，顺序可调
    static let reset = TestStep(id: "step_reset", key: "step_reset", isLocked: false, enabled: false)
    /// 恢复出厂设置（Testing 特征 0x00000002 擦除 NVS，固件 1.1.2+ 或 0.x > 0.4.1）
    static let factoryReset = TestStep(id: "step_factory_reset", key: "step_factory_reset", isLocked: false, enabled: true)
    /// 断开连接前的 OTA 步骤（默认启用，不许用户取消）
    static let otaBeforeDisconnect = TestStep(id: "step_ota", key: "step_ota", isLocked: true, enabled: true)
    static let disconnectDevice = TestStep(id: "step_disconnect", key: "step_disconnect", isLocked: false, enabled: true)
}

/// 规则层：本步失败时是否终止整条产测（return）；不在集合内的步骤失败时仅 break，继续后续步骤。
extension TestStep {
    /// 失败时应终止产测（先执行恢复出厂若已启用再 return）的 step.id 集合；其余步骤失败时只 break。
    static let stepIdsFatalOnFailure: Set<String> = [TestStep.verifyFirmware.id]

    /// 旧版 step id（step1～step4）→ 语义化 id，用于 UserDefaults 加载时迁移。
    static func migrateLegacyStepId(_ id: String) -> String {
        let oldToNew = ["step1": "step_connect", "step2": "step_verify_firmware", "step3": "step_read_rtc", "step4": "step_read_pressure"]
        return oldToNew[id] ?? id
    }

    /// 语义化 id → 旧版 id（供读取旧 UserDefaults 时兼容）。
    static func legacyStepId(for newId: String) -> String? {
        let newToOld = ["step_connect": "step1", "step_verify_firmware": "step2", "step_read_rtc": "step3", "step_read_pressure": "step4"]
        return newToOld[newId]
    }
}

/// 产测规则视图：定义产测SOP（标准操作程序）
struct ProductionTestRulesView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @EnvironmentObject private var serverClient: ServerClient
    @EnvironmentObject private var productionState: ProductionTestState
    @ObservedObject var ble: BLEManager
    @ObservedObject var firmwareManager: FirmwareManager
    
    private let hardwareVersionPresets = ["P02V02R01", "P02V02R00"]
    @State private var bootloaderVersion: String = {
        let v = UserDefaults.standard.string(forKey: "production_test_bootloader_version")
        return (v == nil || v!.isEmpty) ? "2" : v!
    }()
    @State private var firmwareVersion: String = {
        UserDefaults.standard.string(forKey: "production_test_firmware_version") ?? ""
    }()
    @State private var hardwareVersion: String = {
        UserDefaults.standard.string(forKey: "production_test_hardware_version") ?? "P02V02R01"
    }()
    // 固件版本升级开关（默认关闭，仅在用户显式开启时触发 OTA）
    @State private var firmwareUpgradeEnabled: Bool = {
        UserDefaults.standard.object(forKey: "production_test_firmware_upgrade_enabled") as? Bool ?? false
    }()
    @State private var isEditingOrder: Bool = false
    // 步骤展开状态（用于显示配置项）
    @State private var expandedSteps: Set<String> = []
    /// 每步「失败时终止产测」覆盖配置（stepId -> 是否终止）；未在此字典中的步骤沿用 TestStep.stepIdsFatalOnFailure 默认；加载时旧 step1～step4 迁移为语义化 id
    @State private var stepFatalOverrides: [String: Bool] = {
        let raw = UserDefaults.standard.dictionary(forKey: "production_test_steps_fatal_on_failure") as? [String: Bool] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.map { (TestStep.migrateLegacyStepId($0.key), $0.value) })
    }()
    
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
    /// Disable diag 发送完成后等待时间（秒），默认 2
    @State private var disableDiagWaitSeconds: Double = {
        UserDefaults.standard.object(forKey: "production_test_disable_diag_wait_seconds") as? Double ?? 2.0
    }()
    /// Disable diag 轮询 Gas status 时期望的值（0–9，1=ok），默认 1
    @State private var disableDiagExpectedGasStatus: Int = {
        if let i = UserDefaults.standard.object(forKey: "production_test_disable_diag_expected_gas_status") as? Int { return max(0, min(9, i)) }
        if let d = UserDefaults.standard.object(forKey: "production_test_disable_diag_expected_gas_status") as? Double { return max(0, min(9, Int(d))) }
        return 1
    }()
    /// Disable diag 轮询 Gas status 超时（秒），默认 3
    @State private var disableDiagPollTimeoutSeconds: Double = {
        UserDefaults.standard.object(forKey: "production_test_disable_diag_poll_timeout_seconds") as? Double ?? 3.0
    }()
    /// Disable diag 是否轮询 Gas status 直至期望值，默认开启
    @State private var disableDiagPollGasStatusEnabled: Bool = {
        UserDefaults.standard.object(forKey: "production_test_disable_diag_poll_gas_status_enabled") as? Bool ?? true
    }()
    /// 每个测试步骤之间的等待时间（SOP 定义，单位 ms）
    @State private var stepIntervalMs: Int = {
        UserDefaults.standard.object(forKey: "production_test_step_interval_ms") as? Int ?? 100
    }()
    /// 连接设备步骤完成后、下一步前等待秒数（供用户处理系统蓝牙权限/配对弹窗，0=不等待）
    @State private var bluetoothPermissionWaitSeconds: Double = {
        UserDefaults.standard.object(forKey: "production_test_bluetooth_permission_wait_seconds") as? Double ?? 0
    }()
    /// 测试失败时是否跳过恢复出厂设置与安全断开连接（默认不使能）
    @State private var skipFactoryResetAndDisconnectOnFail: Bool = {
        UserDefaults.standard.object(forKey: "production_test_skip_factory_reset_and_disconnect_on_fail") as? Bool ?? false
    }()
    
    // 压力阈值配置（单位：mbar）
    @State private var pressureClosedMin: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_closed_min") as? Double ?? 1000
    }()
    @State private var pressureClosedMax: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_closed_max") as? Double ?? 1350
    }()
    @State private var pressureOpenMin: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_open_min") as? Double ?? 1000
    }()
    @State private var pressureOpenMax: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_open_max") as? Double ?? 1500
    }()
    // 压力差值检查配置
    @State private var pressureDiffCheckEnabled: Bool = {
        UserDefaults.standard.object(forKey: "production_test_pressure_diff_check_enabled") as? Bool ?? true
    }()
    @State private var pressureDiffMin: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_diff_min") as? Double ?? 0
    }()
    @State private var pressureDiffMax: Double = {
        UserDefaults.standard.object(forKey: "production_test_pressure_diff_max") as? Double ?? 400
    }()
    /// 压力读取失败时是否弹窗确认重新测试当前步骤（默认使能）
    @State private var pressureFailRetryConfirmEnabled: Bool = {
        UserDefaults.standard.object(forKey: "production_test_pressure_fail_retry_confirm_enabled") as? Bool ?? true
    }()
    
    // 气体泄漏检测（开阀压力）步骤参数
    @State private var gasLeakOpenPreCloseDurationSeconds: Int = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_open_pre_close_duration_seconds") as? Int ?? 10
    }()
    @State private var gasLeakOpenPostCloseDurationSeconds: Int = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_open_post_close_duration_seconds") as? Int ?? 15
    }()
    @State private var gasLeakOpenIntervalSeconds: Double = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_open_interval_seconds") as? Double ?? 0.5
    }()
    @State private var gasLeakOpenDropThresholdMbar: Double = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_open_drop_threshold_mbar") as? Double ?? 15
    }()
    @State private var gasLeakOpenStartPressureMinMbar: Double = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_open_start_pressure_min_mbar") as? Double ?? 1300
    }()
    @State private var gasLeakOpenRequirePipelineReadyConfirm: Bool = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_open_require_pipeline_ready_confirm") as? Bool ?? true
    }()
    @State private var gasLeakOpenRequireValveClosedConfirm: Bool = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_open_require_valve_closed_confirm") as? Bool ?? true
    }()
    
    // 气体泄漏检测（关阀压力）步骤参数
    @State private var gasLeakClosedPreCloseDurationSeconds: Int = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_pre_close_duration_seconds") as? Int ?? 10
    }()
    @State private var gasLeakClosedPostCloseDurationSeconds: Int = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_post_close_duration_seconds") as? Int ?? 15
    }()
    @State private var gasLeakClosedIntervalSeconds: Double = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_interval_seconds") as? Double ?? 0.5
    }()
    @State private var gasLeakClosedDropThresholdMbar: Double = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_drop_threshold_mbar") as? Double ?? 15
    }()
    @State private var gasLeakClosedStartPressureMinMbar: Double = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_start_pressure_min_mbar") as? Double ?? 1300
    }()
    @State private var gasLeakClosedRequirePipelineReadyConfirm: Bool = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_require_pipeline_ready_confirm") as? Bool ?? true
    }()
    @State private var gasLeakClosedRequireValveClosedConfirm: Bool = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_require_valve_closed_confirm") as? Bool ?? true
    }()
    // 关阀压力 Phase 4：Phase 3 通过后开阀，连续监测，要求在规定时间内压力低于阈值
    @State private var gasLeakClosedPhase4MonitorDurationSeconds: Int = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_phase4_monitor_duration_seconds") as? Int ?? 15
    }()
    @State private var gasLeakClosedPhase4DropWithinSeconds: Int = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_phase4_drop_within_seconds") as? Int ?? 5
    }()
    @State private var gasLeakClosedPhase4PressureBelowMbar: Double = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_phase4_pressure_below_mbar") as? Double ?? 100
    }()
    @State private var gasLeakClosedPhase4Enabled: Bool = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_phase4_enabled") as? Bool ?? true
    }()
    /// 若开阀压力检测通过则自动跳过关阀压力步骤
    @State private var gasLeakSkipClosedWhenOpenPasses: Bool = {
        UserDefaults.standard.object(forKey: "production_test_gas_leak_skip_closed_when_open_passes") as? Bool ?? false
    }()
    /// 漏气 limit 计算基准（开阀）：phase1_avg 或 phase3_first
    @State private var gasLeakOpenLimitSource: String = {
        let raw = UserDefaults.standard.string(forKey: "production_test_gas_leak_open_limit_source")
        return (raw == "phase3_first" ? "phase3_first" : "phase1_avg")
    }()
    /// 漏气 limit 计算基准（关阀）：phase1_avg 或 phase3_first
    @State private var gasLeakClosedLimitSource: String = {
        let raw = UserDefaults.standard.string(forKey: "production_test_gas_leak_closed_limit_source")
        return (raw == "phase3_first" ? "phase3_first" : "phase1_avg")
    }()
    /// 判定线下限（bar），不得低于 0；不论基准选哪个，有效 limit = max(计算值, 此值)
    @State private var gasLeakOpenLimitFloorBar: Double = {
        let v = UserDefaults.standard.object(forKey: "production_test_gas_leak_open_limit_floor_bar") as? Double ?? 0
        return max(0, v)
    }()
    @State private var gasLeakClosedLimitFloorBar: Double = {
        let v = UserDefaults.standard.object(forKey: "production_test_gas_leak_closed_limit_floor_bar") as? Double ?? 0
        return max(0, v)
    }()

    // MARK: - 导入导出：当前规则快照
    private struct RulesSnapshot: Codable {
        struct StepState: Codable {
            var id: String
            var enabled: Bool
            /// 本步失败时是否终止整条产测（true=return，false=break）；nil 表示沿用代码默认（导出时写入实际值便于导入还原）
            var fatalOnFailure: Bool?
        }
        
        var bootloaderVersion: String
        var firmwareVersion: String
        var hardwareVersion: String
        var firmwareUpgradeEnabled: Bool
        
        var rtcTimeDiffPassThreshold: Double
        var rtcTimeDiffFailThreshold: Double
        var rtcWriteEnabled: Bool
        var rtcWriteRetryCount: Int
        var rtcReadTimeout: Double
        var deviceInfoReadTimeout: Double
        var otaStartWaitTimeout: Double
        var deviceReconnectTimeout: Double
        var valveOpenTimeout: Double
        var disableDiagWaitSeconds: Double?
        var disableDiagExpectedGasStatus: Int?
        var disableDiagPollTimeoutSeconds: Double?
        var disableDiagPollGasStatusEnabled: Bool?
        var stepIntervalMs: Int
        var bluetoothPermissionWaitSeconds: Double
        
        var pressureClosedMin: Double
        var pressureClosedMax: Double
        var pressureOpenMin: Double
        var pressureOpenMax: Double
        var pressureDiffCheckEnabled: Bool
        var pressureDiffMin: Double
        var pressureDiffMax: Double
        
        var gasLeakOpenPreCloseDurationSeconds: Int
        var gasLeakOpenPostCloseDurationSeconds: Int
        var gasLeakOpenIntervalSeconds: Double
        var gasLeakOpenDropThresholdMbar: Double
        var gasLeakOpenStartPressureMinMbar: Double
        var gasLeakOpenRequirePipelineReadyConfirm: Bool
        var gasLeakOpenRequireValveClosedConfirm: Bool
        var gasLeakOpenLimitSource: String?
        var gasLeakOpenLimitFloorBar: Double?
        
        var gasLeakClosedPreCloseDurationSeconds: Int
        var gasLeakClosedPostCloseDurationSeconds: Int
        var gasLeakClosedIntervalSeconds: Double
        var gasLeakClosedDropThresholdMbar: Double
        var gasLeakClosedStartPressureMinMbar: Double
        var gasLeakClosedRequirePipelineReadyConfirm: Bool
        var gasLeakClosedRequireValveClosedConfirm: Bool
        var gasLeakClosedLimitSource: String?
        var gasLeakClosedLimitFloorBar: Double?
        /// Phase 4 参数（可选以兼容旧版导出）
        var gasLeakClosedPhase4Enabled: Bool?
        var gasLeakClosedPhase4MonitorDurationSeconds: Int?
        var gasLeakClosedPhase4DropWithinSeconds: Int?
        var gasLeakClosedPhase4PressureBelowMbar: Double?
        var gasLeakSkipClosedWhenOpenPasses: Bool
        
        var steps: [StepState]
    }
    
    // 默认步骤顺序：第一步连接，断开前 OTA，最后一步断开连接；中间含「重启」「恢复出厂」等可调顺序步骤（须在第2步到倒数第二步之间）
    private static let defaultSteps: [TestStep] = [
        .connectDevice,
        .verifyFirmware,
        .readRTC,
        .readPressure,
        .disableDiag,
        .readGasSystemStatus,
        .gasLeakOpen,
        .gasLeakClosed,
        .ensureValveOpen,
        .reset,
        .factoryReset,
        .tbd,
        .otaBeforeDisconnect,
        .disconnectDevice
    ]
    
    @State private var testSteps: [TestStep] = {
        // 从UserDefaults加载保存的顺序和启用状态，如果没有则使用默认值
        let stepMap = [TestStep.connectDevice, .verifyFirmware, .readRTC, .readPressure, .disableDiag, .readGasSystemStatus, .gasLeakOpen, .gasLeakClosed, .tbd, .ensureValveOpen, .reset, .factoryReset, .otaBeforeDisconnect, .disconnectDevice]
            .reduce(into: [:]) { $0[$1.id] = $1 }
        
        // 加载步骤顺序（旧版 step1～step4 迁移为语义化 id）
        var steps: [TestStep] = []
        if let saved = UserDefaults.standard.array(forKey: "production_test_steps_order") as? [String] {
            for id in saved {
                let migratedId = TestStep.migrateLegacyStepId(id)
                if let step = stepMap[migratedId] {
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
        // 迁移：若旧配置中无「读取 Gas system status」步骤，则插入在读取压力之后、确保电磁阀之前
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
        // 迁移：若旧配置中无「重启」「恢复出厂」步骤，则插入在断开连接之前（第2步到倒数第二步之间）
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
        // OTA 步骤必须在「确认固件版本」(step_verify_firmware) 之后
        ProductionTestRulesView.ensureOtaAfterFirmwareVerify(steps: &steps)
        // 重启、恢复出厂只允许在倒数第三步或倒数第二步
        ProductionTestRulesView.ensureResetAndFactoryResetBetweenSecondAndSecondToLast(steps: &steps)
        
        // 加载每个步骤的启用状态（step_ota 不许用户关闭，始终为 true；step_reset 产测中不许启用，始终为 false）；兼容旧版 step1～step4 的 key
        if let enabledDict = UserDefaults.standard.dictionary(forKey: "production_test_steps_enabled") as? [String: Bool] {
            for i in 0..<steps.count {
                if steps[i].id == TestStep.otaBeforeDisconnect.id {
                    steps[i] = TestStep(id: steps[i].id, key: steps[i].key, isLocked: steps[i].isLocked, enabled: true)
                } else if steps[i].id == TestStep.reset.id {
                    steps[i] = TestStep(id: steps[i].id, key: steps[i].key, isLocked: steps[i].isLocked, enabled: false)
                } else {
                    let enabledValue = enabledDict[steps[i].id] ?? TestStep.legacyStepId(for: steps[i].id).flatMap { enabledDict[$0] }
                    if let enabled = enabledValue {
                        steps[i] = TestStep(id: steps[i].id, key: steps[i].key, isLocked: steps[i].isLocked, enabled: enabled)
                    } else if (steps[i].id == TestStep.gasLeakOpen.id || steps[i].id == TestStep.gasLeakClosed.id),
                              let legacyEnabled = enabledDict["step_gas_leak"] {
                        // 迁移：旧单步「气体泄漏检测」的启用状态应用到两个新步骤
                        steps[i] = TestStep(id: steps[i].id, key: steps[i].key, isLocked: steps[i].isLocked, enabled: legacyEnabled)
                    }
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
                VStack(alignment: .leading, spacing: 4) {
                    // 产测流程说明
                    testProcedureSection
                    
                    // 全局延时设定（步骤间延时，适用于整个产测流程）
                    globalStepDelaySection
                    
                    // 测试步骤详情（包含各步骤的配置）
                    testStepsSection
                }
                .padding()
            }
            .disabled(isReadOnly)
        }
        .frame(minWidth: 960, idealWidth: 1100, minHeight: 540)
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(appLanguage.string("production_test_rules.title"))
                    .font(.title2.weight(.semibold))
                
                if isReadOnly {
                    Text(appLanguage.string("production_test_rules.readonly_while_testing"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button {
                        saveRulesToFile()
                    } label: {
                        Text(appLanguage.string("production_test_rules.export_rules"))
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isReadOnly)
                    
                    Button {
                        loadRulesFromFile()
                    } label: {
                        Text(appLanguage.string("production_test_rules.import_rules"))
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isReadOnly)
                    
                    Button {
                        resetToDefaultRules()
                    } label: {
                        Text(appLanguage.string("common.reset_to_default"))
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isReadOnly)
                }
            }
        }
        .padding()
    }

    /// 将所有产测 SOP 规则恢复为默认值
    private func resetToDefaultRules() {
        guard !isReadOnly else { return }
        let defaults = UserDefaults.standard
        // 版本与基础配置
        defaults.removeObject(forKey: "production_test_bootloader_version")
        defaults.removeObject(forKey: "production_test_firmware_version")
        defaults.removeObject(forKey: "production_test_hardware_version")
        defaults.removeObject(forKey: "production_test_firmware_upgrade_enabled")
        // 步骤顺序、启用状态与失败行为
        defaults.removeObject(forKey: "production_test_steps_order")
        defaults.removeObject(forKey: "production_test_steps_enabled")
        defaults.removeObject(forKey: "production_test_steps_fatal_on_failure")
        // 全局延时与失败时跳过行为
        defaults.removeObject(forKey: "production_test_step_interval_ms")
        defaults.removeObject(forKey: "production_test_bluetooth_permission_wait_seconds")
        defaults.removeObject(forKey: "production_test_skip_factory_reset_and_disconnect_on_fail")
        skipFactoryResetAndDisconnectOnFail = false
        // RTC
        defaults.removeObject(forKey: "production_test_rtc_pass_threshold")
        defaults.removeObject(forKey: "production_test_rtc_fail_threshold")
        defaults.removeObject(forKey: "production_test_rtc_write_enabled")
        defaults.removeObject(forKey: "production_test_rtc_write_retry_count")
        defaults.removeObject(forKey: "production_test_rtc_read_timeout")
        // 设备信息 / OTA / 断开重连
        defaults.removeObject(forKey: "production_test_device_info_timeout")
        defaults.removeObject(forKey: "production_test_ota_start_timeout")
        defaults.removeObject(forKey: "production_test_reconnect_timeout")
        defaults.removeObject(forKey: "production_test_valve_open_timeout")
        defaults.removeObject(forKey: "production_test_disable_diag_wait_seconds")
        defaults.removeObject(forKey: "production_test_disable_diag_expected_gas_status")
        defaults.removeObject(forKey: "production_test_disable_diag_poll_timeout_seconds")
        defaults.removeObject(forKey: "production_test_disable_diag_poll_gas_status_enabled")
        // 压力阈值
        defaults.removeObject(forKey: "production_test_pressure_closed_min")
        defaults.removeObject(forKey: "production_test_pressure_closed_max")
        defaults.removeObject(forKey: "production_test_pressure_open_min")
        defaults.removeObject(forKey: "production_test_pressure_open_max")
        defaults.removeObject(forKey: "production_test_pressure_diff_check_enabled")
        defaults.removeObject(forKey: "production_test_pressure_diff_min")
        defaults.removeObject(forKey: "production_test_pressure_diff_max")
        defaults.removeObject(forKey: "production_test_pressure_fail_retry_confirm_enabled")
        // 气体泄漏（开阀）
        defaults.removeObject(forKey: "production_test_gas_leak_open_judgement_source")
        defaults.removeObject(forKey: "production_test_gas_leak_open_pre_close_duration_seconds")
        defaults.removeObject(forKey: "production_test_gas_leak_open_post_close_duration_seconds")
        defaults.removeObject(forKey: "production_test_gas_leak_open_interval_seconds")
        defaults.removeObject(forKey: "production_test_gas_leak_open_drop_threshold_mbar")
        defaults.removeObject(forKey: "production_test_gas_leak_open_alarm_enabled")
        defaults.removeObject(forKey: "production_test_gas_leak_open_alarm_threshold_bar")
        defaults.removeObject(forKey: "production_test_gas_leak_open_require_pipeline_ready_confirm")
        defaults.removeObject(forKey: "production_test_gas_leak_open_require_valve_closed_confirm")
        defaults.removeObject(forKey: "production_test_gas_leak_open_limit_source")
        defaults.removeObject(forKey: "production_test_gas_leak_open_limit_floor_bar")
        // 气体泄漏（关阀）
        defaults.removeObject(forKey: "production_test_gas_leak_closed_judgement_source")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_pre_close_duration_seconds")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_post_close_duration_seconds")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_interval_seconds")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_drop_threshold_mbar")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_alarm_enabled")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_alarm_threshold_bar")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_require_pipeline_ready_confirm")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_require_valve_closed_confirm")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_limit_source")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_limit_floor_bar")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_phase4_enabled")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_phase4_monitor_duration_seconds")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_phase4_drop_within_seconds")
        defaults.removeObject(forKey: "production_test_gas_leak_closed_phase4_pressure_below_mbar")

        // 重置本地状态为初始默认值
        bootloaderVersion = "2"
        firmwareVersion = ""
        hardwareVersion = "P02V02R01"
        firmwareUpgradeEnabled = true
        rtcTimeDiffPassThreshold = 2.0
        rtcTimeDiffFailThreshold = 5.0
        rtcWriteEnabled = true
        rtcWriteRetryCount = 3
        rtcReadTimeout = 2.0
        deviceInfoReadTimeout = 3.0
        otaStartWaitTimeout = 5.0
        deviceReconnectTimeout = 5.0
        valveOpenTimeout = 5.0
        disableDiagWaitSeconds = 2.0
        disableDiagExpectedGasStatus = 1
        disableDiagPollTimeoutSeconds = 3.0
        disableDiagPollGasStatusEnabled = true
        stepIntervalMs = 100
        bluetoothPermissionWaitSeconds = 0
        pressureClosedMin = 1000
        pressureClosedMax = 1350
        pressureOpenMin = 1000
        pressureOpenMax = 1500
        pressureDiffCheckEnabled = true
        pressureDiffMin = 0
        pressureDiffMax = 400
        pressureFailRetryConfirmEnabled = true
        gasLeakOpenPreCloseDurationSeconds = 10
        gasLeakOpenPostCloseDurationSeconds = 15
        gasLeakOpenIntervalSeconds = 0.5
        gasLeakOpenDropThresholdMbar = 15
        gasLeakOpenRequirePipelineReadyConfirm = true
        gasLeakOpenRequireValveClosedConfirm = true
        gasLeakOpenLimitSource = "phase1_avg"
        gasLeakOpenLimitFloorBar = 0
        gasLeakClosedPreCloseDurationSeconds = 10
        gasLeakClosedPostCloseDurationSeconds = 15
        gasLeakClosedIntervalSeconds = 0.5
        gasLeakClosedDropThresholdMbar = 15
        gasLeakClosedRequirePipelineReadyConfirm = true
        gasLeakClosedRequireValveClosedConfirm = true
        gasLeakClosedLimitSource = "phase1_avg"
        gasLeakClosedLimitFloorBar = 0
        gasLeakClosedPhase4Enabled = true
        gasLeakClosedPhase4MonitorDurationSeconds = 15
        gasLeakClosedPhase4DropWithinSeconds = 5
        gasLeakClosedPhase4PressureBelowMbar = 100
        testSteps = Self.defaultSteps
        expandedSteps = []
        isEditingOrder = false

        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
    }

    // MARK: - 规则导出 / 导入
    private func makeSnapshot() -> RulesSnapshot {
        RulesSnapshot(
            bootloaderVersion: bootloaderVersion,
            firmwareVersion: firmwareVersion,
            hardwareVersion: hardwareVersion,
            firmwareUpgradeEnabled: firmwareUpgradeEnabled,
            rtcTimeDiffPassThreshold: rtcTimeDiffPassThreshold,
            rtcTimeDiffFailThreshold: rtcTimeDiffFailThreshold,
            rtcWriteEnabled: rtcWriteEnabled,
            rtcWriteRetryCount: rtcWriteRetryCount,
            rtcReadTimeout: rtcReadTimeout,
            deviceInfoReadTimeout: deviceInfoReadTimeout,
            otaStartWaitTimeout: otaStartWaitTimeout,
            deviceReconnectTimeout: deviceReconnectTimeout,
            valveOpenTimeout: valveOpenTimeout,
            disableDiagWaitSeconds: disableDiagWaitSeconds,
            disableDiagExpectedGasStatus: disableDiagExpectedGasStatus,
            disableDiagPollTimeoutSeconds: disableDiagPollTimeoutSeconds,
            disableDiagPollGasStatusEnabled: disableDiagPollGasStatusEnabled,
            stepIntervalMs: stepIntervalMs,
            bluetoothPermissionWaitSeconds: bluetoothPermissionWaitSeconds,
            pressureClosedMin: pressureClosedMin,
            pressureClosedMax: pressureClosedMax,
            pressureOpenMin: pressureOpenMin,
            pressureOpenMax: pressureOpenMax,
            pressureDiffCheckEnabled: pressureDiffCheckEnabled,
            pressureDiffMin: pressureDiffMin,
            pressureDiffMax: pressureDiffMax,
            gasLeakOpenPreCloseDurationSeconds: gasLeakOpenPreCloseDurationSeconds,
            gasLeakOpenPostCloseDurationSeconds: gasLeakOpenPostCloseDurationSeconds,
            gasLeakOpenIntervalSeconds: gasLeakOpenIntervalSeconds,
            gasLeakOpenDropThresholdMbar: gasLeakOpenDropThresholdMbar,
            gasLeakOpenStartPressureMinMbar: gasLeakOpenStartPressureMinMbar,
            gasLeakOpenRequirePipelineReadyConfirm: gasLeakOpenRequirePipelineReadyConfirm,
            gasLeakOpenRequireValveClosedConfirm: gasLeakOpenRequireValveClosedConfirm,
            gasLeakOpenLimitSource: gasLeakOpenLimitSource,
            gasLeakOpenLimitFloorBar: gasLeakOpenLimitFloorBar,
            gasLeakClosedPreCloseDurationSeconds: gasLeakClosedPreCloseDurationSeconds,
            gasLeakClosedPostCloseDurationSeconds: gasLeakClosedPostCloseDurationSeconds,
            gasLeakClosedIntervalSeconds: gasLeakClosedIntervalSeconds,
            gasLeakClosedDropThresholdMbar: gasLeakClosedDropThresholdMbar,
            gasLeakClosedStartPressureMinMbar: gasLeakClosedStartPressureMinMbar,
            gasLeakClosedRequirePipelineReadyConfirm: gasLeakClosedRequirePipelineReadyConfirm,
            gasLeakClosedRequireValveClosedConfirm: gasLeakClosedRequireValveClosedConfirm,
            gasLeakClosedLimitSource: gasLeakClosedLimitSource,
            gasLeakClosedLimitFloorBar: gasLeakClosedLimitFloorBar,
            gasLeakClosedPhase4Enabled: gasLeakClosedPhase4Enabled,
            gasLeakClosedPhase4MonitorDurationSeconds: gasLeakClosedPhase4MonitorDurationSeconds,
            gasLeakClosedPhase4DropWithinSeconds: gasLeakClosedPhase4DropWithinSeconds,
            gasLeakClosedPhase4PressureBelowMbar: gasLeakClosedPhase4PressureBelowMbar,
            gasLeakSkipClosedWhenOpenPasses: gasLeakSkipClosedWhenOpenPasses,
            steps: testSteps.map { step in
                let fatalDict = UserDefaults.standard.dictionary(forKey: "production_test_steps_fatal_on_failure") as? [String: Bool]
                let fatalVal = fatalDict?[step.id] ?? TestStep.stepIdsFatalOnFailure.contains(step.id)
                return RulesSnapshot.StepState(id: step.id, enabled: step.enabled, fatalOnFailure: fatalVal)
            }
        )
    }

    private func applySnapshot(_ snapshot: RulesSnapshot) {
        guard !isReadOnly else { return }

        let defaults = UserDefaults.standard

        bootloaderVersion = snapshot.bootloaderVersion
        firmwareVersion = snapshot.firmwareVersion
        hardwareVersion = snapshot.hardwareVersion
        firmwareUpgradeEnabled = snapshot.firmwareUpgradeEnabled

        rtcTimeDiffPassThreshold = snapshot.rtcTimeDiffPassThreshold
        rtcTimeDiffFailThreshold = snapshot.rtcTimeDiffFailThreshold
        rtcWriteEnabled = snapshot.rtcWriteEnabled
        rtcWriteRetryCount = snapshot.rtcWriteRetryCount
        rtcReadTimeout = snapshot.rtcReadTimeout
        deviceInfoReadTimeout = snapshot.deviceInfoReadTimeout
        otaStartWaitTimeout = snapshot.otaStartWaitTimeout
        deviceReconnectTimeout = snapshot.deviceReconnectTimeout
        valveOpenTimeout = snapshot.valveOpenTimeout
        disableDiagWaitSeconds = snapshot.disableDiagWaitSeconds ?? 2.0
        disableDiagExpectedGasStatus = max(0, min(9, snapshot.disableDiagExpectedGasStatus ?? 1))
        disableDiagPollTimeoutSeconds = snapshot.disableDiagPollTimeoutSeconds ?? 3.0
        disableDiagPollGasStatusEnabled = snapshot.disableDiagPollGasStatusEnabled ?? true
        stepIntervalMs = snapshot.stepIntervalMs
        bluetoothPermissionWaitSeconds = snapshot.bluetoothPermissionWaitSeconds

        pressureClosedMin = snapshot.pressureClosedMin
        pressureClosedMax = snapshot.pressureClosedMax
        pressureOpenMin = snapshot.pressureOpenMin
        pressureOpenMax = snapshot.pressureOpenMax
        pressureDiffCheckEnabled = snapshot.pressureDiffCheckEnabled
        pressureDiffMin = snapshot.pressureDiffMin
        pressureDiffMax = snapshot.pressureDiffMax

        gasLeakOpenPreCloseDurationSeconds = snapshot.gasLeakOpenPreCloseDurationSeconds
        gasLeakOpenPostCloseDurationSeconds = snapshot.gasLeakOpenPostCloseDurationSeconds
        gasLeakOpenIntervalSeconds = snapshot.gasLeakOpenIntervalSeconds
        gasLeakOpenDropThresholdMbar = snapshot.gasLeakOpenDropThresholdMbar
        gasLeakOpenStartPressureMinMbar = snapshot.gasLeakOpenStartPressureMinMbar
        gasLeakOpenRequirePipelineReadyConfirm = snapshot.gasLeakOpenRequirePipelineReadyConfirm
        gasLeakOpenRequireValveClosedConfirm = snapshot.gasLeakOpenRequireValveClosedConfirm
        gasLeakOpenLimitSource = snapshot.gasLeakOpenLimitSource ?? "phase1_avg"
        gasLeakOpenLimitFloorBar = max(0, snapshot.gasLeakOpenLimitFloorBar ?? 0)

        gasLeakClosedPreCloseDurationSeconds = snapshot.gasLeakClosedPreCloseDurationSeconds
        gasLeakClosedPostCloseDurationSeconds = snapshot.gasLeakClosedPostCloseDurationSeconds
        gasLeakClosedIntervalSeconds = snapshot.gasLeakClosedIntervalSeconds
        gasLeakClosedDropThresholdMbar = snapshot.gasLeakClosedDropThresholdMbar
        gasLeakClosedStartPressureMinMbar = snapshot.gasLeakClosedStartPressureMinMbar
        gasLeakClosedRequirePipelineReadyConfirm = snapshot.gasLeakClosedRequirePipelineReadyConfirm
        gasLeakClosedRequireValveClosedConfirm = snapshot.gasLeakClosedRequireValveClosedConfirm
        gasLeakClosedLimitSource = snapshot.gasLeakClosedLimitSource ?? "phase1_avg"
        gasLeakClosedLimitFloorBar = max(0, snapshot.gasLeakClosedLimitFloorBar ?? 0)
        gasLeakClosedPhase4Enabled = snapshot.gasLeakClosedPhase4Enabled ?? true
        gasLeakClosedPhase4MonitorDurationSeconds = snapshot.gasLeakClosedPhase4MonitorDurationSeconds ?? 15
        gasLeakClosedPhase4DropWithinSeconds = snapshot.gasLeakClosedPhase4DropWithinSeconds ?? 5
        gasLeakClosedPhase4PressureBelowMbar = snapshot.gasLeakClosedPhase4PressureBelowMbar ?? 100
        gasLeakSkipClosedWhenOpenPasses = snapshot.gasLeakSkipClosedWhenOpenPasses

        // 写回 UserDefaults（保持现有 key 语义）
        defaults.set(bootloaderVersion, forKey: "production_test_bootloader_version")
        defaults.set(firmwareVersion, forKey: "production_test_firmware_version")
        defaults.set(hardwareVersion, forKey: "production_test_hardware_version")
        defaults.set(firmwareUpgradeEnabled, forKey: "production_test_firmware_upgrade_enabled")

        defaults.set(rtcTimeDiffPassThreshold, forKey: "production_test_rtc_pass_threshold")
        defaults.set(rtcTimeDiffFailThreshold, forKey: "production_test_rtc_fail_threshold")
        defaults.set(rtcWriteEnabled, forKey: "production_test_rtc_write_enabled")
        defaults.set(rtcWriteRetryCount, forKey: "production_test_rtc_write_retry_count")
        defaults.set(rtcReadTimeout, forKey: "production_test_rtc_read_timeout")
        defaults.set(deviceInfoReadTimeout, forKey: "production_test_device_info_timeout")
        defaults.set(otaStartWaitTimeout, forKey: "production_test_ota_start_timeout")
        defaults.set(deviceReconnectTimeout, forKey: "production_test_reconnect_timeout")
        defaults.set(valveOpenTimeout, forKey: "production_test_valve_open_timeout")
        defaults.set(disableDiagWaitSeconds, forKey: "production_test_disable_diag_wait_seconds")
        defaults.set(disableDiagExpectedGasStatus, forKey: "production_test_disable_diag_expected_gas_status")
        defaults.set(disableDiagPollTimeoutSeconds, forKey: "production_test_disable_diag_poll_timeout_seconds")
        defaults.set(disableDiagPollGasStatusEnabled, forKey: "production_test_disable_diag_poll_gas_status_enabled")
        defaults.set(stepIntervalMs, forKey: "production_test_step_interval_ms")
        defaults.set(bluetoothPermissionWaitSeconds, forKey: "production_test_bluetooth_permission_wait_seconds")

        defaults.set(pressureClosedMin, forKey: "production_test_pressure_closed_min")
        defaults.set(pressureClosedMax, forKey: "production_test_pressure_closed_max")
        defaults.set(pressureOpenMin, forKey: "production_test_pressure_open_min")
        defaults.set(pressureOpenMax, forKey: "production_test_pressure_open_max")
        defaults.set(pressureDiffCheckEnabled, forKey: "production_test_pressure_diff_check_enabled")
        defaults.set(pressureDiffMin, forKey: "production_test_pressure_diff_min")
        defaults.set(pressureDiffMax, forKey: "production_test_pressure_diff_max")

        defaults.set(gasLeakOpenPreCloseDurationSeconds, forKey: "production_test_gas_leak_open_pre_close_duration_seconds")
        defaults.set(gasLeakOpenPostCloseDurationSeconds, forKey: "production_test_gas_leak_open_post_close_duration_seconds")
        defaults.set(gasLeakOpenIntervalSeconds, forKey: "production_test_gas_leak_open_interval_seconds")
        defaults.set(gasLeakOpenDropThresholdMbar, forKey: "production_test_gas_leak_open_drop_threshold_mbar")
        defaults.set(gasLeakOpenStartPressureMinMbar, forKey: "production_test_gas_leak_open_start_pressure_min_mbar")
        defaults.set(gasLeakOpenRequirePipelineReadyConfirm, forKey: "production_test_gas_leak_open_require_pipeline_ready_confirm")
        defaults.set(gasLeakOpenRequireValveClosedConfirm, forKey: "production_test_gas_leak_open_require_valve_closed_confirm")
        defaults.set(gasLeakOpenLimitSource, forKey: "production_test_gas_leak_open_limit_source")
        defaults.set(max(0, gasLeakOpenLimitFloorBar), forKey: "production_test_gas_leak_open_limit_floor_bar")

        defaults.set(gasLeakClosedPreCloseDurationSeconds, forKey: "production_test_gas_leak_closed_pre_close_duration_seconds")
        defaults.set(gasLeakClosedPostCloseDurationSeconds, forKey: "production_test_gas_leak_closed_post_close_duration_seconds")
        defaults.set(gasLeakClosedIntervalSeconds, forKey: "production_test_gas_leak_closed_interval_seconds")
        defaults.set(gasLeakClosedDropThresholdMbar, forKey: "production_test_gas_leak_closed_drop_threshold_mbar")
        defaults.set(gasLeakClosedStartPressureMinMbar, forKey: "production_test_gas_leak_closed_start_pressure_min_mbar")
        defaults.set(gasLeakClosedRequirePipelineReadyConfirm, forKey: "production_test_gas_leak_closed_require_pipeline_ready_confirm")
        defaults.set(gasLeakClosedRequireValveClosedConfirm, forKey: "production_test_gas_leak_closed_require_valve_closed_confirm")
        defaults.set(gasLeakClosedLimitSource, forKey: "production_test_gas_leak_closed_limit_source")
        defaults.set(max(0, gasLeakClosedLimitFloorBar), forKey: "production_test_gas_leak_closed_limit_floor_bar")
        defaults.set(gasLeakClosedPhase4Enabled, forKey: "production_test_gas_leak_closed_phase4_enabled")
        defaults.set(gasLeakClosedPhase4MonitorDurationSeconds, forKey: "production_test_gas_leak_closed_phase4_monitor_duration_seconds")
        defaults.set(gasLeakClosedPhase4DropWithinSeconds, forKey: "production_test_gas_leak_closed_phase4_drop_within_seconds")
        defaults.set(gasLeakClosedPhase4PressureBelowMbar, forKey: "production_test_gas_leak_closed_phase4_pressure_below_mbar")
        defaults.set(gasLeakSkipClosedWhenOpenPasses, forKey: "production_test_gas_leak_skip_closed_when_open_passes")

        // 步骤顺序、启用状态与失败行为
        let ids = snapshot.steps.map { $0.id }
        defaults.set(ids, forKey: "production_test_steps_order")
        let enabledDict = Dictionary(uniqueKeysWithValues: snapshot.steps.map { ($0.id, $0.enabled) })
        defaults.set(enabledDict, forKey: "production_test_steps_enabled")
        var fatalDict = defaults.dictionary(forKey: "production_test_steps_fatal_on_failure") as? [String: Bool] ?? [:]
        for s in snapshot.steps where s.fatalOnFailure != nil {
            fatalDict[s.id] = s.fatalOnFailure!
        }
        if !fatalDict.isEmpty {
            defaults.set(fatalDict, forKey: "production_test_steps_fatal_on_failure")
        }

        // 更新本地状态数组
        var newSteps: [TestStep] = []
        let stepMap = [TestStep.connectDevice, .verifyFirmware, .readRTC, .readPressure, .disableDiag, .readGasSystemStatus, .gasLeakOpen, .gasLeakClosed, .tbd, .ensureValveOpen, .reset, .factoryReset, .otaBeforeDisconnect, .disconnectDevice]
            .reduce(into: [:]) { $0[$1.id] = $1 }
        for s in snapshot.steps {
            if var base = stepMap[s.id] {
                base.enabled = s.enabled
                newSteps.append(base)
            }
        }
        if newSteps.isEmpty {
            newSteps = Self.defaultSteps
        }
        testSteps = newSteps

        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
    }

    private func saveRulesToFile() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedFileTypes = ["json"]
        panel.nameFieldStringValue = "ProductionTestRules.json"

        let snapshot = makeSnapshot()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }

    private func loadRulesFromFile() {
        guard !isReadOnly else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["json"]

        panel.begin { response in
            if response == .OK, let url = panel.url {
                guard let data = try? Data(contentsOf: url) else { return }
                let decoder = JSONDecoder()
                if let snapshot = try? decoder.decode(RulesSnapshot.self, from: data) {
                    applySnapshot(snapshot)
                }
            }
        }
    }
    
    
    private var isReadOnly: Bool {
        productionState.isRunning
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
        VStack(alignment: .leading, spacing: 6) {
            Text(appLanguage.string("production_test_rules.global_step_delay_section"))
                .font(.headline)
                .foregroundStyle(.primary)

            // 步骤间延时（ms）与蓝牙权限等待（s）放在同一行，提升布局利用率
            HStack(alignment: .center, spacing: 8) {
                thresholdIntRow(
                    label: appLanguage.string("production_test_rules.step_interval_ms"),
                    value: $stepIntervalMs,
                    key: "production_test_step_interval_ms"
                )
                .frame(maxWidth: 260, alignment: .leading)

                thresholdRow(
                    label: appLanguage.string("production_test_rules.bluetooth_permission_wait_seconds"),
                    value: $bluetoothPermissionWaitSeconds,
                    unit: appLanguage.string("production_test_rules.unit_seconds"),
                    key: "production_test_bluetooth_permission_wait_seconds"
                )
                .frame(maxWidth: 360, alignment: .leading)
            }
            .controlSize(.small)
            Toggle(isOn: $skipFactoryResetAndDisconnectOnFail) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appLanguage.string("production_test_rules.skip_factory_reset_and_disconnect_on_fail_title"))
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(appLanguage.string("production_test_rules.skip_factory_reset_and_disconnect_on_fail_desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: skipFactoryResetAndDisconnectOnFail) { newValue in
                UserDefaults.standard.set(newValue, forKey: "production_test_skip_factory_reset_and_disconnect_on_fail")
                NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
            }
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
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 180, alignment: .leading)
            
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
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 180, alignment: .leading)
            
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
    
    /// 当前 SOP 是否启用了恢复出厂或重启（二者需支持 reboot/恢复出厂 的固件版本）
    private var productionTestRequiresFirmwareSupportForRebootSteps: Bool {
        testSteps.contains { step in
            (step.id == TestStep.factoryReset.id || step.id == TestStep.reset.id) && step.enabled
        }
    }
    
    /// 产测可选固件列表：仅产线可见的 OTA 固件；当恢复出厂/重启启用时仅包含支持该命令的版本（>=1.1.2 或 0.x>0.4.1），否则为全部
    private var productionTestAllowedFirmwareEntries: [ServerFirmwareItem] {
        let items = firmwareManager.serverItemsForProduction
        if productionTestRequiresFirmwareSupportForRebootSteps {
            return items.filter { Self.firmwareVersionSupportsRebootAndFactoryReset($0.version) }
        }
        return items
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
                    let isEnableLocked = isPositionLocked || step.id == TestStep.otaBeforeDisconnect.id || step.id == TestStep.reset.id // step_ota 不许关闭；step_reset 产测中不许启用，仅隐藏开关
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
                                .disabled(
                                    index <= 1
                                    || (step.id == TestStep.otaBeforeDisconnect.id && index > 0 && testSteps[index - 1].id == TestStep.verifyFirmware.id)
                                    || ((step.id == TestStep.reset.id || step.id == TestStep.factoryReset.id) && index < testSteps.count - 2) // 重启/恢复出厂只能在上移后仍在倒数第二或倒数第三
                                    || (index == testSteps.count - 4 && (testSteps[index - 1].id == TestStep.reset.id || testSteps[index - 1].id == TestStep.factoryReset.id)) // 不能把倒数第三步的重启/恢复出厂顶到更前
                                )
                                
                                Button {
                                    moveStepDown(at: index)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .disabled(
                                    index >= testSteps.count - 2
                                    || (step.id == TestStep.verifyFirmware.id && index + 1 < testSteps.count && testSteps[index + 1].id == TestStep.otaBeforeDisconnect.id)
                                    || ((step.id == TestStep.reset.id || step.id == TestStep.factoryReset.id) && index < testSteps.count - 3) // 重启/恢复出厂只能在下移后仍在倒数第二或倒数第三
                                    || (index == testSteps.count - 4 && (testSteps[index + 1].id == TestStep.reset.id || testSteps[index + 1].id == TestStep.factoryReset.id)) // 不能把倒数第三步的重启/恢复出厂挤到更前
                                )
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
    
    /// OTA 步骤必须在「确认固件版本」(step_verify_firmware) 之后；若违反则把 step_ota 移到 step_verify_firmware 之后
    private static func ensureOtaAfterFirmwareVerify(steps: inout [TestStep]) {
        guard let fwIndex = steps.firstIndex(where: { $0.id == TestStep.verifyFirmware.id }),
              let otaIndex = steps.firstIndex(where: { $0.id == TestStep.otaBeforeDisconnect.id }) else { return }
        if otaIndex <= fwIndex {
            let ota = steps.remove(at: otaIndex)
            let insertIndex = steps.firstIndex(where: { $0.id == TestStep.verifyFirmware.id }).map { $0 + 1 } ?? steps.count - 1
            steps.insert(ota, at: min(insertIndex, steps.count))
        }
    }

    /// 判断给定固件版本字符串是否支持 Testing 重启/恢复出厂（与 BLEManager 规则一致：0.x > 0.4.1，否则 >= 1.1.2）
    private static func firmwareVersionSupportsRebootAndFactoryReset(_ version: String) -> Bool {
        guard !version.isEmpty else { return false }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return false }
        let major = parts[0]
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        if version.hasPrefix("0") {
            if major > 0 { return true }
            if minor > 4 { return true }
            if minor == 4, patch > 1 { return true }
            return false
        }
        if major > 1 { return true }
        if major == 1, minor > 1 { return true }
        if major == 1, minor == 1, patch >= 2 { return true }
        return false
    }
    
    /// 重启、恢复出厂只允许在倒数第三步或倒数第二步（索引 count-3、count-2），不可再往前调
    static func ensureResetAndFactoryResetBetweenSecondAndSecondToLast(steps: inout [TestStep]) {
        let count = steps.count
        guard count >= 4 else { return } // 至少：连接、某一步、重置/恢复出厂、断开
        guard let resetStep = steps.first(where: { $0.id == TestStep.reset.id }),
              let factoryResetStep = steps.first(where: { $0.id == TestStep.factoryReset.id }) else { return }
        let otherSteps = steps.filter { $0.id != TestStep.reset.id && $0.id != TestStep.factoryReset.id }
        guard otherSteps.count == count - 2 else { return }
        // 仅允许在倒数第三、倒数第二步：前面 count-3 个其它步骤 + 重启 + 恢复出厂 + 最后一步断开
        steps = Array(otherSteps.prefix(count - 3)) + [resetStep, factoryResetStep] + Array(otherSteps.suffix(1))
    }
    
    private func moveStep(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }
        
        // 不能移动第一步或最后一步
        guard sourceIndex > 0 && sourceIndex < testSteps.count - 1 else { return }
        // 不能移动到第一步或最后一步的位置
        guard destination > 0 && destination < testSteps.count - 1 else { return }
        
        // 如果目标位置在源位置之后，需要调整索引（因为先删除后插入）
        let adjustedDestination = destination > sourceIndex ? destination - 1 : destination
        let count = testSteps.count
        let resetSlots = [count - 3, count - 2]
        let step = testSteps[sourceIndex]
        let isResetOrFactoryReset = step.id == TestStep.reset.id || step.id == TestStep.factoryReset.id
        // 重启、恢复出厂只能落在倒数第三或倒数第二步
        if isResetOrFactoryReset, !resetSlots.contains(adjustedDestination) { return }
        // 其它步骤不能占倒数第三、倒数第二步
        if !isResetOrFactoryReset, resetSlots.contains(adjustedDestination) { return }
        
        var updatedSteps = testSteps
        let removed = updatedSteps.remove(at: sourceIndex)
        updatedSteps.insert(removed, at: adjustedDestination)
        
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
        Self.ensureResetAndFactoryResetBetweenSecondAndSecondToLast(steps: &updatedSteps)
        
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
        // 重启/恢复出厂只能处于倒数第二或倒数第三步，上移后仍须在此两格
        if (testSteps[index].id == TestStep.reset.id || testSteps[index].id == TestStep.factoryReset.id) && index < testSteps.count - 2 { return }
        // 不能把倒数第三步的重启/恢复出厂顶到更前
        if index == testSteps.count - 4 && (testSteps[index - 1].id == TestStep.reset.id || testSteps[index - 1].id == TestStep.factoryReset.id) { return }
        
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
        // 重启/恢复出厂只能处于倒数第二或倒数第三步，下移后仍须在此两格
        if (testSteps[index].id == TestStep.reset.id || testSteps[index].id == TestStep.factoryReset.id) && index < testSteps.count - 3 { return }
        // 不能把倒数第三步的重启/恢复出厂挤到更前（与下方交换会把它换到 count-4）
        if index == testSteps.count - 4 && (testSteps[index + 1].id == TestStep.reset.id || testSteps[index + 1].id == TestStep.factoryReset.id) { return }
        
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
        enabledDict[TestStep.reset.id] = false // step_reset 产测中不许启用，持久化时强制为 false
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
            
            // 每步可单独设置：失败后终止产测 或 仅本步失败继续后续步骤
            if !isEditingOrder {
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { stepFatalOverrides[step.id] ?? TestStep.stepIdsFatalOnFailure.contains(step.id) },
                        set: { newVal in
                            stepFatalOverrides[step.id] = newVal
                            UserDefaults.standard.set(stepFatalOverrides, forKey: "production_test_steps_fatal_on_failure")
                            NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                        }
                    )) {
                        Text(appLanguage.string("production_test_rules.step_fatal_on_failure_title"))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .toggleStyle(.switch)
                }
                .padding(.vertical, 4)
            }
            
            switch step.id {
            case "step_verify_firmware": // 确认固件版本
                versionConfigurationView
            case "step_read_rtc": // 检查RTC
                rtcConfigurationView
            case "step_read_pressure": // 读取压力值
                pressureConfigurationView
            case "step_disable_diag": // 屏蔽气体自检（Disable diag）
                disableDiagConfigurationView
            case "step_gas_leak_open": // 气体泄漏检测（开阀压力）
                gasLeakOpenConfigurationView
            case "step_gas_leak_closed": // 气体泄漏检测（关阀压力）
                gasLeakClosedConfigurationView
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
                
                // FW 版本：从服务器可用固件列表下拉选择，产测 OTA 步骤直接使用此版本；当恢复出厂/重启启用时仅允许选择支持该命令的版本（>=1.1.2 或 0.x>0.4.1）
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text(appLanguage.string("production_test_rules.firmware_version_label"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .leading)
                        
                        Picker("", selection: $firmwareVersion) {
                            Text(appLanguage.string("ota.not_selected")).tag("")
                            ForEach(productionTestAllowedFirmwareEntries) { e in
                                Text("\(e.version) – \((e.originalFileName ?? e.fileName) as String)")
                                    .tag(e.version)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minWidth: 200, alignment: .leading)
                        .onChange(of: firmwareVersion) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "production_test_firmware_version")
                            NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                        }

                        Button {
                            ble.appendLog("[固件] 产测 SOP 手动刷新 usage_type=ota_app channel=production", level: .info)
                            Task {
                                await firmwareManager.fetchServerFirmware(serverClient: serverClient, channel: "production")
                                await MainActor.run {
                                    let count = firmwareManager.serverItemsForProduction.count
                                    if let err = firmwareManager.serverItemsError {
                                        ble.appendLog("[固件] 产测 channel=production 拉取失败: \(err)", level: .error)
                                    } else {
                                        let versions = firmwareManager.serverItemsForProduction.map(\.version).joined(separator: ", ")
                                        ble.appendLog("[固件] 产测 channel=production 拉取成功 共\(count)条 [\(versions.isEmpty ? "无" : versions)]", level: .info)
                                    }
                                }
                            }
                        } label: {
                            Text(appLanguage.string("ota.refresh_firmware_list"))
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .disabled(firmwareManager.serverItemsLoading)
                    }
                    
                    if productionTestRequiresFirmwareSupportForRebootSteps && !productionTestAllowedFirmwareEntries.isEmpty {
                        Text(appLanguage.string("production_test_rules.firmware_version_reboot_required_hint"))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.leading, 112)
                    }
                    Text(appLanguage.string("production_test_rules.firmware_version_hint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 112)
                    
                    if firmwareManager.serverItemsForProduction.isEmpty {
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
                .onChange(of: productionTestRequiresFirmwareSupportForRebootSteps) { requires in
                    if requires {
                        let allowed = productionTestAllowedFirmwareEntries
                        if !allowed.contains(where: { $0.version == firmwareVersion }) {
                            firmwareVersion = allowed.first?.version ?? ""
                            UserDefaults.standard.set(firmwareVersion, forKey: "production_test_firmware_version")
                            NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                        }
                    }
                }
                .onAppear {
                    // 首次进入时，如需支持 reboot/恢复出厂，自动将版本收紧到支持该命令的服务器固件列表中
                    if productionTestRequiresFirmwareSupportForRebootSteps {
                        let allowed = productionTestAllowedFirmwareEntries
                        if !allowed.contains(where: { $0.version == firmwareVersion }) {
                            firmwareVersion = allowed.first?.version ?? ""
                            UserDefaults.standard.set(firmwareVersion, forKey: "production_test_firmware_version")
                            NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                        }
                    }
                    // 若产线可见固件列表尚为空，则触发一次拉取（channel=production）
                    if firmwareManager.serverItemsForProduction.isEmpty && !firmwareManager.serverItemsLoading {
                        ble.appendLog("[固件] 产测 SOP 拉取 usage_type=ota_app channel=production", level: .info)
                        Task {
                            await firmwareManager.fetchServerFirmware(serverClient: serverClient, channel: "production")
                            await MainActor.run {
                                let count = firmwareManager.serverItemsForProduction.count
                                if let err = firmwareManager.serverItemsError {
                                    ble.appendLog("[固件] 产测 channel=production 拉取失败: \(err)", level: .error)
                                } else {
                                    let versions = firmwareManager.serverItemsForProduction.map(\.version).joined(separator: ", ")
                                    ble.appendLog("[固件] 产测 channel=production 拉取成功 共\(count)条 [\(versions.isEmpty ? "无" : versions)]", level: .info)
                                }
                            }
                        }
                    }
                }
                
                // HW 版本（可输入 + 下拉预设）
                HStack(spacing: 12) {
                    Text(appLanguage.string("production_test_rules.hardware_version_label"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)
                    
                    HStack(spacing: 8) {
                        TextField(
                            appLanguage.string("production_test_rules.hardware_version_placeholder"),
                            text: $hardwareVersion
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onChange(of: hardwareVersion) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "production_test_hardware_version")
                            NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                        }
                        
                        if !hardwareVersionPresets.isEmpty {
                            Menu {
                                ForEach(hardwareVersionPresets, id: \.self) { preset in
                                    Button(preset) {
                                        hardwareVersion = preset
                                        UserDefaults.standard.set(preset, forKey: "production_test_hardware_version")
                                        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .menuStyle(.borderlessButton)
                        }
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
                
                // 超时配置（步骤2：设备信息/OTA/重连等）——两行紧凑布局，避免横向被截断
                Text(appLanguage.string("production_test_rules.timeouts"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 24) {
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
                    }
                    
                    HStack(alignment: .center, spacing: 24) {
                        thresholdRow(
                            label: appLanguage.string("production_test_rules.reconnect_timeout"),
                            value: $deviceReconnectTimeout,
                            unit: appLanguage.string("production_test_rules.unit_seconds"),
                            key: "production_test_reconnect_timeout"
                        )
                        Spacer()
                    }
                }
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
                
                Divider()
                    .padding(.vertical, 4)
                
                Toggle(isOn: $pressureFailRetryConfirmEnabled) {
                    Text(appLanguage.string("production_test_rules.pressure_fail_retry_confirm_title"))
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                .toggleStyle(.switch)
                .onChange(of: pressureFailRetryConfirmEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "production_test_pressure_fail_retry_confirm_enabled")
                    NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                }
            }
        }
        .padding(8)
    }
    
    /// 屏蔽气体自检（Disable diag）步骤配置：发送后等待、是否轮询 Gas status、期望值与超时
    private var disableDiagConfigurationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appLanguage.string("production_test_rules.disable_diag_config_title"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            HStack(spacing: 12) {
                Toggle("", isOn: $disableDiagPollGasStatusEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: disableDiagPollGasStatusEnabled) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "production_test_disable_diag_poll_gas_status_enabled")
                        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                    }
                Text(appLanguage.string("production_test_rules.disable_diag_poll_gas_status_enabled"))
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            thresholdRow(
                label: appLanguage.string("production_test_rules.disable_diag_wait_seconds"),
                value: $disableDiagWaitSeconds,
                unit: appLanguage.string("production_test_rules.unit_seconds"),
                key: "production_test_disable_diag_wait_seconds"
            )
            thresholdIntRow(
                label: appLanguage.string("production_test_rules.disable_diag_expected_gas_status"),
                value: Binding(
                    get: { disableDiagExpectedGasStatus },
                    set: { disableDiagExpectedGasStatus = max(0, min(9, $0)) }
                ),
                key: "production_test_disable_diag_expected_gas_status"
            )
            thresholdRow(
                label: appLanguage.string("production_test_rules.disable_diag_poll_timeout_seconds"),
                value: $disableDiagPollTimeoutSeconds,
                unit: appLanguage.string("production_test_rules.unit_seconds"),
                key: "production_test_disable_diag_poll_timeout_seconds"
            )
        }
        .padding(8)
    }
    
    /// 气体泄漏检测（开阀压力）步骤配置视图
    private var gasLeakOpenConfigurationView: some View {
            gasLeakConfigView(
                preCloseDuration: $gasLeakOpenPreCloseDurationSeconds,
                postCloseDuration: $gasLeakOpenPostCloseDurationSeconds,
                intervalSeconds: $gasLeakOpenIntervalSeconds,
                dropThresholdMbar: $gasLeakOpenDropThresholdMbar,
                startPressureMinMbar: $gasLeakOpenStartPressureMinMbar,
                limitSource: $gasLeakOpenLimitSource,
                limitFloorBar: Binding(
                    get: { gasLeakOpenLimitFloorBar },
                    set: { newVal in
                        let c = max(0, newVal)
                        gasLeakOpenLimitFloorBar = c
                        UserDefaults.standard.set(c, forKey: "production_test_gas_leak_open_limit_floor_bar")
                        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                    }
                ),
                requirePipelineReadyConfirm: $gasLeakOpenRequirePipelineReadyConfirm,
                requireValveClosedConfirm: $gasLeakOpenRequireValveClosedConfirm,
                keyPrefix: "production_test_gas_leak_open"
            )
    }
    
    /// 气体泄漏检测（关阀压力）步骤配置视图
    private var gasLeakClosedConfigurationView: some View {
        VStack(alignment: .leading, spacing: 10) {
            gasLeakConfigView(
                preCloseDuration: $gasLeakClosedPreCloseDurationSeconds,
                postCloseDuration: $gasLeakClosedPostCloseDurationSeconds,
                intervalSeconds: $gasLeakClosedIntervalSeconds,
                dropThresholdMbar: $gasLeakClosedDropThresholdMbar,
                startPressureMinMbar: $gasLeakClosedStartPressureMinMbar,
                limitSource: $gasLeakClosedLimitSource,
                limitFloorBar: Binding(
                    get: { gasLeakClosedLimitFloorBar },
                    set: { newVal in
                        let c = max(0, newVal)
                        gasLeakClosedLimitFloorBar = c
                        UserDefaults.standard.set(c, forKey: "production_test_gas_leak_closed_limit_floor_bar")
                        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                    }
                ),
                requirePipelineReadyConfirm: $gasLeakClosedRequirePipelineReadyConfirm,
                requireValveClosedConfirm: $gasLeakClosedRequireValveClosedConfirm,
                keyPrefix: "production_test_gas_leak_closed"
            )
            
            Divider()
                .padding(.vertical, 4)
            
            // Phase 4：Phase 3 通过后开阀，连续监测，要求在规定时间内开阀压力低于阈值（独立开关）
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Toggle("", isOn: $gasLeakClosedPhase4Enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: gasLeakClosedPhase4Enabled) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "production_test_gas_leak_closed_phase4_enabled")
                            NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                        }
                    Text(appLanguage.string("production_test_rules.gas_leak_closed_phase4_enabled"))
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                Text(appLanguage.string("production_test_rules.gas_leak_closed_phase4_title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    thresholdIntRow(label: appLanguage.string("production_test_rules.gas_leak_closed_phase4_monitor_duration"), value: $gasLeakClosedPhase4MonitorDurationSeconds, key: "production_test_gas_leak_closed_phase4_monitor_duration_seconds")
                    thresholdIntRow(label: appLanguage.string("production_test_rules.gas_leak_closed_phase4_drop_within"), value: $gasLeakClosedPhase4DropWithinSeconds, key: "production_test_gas_leak_closed_phase4_drop_within_seconds")
                    thresholdRow(label: appLanguage.string("production_test_rules.gas_leak_closed_phase4_pressure_below"), value: $gasLeakClosedPhase4PressureBelowMbar, unit: appLanguage.string("production_test_rules.unit_mbar"), key: "production_test_gas_leak_closed_phase4_pressure_below_mbar")
                }
                .padding(8)
            }
            
            Divider()
                .padding(.vertical, 4)
            
            // 开阀压力通过时是否跳过本步骤
            HStack(spacing: 12) {
                Toggle("", isOn: $gasLeakSkipClosedWhenOpenPasses)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: gasLeakSkipClosedWhenOpenPasses) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "production_test_gas_leak_skip_closed_when_open_passes")
                        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                    }
                
                Text(appLanguage.string("production_test_rules.gas_leak_skip_closed_when_open_passes"))
                    .font(.body)
                    .foregroundStyle(.primary)
                
                Spacer()
            }
        }
    }
    
    /// 气体泄漏检测通用配置视图（供开阀/关阀两个步骤复用）
    private func gasLeakConfigView(
        preCloseDuration: Binding<Int>,
        postCloseDuration: Binding<Int>,
        intervalSeconds: Binding<Double>,
        dropThresholdMbar: Binding<Double>,
        startPressureMinMbar: Binding<Double>,
        limitSource: Binding<String>,
        limitFloorBar: Binding<Double>,
        requirePipelineReadyConfirm: Binding<Bool>,
        requireValveClosedConfirm: Binding<Bool>,
        keyPrefix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appLanguage.string("production_test_rules.gas_leak_params_title"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 8) {
                thresholdIntRow(label: appLanguage.string("production_test_rules.gas_leak_pre_close_duration"), value: preCloseDuration, key: "\(keyPrefix)_pre_close_duration_seconds")
                thresholdIntRow(label: appLanguage.string("production_test_rules.gas_leak_post_close_duration"), value: postCloseDuration, key: "\(keyPrefix)_post_close_duration_seconds")
                thresholdRow(label: appLanguage.string("production_test_rules.gas_leak_interval"), value: intervalSeconds, unit: appLanguage.string("production_test_rules.unit_seconds"), key: "\(keyPrefix)_interval_seconds")
                thresholdRow(label: appLanguage.string("production_test_rules.gas_leak_drop_threshold_mbar"), value: dropThresholdMbar, unit: appLanguage.string("production_test_rules.unit_mbar"), key: "\(keyPrefix)_drop_threshold_mbar")
                thresholdRow(label: appLanguage.string("production_test_rules.gas_leak_start_pressure_min"), value: startPressureMinMbar, unit: appLanguage.string("production_test_rules.unit_mbar"), key: "\(keyPrefix)_start_pressure_min_mbar")
                
                HStack(alignment: .center, spacing: 12) {
                    Text(appLanguage.string("production_test_rules.gas_leak_limit_source_title"))
                        .font(.body)
                        .foregroundStyle(.primary)
                    Picker("", selection: limitSource) {
                        Text(appLanguage.string("production_test_rules.gas_leak_limit_source_phase1_avg")).tag("phase1_avg")
                        Text(appLanguage.string("production_test_rules.gas_leak_limit_source_phase3_first")).tag("phase3_first")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: limitSource.wrappedValue) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "\(keyPrefix)_limit_source")
                        NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    thresholdRow(label: appLanguage.string("production_test_rules.gas_leak_limit_floor_bar"), value: limitFloorBar, unit: appLanguage.string("production_test_rules.unit_bar"), key: "\(keyPrefix)_limit_floor_bar")
                    Text(appLanguage.string("production_test_rules.gas_leak_limit_floor_bar_hint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Divider().padding(.vertical, 4)
                Divider().padding(.vertical, 4)
                
                HStack(spacing: 12) {
                    Toggle("", isOn: requirePipelineReadyConfirm)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: requirePipelineReadyConfirm.wrappedValue) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "\(keyPrefix)_require_pipeline_ready_confirm")
                            NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                        }
                    Text(appLanguage.string("production_test_rules.gas_leak_require_pipeline_ready_confirm"))
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                
                HStack(spacing: 12) {
                    Toggle("", isOn: requireValveClosedConfirm)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: requireValveClosedConfirm.wrappedValue) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "\(keyPrefix)_require_valve_closed_confirm")
                            NotificationCenter.default.post(name: .productionTestRulesDidChange, object: nil)
                        }
                    Text(appLanguage.string("production_test_rules.gas_leak_require_valve_closed_confirm"))
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer()
                }
            }
        }
        .padding(8)
    }
    
}

#Preview {
    ProductionTestRulesView(ble: BLEManager(), firmwareManager: FirmwareManager.shared)
        .environmentObject(AppLanguage())
        .frame(width: 720, height: 500)
}
