import SwiftUI

/// 产测 / Debug 区域内操作按钮统一宽度，并右对齐
let actionButtonWidth: CGFloat = 96

/// Debug 模式：RTC / 阀门 / 压力 区域 + 原有电磁阀与设备 RTC
struct DebugModeView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    /// Debug 下 RTC 轮询间隔（秒）
    private let rtcPollInterval: UInt64 = 2_000_000_000  // 2 秒
    
    /// 系统当前时间（按秒更新，仅 UI）
    @State private var systemTimeString: String = "--"
    /// 设备时间占位（仅 UI，逻辑未实现）
    @State private var deviceTimeString: String = "--"
    /// 与系统时间差占位（仅 UI，逻辑未实现）
    @State private var timeDiffString: String = "--"
    
    /// 阀门状态显示（仅 UI，逻辑未实现）
    @State private var valveStateString: String = "--"
    /// 阀门 UI 假定状态，用于按钮显示「开」或「关闭」（仅 UI）
    @State private var valveButtonIsOpen: Bool = false
    
    /// 开阀压力、关阀压力（仅 UI，逻辑未实现）
    @State private var pressureOpenString: String = "--"
    @State private var pressureClosedString: String = "--"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appLanguage.string("debug.title"))
                .font(.headline)

            rtcSection
            valveSection
            pressureSection
            OTASectionView(ble: ble)

            if ble.isConnected {
                HStack(spacing: 8) {
                    Text(appLanguage.string("debug.current_pressure"))
                    Text(ble.lastPressureValue)
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
                .task(id: ble.isConnected) {
                    guard ble.isConnected else { return }
                    while !Task.isCancelled && ble.isConnected {
                        ble.writeRTCTrigger(hexString: "01")
                        try? await Task.sleep(nanoseconds: rtcPollInterval)
                    }
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
                    Text(systemTimeString)
                        .font(.system(.caption, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(6)
                Spacer(minLength: 8)
                Button {
                    // TODO: 手动触发写入 RTC 逻辑
                } label: {
                    Text(appLanguage.string("debug.write_rtc"))
                        .frame(minWidth: actionButtonWidth, maxWidth: actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected)
            }

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text(appLanguage.string("debug.device_time"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(deviceTimeString)
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
                    Text(timeDiffString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
        .task {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            formatter.locale = Locale(identifier: "zh_CN")
            while !Task.isCancelled {
                systemTimeString = formatter.string(from: Date())
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    
    // MARK: - 阀门区域（仅 UI）
    
    private var valveSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(appLanguage.string("debug.valve"))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 5) {
                    Text(appLanguage.string("debug.valve_state"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(valveStateString)
                        .font(.system(.caption, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(6)
                Spacer(minLength: 8)
                Button {
                    valveButtonIsOpen.toggle()
                } label: {
                    Text(valveButtonIsOpen ? appLanguage.string("debug.valve_close") : appLanguage.string("debug.valve_open"))
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
                        Text(pressureOpenString)
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
                        Text(pressureClosedString)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(6)
                }
                Spacer(minLength: 8)
                Button {
                    // TODO: 读取两个压力值逻辑
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
