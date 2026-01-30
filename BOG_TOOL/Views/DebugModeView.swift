import SwiftUI

/// 产测 / Debug 区域内操作按钮统一宽度，并右对齐
let actionButtonWidth: CGFloat = 96

/// 阀门控制：自动（固件决定开/关） / 手动（用户点开/关）
private enum ValveControlMode: String, CaseIterable {
    case auto
    case manual
}

/// Debug 模式：RTC / 阀门 / 压力 区域 + 原有电磁阀与设备 RTC
struct DebugModeView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    /// 阀门控制：Auto 不显示开/关键，Manual 显示
    @State private var valveControlMode: ValveControlMode = .manual
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appLanguage.string("debug.title"))
                .font(.headline)

            rtcSection
            valveSection
            pressureSection
            OTASectionView(ble: ble)
            UUIDDebugView(ble: ble)

            if ble.isConnected {
                HStack(spacing: 8) {
                    Text(appLanguage.string("debug.current_pressure"))
                    Text(ble.lastPressureValue)
                    Text("|")
                    Text(ble.lastPressureOpenValue)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(5)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(appLanguage.string("debug.device_rtc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ble.lastRTCValue)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(5)
                }
            } else {
                Text(appLanguage.string("debug.connect_first"))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }
    
    // MARK: - RTC 区域（仅 UI）
    
    private var rtcSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(appLanguage.string("debug.rtc"))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 5) {
                    Text(appLanguage.string("debug.system_time"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ble.lastSystemTimeAtRTCRead)
                        .font(.system(.caption, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(6)
                Spacer(minLength: 8)
                Button {
                    ble.writeRTCTrigger(hexString: "01")
                } label: {
                    Text(appLanguage.string("debug.write_rtc"))
                        .frame(minWidth: actionButtonWidth, maxWidth: actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected)
            }

            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 5) {
                    Text(appLanguage.string("debug.device_time"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ble.lastRTCValue)
                        .font(.system(.caption, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(6)

                HStack(spacing: 5) {
                    Text(appLanguage.string("debug.time_diff"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ble.lastTimeDiffFromRTCRead)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    ble.writeTestingUnlock()
                    ble.readRTC()
                } label: {
                    Text(appLanguage.string("debug.read_rtc"))
                        .frame(minWidth: actionButtonWidth, maxWidth: actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || !ble.areCharacteristicsReady)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
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
    
    /// 电磁阀开关：显示当前状态，操作时先读再设；若已是目标状态则警告一次
    private var valveSwitchBinding: Binding<Bool> {
        Binding(
            get: { ble.lastValveStateValue == "open" },
            set: { newValue in ble.setValveAfterReadingState(open: newValue) }
        )
    }
    
    /// Binding 用于 Picker：Auto/Manual 互斥；选 Auto 写 0，选 Manual 按当前阀门状态写开/关
    private var valveControlModeBinding: Binding<ValveControlMode> {
        Binding(
            get: { valveControlMode },
            set: { newValue in
                valveControlMode = newValue
                if newValue == .auto {
                    ble.setValveModeAuto()
                } else if newValue == .manual {
                    // 从 Auto 切到 Manual：按当前阀门状态写入开或关，使设备进入手动并保持当前状态
                    let open = (ble.lastValveStateValue != "closed")
                    ble.setValve(open: open)
                }
            }
        )
    }
    
    private var valveSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(appLanguage.string("debug.valve"))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Text(appLanguage.string("debug.valve_mode"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(valveModeDisplay)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(6)
                    HStack(spacing: 5) {
                        Text(appLanguage.string("debug.valve_state"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(valveStateDisplay)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(6)
                }
                Spacer(minLength: 8)
                Button {
                    ble.readValveMode()
                    ble.readValveState()
                } label: {
                    Text(appLanguage.string("debug.read"))
                        .frame(minWidth: actionButtonWidth, maxWidth: actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || !ble.areCharacteristicsReady)
                Picker("", selection: valveControlModeBinding) {
                    Text(appLanguage.string("debug.valve_control_auto")).tag(ValveControlMode.auto)
                    Text(appLanguage.string("debug.valve_control_manual")).tag(ValveControlMode.manual)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            if valveControlMode == .manual {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text(appLanguage.string("debug.valve_switch"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("", isOn: valveSwitchBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .disabled(!ble.isConnected)
                    if let key = ble.valveOperationWarning, !key.isEmpty {
                        Text(appLanguage.string(key))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 8)
                }
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
        .onReceive(ble.$lastValveModeValue) { newValue in
            if newValue == "auto" { valveControlMode = .auto }
            else if newValue == "open" || newValue == "closed" { valveControlMode = .manual }
        }
    }
    
    // MARK: - 压力区域（仅 UI）
    
    private var pressureSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(appLanguage.string("debug.pressure"))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Text(appLanguage.string("debug.open_pressure"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ble.lastPressureOpenValue)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(6)

                    HStack(spacing: 5) {
                        Text(appLanguage.string("debug.close_pressure"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ble.lastPressureValue)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(6)
                }
                Spacer(minLength: 8)
                Button {
                    ble.readPressure()
                    ble.readPressureOpen()
                } label: {
                    Text(appLanguage.string("debug.read"))
                        .frame(minWidth: actionButtonWidth, maxWidth: actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }
}
