import SwiftUI
import AppKit

/// 应用模式：产测 / Debug，切换时互斥折叠另一项
enum AppMode: String, CaseIterable {
    case productionTest = "productionTest"
    case debug = "debug"

    /// 用于 UI 显示的本地化 key
    var localizationKey: String {
        switch self {
        case .productionTest: return "mode.production_test"
        case .debug: return "mode.debug"
        }
    }
}

/// 通过挂到窗口层级上的 NSView 设置窗口是否置顶（Floating），并启用窗口位置/尺寸持久化
private struct WindowLevelSetter: NSViewRepresentable {
    var floating: Bool
    
    func makeNSView(context: Context) -> NSView {
        NSView()
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        window.level = floating ? .floating : .normal
        // 启用窗口 frame 自动保存/恢复，用户调整大小或位置后下次启动会沿用
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("BOG_TOOL_MainWindow")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var appLanguage: AppLanguage
    @StateObject private var ble = BLEManager()
    @State private var selectedMode: AppMode = .productionTest
    /// 是否开启日志自动滚动到底部，默认开启
    @State private var logAutoScrollEnabled = true
    /// 上次执行自动滚动的时刻，用于节流（避免刷屏时无法控制）
    @State private var lastAutoScrollDate: Date = .distantPast

    var body: some View {
        HSplitView {
            // 左侧：设备与模式
            VStack(alignment: .leading, spacing: 0) {
                DeviceListView(ble: ble)

                Divider()

                Picker(appLanguage.string("mode.picker_label"), selection: $selectedMode) {
                    ForEach(AppMode.allCases, id: \.self) { mode in
                        Text(appLanguage.string(mode.localizationKey)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

                // 设备基础信息：连接后显示在模式选择下方、模式内容上方，保证可见
                if ble.isConnected {
                    DeviceInfoStrip(ble: ble)
                }

                ScrollView {
                    Group {
                        switch selectedMode {
                        case .productionTest:
                            ProductionTestView(ble: ble)
                        case .debug:
                            DebugModeView(ble: ble)
                        }
                    }
                    .padding(6)
                }
                .frame(minWidth: 320)
            }
            .frame(minWidth: 360)

            // 右侧：日志
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(appLanguage.string("log.title"))
                        .font(.headline)
                    Spacer()
                    Button(appLanguage.switchButtonTitle, action: { appLanguage.toggle() })
                        .buttonStyle(.bordered)
                    Button(appLanguage.string("log.pin_top")) {
                        appSettings.windowFloating = !appSettings.windowFloating
                        applyWindowFloating(appSettings.windowFloating)
                    }
                    .buttonStyle(PinTopButtonStyle(isFloating: appSettings.windowFloating))
                    .keyboardShortcut(.space, modifiers: [])
                    Toggle(isOn: $logAutoScrollEnabled) {
                        Text(appLanguage.string("log.auto_scroll"))
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .help(appLanguage.string("log.auto_scroll_hint"))
                    Button(appLanguage.string("log.clear")) {
                        ble.clearLog()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor))
                
                // 日志等级过滤
                LogLevelFilterView(ble: ble)
                
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(ble.displayedLogEntries) { entry in
                                Text(entry.line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(LogLevelColor.color(entry.level))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(5)
                        .id(0)
                    }
                    .onChange(of: ble.logEntries.count, perform: { _ in
                        guard logAutoScrollEnabled else { return }
                        let now = Date()
                        if now.timeIntervalSince(lastAutoScrollDate) >= 0.4 {
                            proxy.scrollTo(0, anchor: .bottom)
                            lastAutoScrollDate = now
                        }
                    })
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(minWidth: 380)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(WindowLevelSetter(floating: appSettings.windowFloating))
        .onAppear {
            // 启动时先激活窗口，再设置置顶，否则未激活时 level 可能不生效
            NSApp.activate(ignoringOtherApps: true)
            applyWindowFloating(appSettings.windowFloating)
        }
    }
    
    private func applyWindowFloating(_ floating: Bool) {
        let level: NSWindow.Level = floating ? .floating : .normal
        (NSApp.keyWindow ?? NSApp.mainWindow)?.level = level
    }
}

/// 设备基础信息条：连接后显示在产测/Debug 模式下方（SN、FW、制造商等）
private struct DeviceInfoStrip: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager

    private var hasAnyInfo: Bool {
        ble.deviceSerialNumber != nil || ble.currentFirmwareVersion != nil
            || ble.deviceManufacturer != nil || ble.deviceModelNumber != nil || ble.deviceHardwareRevision != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appLanguage.string("device_info.title"))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            if hasAnyInfo {
                HStack(alignment: .top, spacing: 12) {
                    if let v = ble.deviceSerialNumber {
                        item(appLanguage.string("device_info.sn"), v)
                    }
                    if let v = ble.currentFirmwareVersion {
                        item(appLanguage.string("device_info.fw"), v)
                    }
                    if let v = ble.deviceManufacturer {
                        item(appLanguage.string("device_info.manufacturer"), v)
                    }
                    if let v = ble.deviceModelNumber {
                        item(appLanguage.string("device_info.model"), v)
                    }
                    if let v = ble.deviceHardwareRevision {
                        item(appLanguage.string("device_info.hw"), v)
                    }
                }
                .font(.system(.caption, design: .monospaced))
            } else {
                Text(appLanguage.string("device_info.loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func item(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(label):")
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// 日志等级对应颜色（DEBUG 用 secondary 避免白字在浅色背景下不可见）
private enum LogLevelColor {
    static func color(_ level: BLEManager.LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// 日志等级过滤：Debug / Info / Warning / Error 勾选
private struct LogLevelFilterView: View {
    @ObservedObject var ble: BLEManager
    @EnvironmentObject private var appLanguage: AppLanguage
    
    var body: some View {
        HStack(spacing: 12) {
            Text(appLanguage.string("log.level"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle(isOn: $ble.showLogLevelDebug) {
                Text(appLanguage.string("log.level_debug"))
                    .font(.caption)
                    .foregroundStyle(LogLevelColor.color(BLEManager.LogLevel.debug))
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $ble.showLogLevelInfo) {
                Text(appLanguage.string("log.level_info"))
                    .font(.caption)
                    .foregroundStyle(LogLevelColor.color(BLEManager.LogLevel.info))
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $ble.showLogLevelWarning) {
                Text(appLanguage.string("log.level_warning"))
                    .font(.caption)
                    .foregroundStyle(LogLevelColor.color(BLEManager.LogLevel.warning))
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $ble.showLogLevelError) {
                Text(appLanguage.string("log.level_error"))
                    .font(.caption)
                    .foregroundStyle(LogLevelColor.color(BLEManager.LogLevel.error))
            }
            .toggleStyle(.checkbox)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 置顶按钮样式：根据是否置顶返回 .borderedProminent 或 .bordered，避免三元运算符类型推断问题
private struct PinTopButtonStyle: ButtonStyle {
    var isFloating: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isFloating ? Color.accentColor : Color.clear)
            .foregroundStyle(isFloating ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor.opacity(isFloating ? 0 : 0.5), lineWidth: 1))
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings())
        .environmentObject(AppLanguage())
}
