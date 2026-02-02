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
    @StateObject private var firmwareManager = FirmwareManager.shared
    @State private var selectedMode: AppMode = .productionTest
    @State private var showFirmwareManager = false
    /// 是否显示日志区域，默认开启
    @State private var showLogArea = true
    /// 是否开启日志自动滚动到底部，默认开启
    @State private var logAutoScrollEnabled = true
    /// 上次执行自动滚动的时刻，用于节流（避免刷屏时无法控制）
    @State private var lastAutoScrollDate: Date = .distantPast

    /// 产测 OTA：在收到设备返回 OTA Status 1 后再显示弹窗，或处于完成/失败/取消/已重启等终态时显示
    private var showProductionTestOTAOverlay: Bool {
        selectedMode == .productionTest
            && ble.otaInitiatedByProductionTest
            && (ble.otaStatus1ReceivedFromDevice || ble.isOTACompletedWaitingReboot || ble.isOTAFailed || ble.isOTACancelled || ble.isOTARebootDisconnected)
    }

    /// 日志区富文本（按等级着色：INFO 蓝、WARN 黄、ERROR 红，支持全选与自由拖选）
    private var logAreaAttributedContent: AttributedString {
        var result = AttributedString()
        for entry in ble.displayedLogEntries {
            var segment = AttributedString(entry.line + "\n")
            segment.foregroundColor = LogLevelColor.color(entry.level)
            result.append(segment)
        }
        if let progress = ble.otaProgressLogLine {
            var segment = AttributedString(progress)
            segment.foregroundColor = .blue
            result.append(segment)
        }
        return result
    }

    var body: some View {
        HSplitView {
            // 左侧：设备与模式
            VStack(alignment: .leading, spacing: 0) {
                // 顶部工具栏：中英文切换、日志区域开关（置顶开关在菜单栏）
                HStack {
                    Spacer()
                    Button(appLanguage.switchButtonTitle, action: { appLanguage.toggle() })
                        .buttonStyle(.bordered)
                    Button(showLogArea ? appLanguage.string("log.hide_area") : appLanguage.string("log.show_area")) {
                        showLogArea.toggle()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, UIDesignSystem.Padding.lg)
                .padding(.vertical, UIDesignSystem.Padding.sm)
                
                DeviceListView(ble: ble, selectedMode: selectedMode, firmwareManager: firmwareManager)

                Divider()

                Picker(appLanguage.string("mode.picker_label"), selection: $selectedMode) {
                    ForEach(AppMode.allCases, id: \.self) { mode in
                        Text(appLanguage.string(mode.localizationKey)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, UIDesignSystem.Padding.lg)
                .padding(.vertical, UIDesignSystem.Padding.sm)

                // 设备基础信息：连接后显示在模式选择下方、模式内容上方，保证可见
                if ble.isConnected {
                    DeviceInfoStrip(ble: ble)
                }

                ScrollView {
                    Group {
                        switch selectedMode {
                        case .productionTest:
                            ProductionTestView(ble: ble, firmwareManager: firmwareManager)
                        case .debug:
                            DebugModeView(ble: ble, firmwareManager: firmwareManager)
                        }
                    }
                    .padding(UIDesignSystem.Padding.sm)
                }
                .frame(minWidth: 320)
            }
            .frame(minWidth: UIDesignSystem.Window.leftPanelMinWidth)
            .overlay {
                if showProductionTestOTAOverlay {
                    ProductionTestOTAOverlay(ble: ble, firmwareManager: firmwareManager)
                        .environmentObject(appLanguage)
                }
            }

            // 右侧：日志
            if showLogArea {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(appLanguage.string("log.title"))
                            .font(UIDesignSystem.Typography.sectionTitle)
                        Spacer()
                        Toggle(isOn: $logAutoScrollEnabled) {
                            Text(appLanguage.string("log.auto_scroll"))
                                .font(UIDesignSystem.Typography.caption)
                        }
                        .toggleStyle(.checkbox)
                        .help(appLanguage.string("log.auto_scroll_hint"))
                        Button(appLanguage.string("log.clear")) {
                            ble.clearLog()
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, UIDesignSystem.Padding.md)
                    .padding(.vertical, UIDesignSystem.Padding.xs)
                    .background(UIDesignSystem.Background.window)
                    
                    // 日志等级过滤
                    LogLevelFilterView(ble: ble)
                    
                    ScrollViewReader { proxy in
                        ScrollView {
                            // 整块富文本显示，按等级着色，支持全选（Cmd+A）和自由拖选
                            Text(logAreaAttributedContent)
                                .font(UIDesignSystem.Typography.monospacedCaption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(UIDesignSystem.Padding.sm)
                                .id("logContent")
                        }
                        .onChange(of: ble.logEntries.count, perform: { _ in
                            guard logAutoScrollEnabled else { return }
                            let now = Date()
                            if now.timeIntervalSince(lastAutoScrollDate) >= 0.4 {
                                proxy.scrollTo("logContent", anchor: .bottom)
                                lastAutoScrollDate = now
                            }
                        })
                        .onChange(of: ble.otaProgressLogLine) { _ in
                            guard logAutoScrollEnabled else { return }
                            proxy.scrollTo("logContent", anchor: .bottom)
                        }
                    }
                    .background(UIDesignSystem.Background.text)
                }
                .frame(minWidth: UIDesignSystem.Window.rightPanelMinWidth)
            }
        }
        .frame(minWidth: UIDesignSystem.Window.minWidth, minHeight: UIDesignSystem.Window.minHeight)
        .background(WindowLevelSetter(floating: appSettings.windowFloating))
        .onAppear {
            // 启动时先激活窗口，再设置置顶，否则未激活时 level 可能不生效
            NSApp.activate(ignoringOtherApps: true)
            applyWindowFloating(appSettings.windowFloating)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFirmwareManager)) { _ in
            showFirmwareManager = true
        }
        .sheet(isPresented: $showFirmwareManager) {
            FirmwareManagerView(manager: firmwareManager)
                .environmentObject(appLanguage)
        }
    }
    
    private func applyWindowFloating(_ floating: Bool) {
        let level: NSWindow.Level = floating ? .floating : .normal
        (NSApp.keyWindow ?? NSApp.mainWindow)?.level = level
    }
}

/// 产测 OTA 弹窗：仅覆盖左侧主内容区，不覆盖日志区；成功时自动发 reboot，以设备断开为成功确认
private struct ProductionTestOTAOverlay: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    @ObservedObject var firmwareManager: FirmwareManager

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            OTASectionView(ble: ble, firmwareManager: firmwareManager, isModal: true, isProductionTestOTA: true)
        }
        .onChange(of: ble.isOTACompletedWaitingReboot) { newValue in
            if newValue { ble.sendReboot() }
        }
    }
}

