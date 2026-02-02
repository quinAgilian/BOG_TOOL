import SwiftUI

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
    
    var body: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.md) {
            Text(appLanguage.string("debug.title"))
                .font(UIDesignSystem.Typography.sectionTitle)
            
            // 连接/断开按钮区域
            connectionSection

            rtcSection
            valveSection
            pressureSection
            gasSystemStatusSection
            co2PressureLimitsSection
            // 谁调用的 OTA 谁管理：产测 OTA 进行中时 Debug 区不随动，仅提示切回产测
            if ble.isOTAInProgress && ble.otaInitiatedByProductionTest {
                productionTestOTAInProgressHint
            } else {
                OTASectionView(ble: ble, firmwareManager: firmwareManager)
            }
            UUIDDebugView(ble: ble)

            if ble.isConnected {
                HStack(spacing: UIDesignSystem.Spacing.md) {
                    Text(appLanguage.string("debug.current_pressure"))
                    Text(ble.lastPressureValue)
                    Text("|")
                    Text(ble.lastPressureOpenValue)
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .padding(.horizontal, UIDesignSystem.Padding.sm)
                        .padding(.vertical, UIDesignSystem.Padding.xs)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(UIDesignSystem.CornerRadius.sm)
                }

                VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
                    Text(appLanguage.string("debug.device_rtc"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text(ble.lastRTCValue)
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .padding(.horizontal, UIDesignSystem.Padding.sm)
                        .padding(.vertical, UIDesignSystem.Padding.xs)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(UIDesignSystem.CornerRadius.sm)
                }
            }
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