/// 设备基础信息条：连接后显示在产测/Debug 模式下方（SN、FW、制造商等）
private struct DeviceInfoStrip: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager

    private var hasAnyInfo: Bool {
        ble.deviceSerialNumber != nil || ble.currentFirmwareVersion != nil || ble.bootloaderVersion != nil
            || ble.deviceManufacturer != nil || ble.deviceModelNumber != nil || ble.deviceHardwareRevision != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
            Text(appLanguage.string("device_info.title"))
                .font(UIDesignSystem.Typography.subsectionTitle)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            if hasAnyInfo {
                HStack(alignment: .top, spacing: UIDesignSystem.Spacing.lg) {
                    if let v = ble.deviceSerialNumber {
                        item(appLanguage.string("device_info.sn"), v)
                    }
                    if let v = ble.bootloaderVersion {
                        item(appLanguage.string("device_info.bootloader"), v)
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
                .font(UIDesignSystem.Typography.monospacedCaption)
            } else if ble.isConnected && ble.areCharacteristicsReady {
                Text(appLanguage.string("device_info.not_available"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
            } else {
                Text(appLanguage.string("device_info.loading"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
            }
        }
        .padding(UIDesignSystem.Padding.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
        .padding(.horizontal, UIDesignSystem.Padding.lg)
        .padding(.vertical, UIDesignSystem.Padding.xs)
    }

    private func item(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UIDesignSystem.Spacing.xs) {
            Text("\(label):")
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            Text(value)
        }
    }
}

/// 日志等级对应颜色：INFO 蓝、WARN 黄、ERROR 红、DEBUG 灰
private enum LogLevelColor {
    static func color(_ level: BLEManager.LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .yellow
        case .error: return .red
        }
    }
}

/// 日志等级过滤：Debug / Info / Warning / Error 勾选
private struct LogLevelFilterView: View {
    @ObservedObject var ble: BLEManager
    @EnvironmentObject private var appLanguage: AppLanguage
    
    var body: some View {
        HStack(spacing: UIDesignSystem.Spacing.lg) {
            Text(appLanguage.string("log.level"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            Toggle(isOn: $ble.showLogLevelDebug) {
                Text(appLanguage.string("log.level_debug"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(LogLevelColor.color(BLEManager.LogLevel.debug))
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $ble.showLogLevelInfo) {
                Text(appLanguage.string("log.level_info"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(LogLevelColor.color(BLEManager.LogLevel.info))
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $ble.showLogLevelWarning) {
                Text(appLanguage.string("log.level_warning"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(LogLevelColor.color(BLEManager.LogLevel.warning))
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $ble.showLogLevelError) {
                Text(appLanguage.string("log.level_error"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(LogLevelColor.color(BLEManager.LogLevel.error))
            }
            .toggleStyle(.checkbox)
            Spacer()
        }
        .padding(.horizontal, UIDesignSystem.Padding.md)
        .padding(.vertical, UIDesignSystem.Padding.xs)
        .background(UIDesignSystem.Background.window)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings())
        .environmentObject(AppLanguage())
}
