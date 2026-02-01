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
    /// 是否显示日志区域，默认开启
    @State private var showLogArea = true
    /// 是否开启日志自动滚动到底部，默认开启
    @State private var logAutoScrollEnabled = true
    /// 上次执行自动滚动的时刻，用于节流（避免刷屏时无法控制）
    @State private var lastAutoScrollDate: Date = .distantPast

    var body: some View {
        HSplitView {
            // 左侧：设备与模式
            VStack(alignment: .leading, spacing: 0) {
                // 顶部工具栏：中英文切换、置顶按钮和日志区域开关
                HStack {
                    Spacer()
                    Button(appLanguage.switchButtonTitle, action: { appLanguage.toggle() })
                        .buttonStyle(.bordered)
                    Button(appLanguage.string("log.pin_top")) {
                        appSettings.windowFloating = !appSettings.windowFloating
                        applyWindowFloating(appSettings.windowFloating)
                    }
                    .buttonStyle(PinTopButtonStyle(isFloating: appSettings.windowFloating))
                    .keyboardShortcut(.space, modifiers: [])
                    Button(showLogArea ? appLanguage.string("log.hide_area") : appLanguage.string("log.show_area")) {
                        showLogArea.toggle()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, UIDesignSystem.Padding.lg)
                .padding(.vertical, UIDesignSystem.Padding.sm)
                
                DeviceListView(ble: ble, selectedMode: selectedMode)

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
                            ProductionTestView(ble: ble)
                        case .debug:
                            DebugModeView(ble: ble)
                        }
                    }
                    .padding(UIDesignSystem.Padding.sm)
                }
                .frame(minWidth: 320)
            }
            .frame(minWidth: UIDesignSystem.Window.leftPanelMinWidth)
            .allowsHitTesting(!ble.isOTAInProgress && !ble.isOTACompletedWaitingReboot && !ble.isOTAFailed && !ble.isOTARebootDisconnected) // OTA 进行中、等待重启、失败或 reboot 断开时禁用左侧操作区域
            .overlay {
                // OTA 进行中、等待重启、失败或 reboot 断开时，在左侧区域显示半透明覆盖层
                if ble.isOTAInProgress || ble.isOTACompletedWaitingReboot || ble.isOTAFailed || ble.isOTARebootDisconnected {
                    OTAExclusiveOverlay(ble: ble)
                        .allowsHitTesting(true) // OTA 覆盖层可以接收交互
                }
            }

            // 右侧：日志（OTA 进行中时仍然可以查看和操作）
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
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(ble.displayedLogEntries) { entry in
                                    Text(entry.line)
                                        .font(UIDesignSystem.Typography.monospacedCaption)
                                        .foregroundStyle(LogLevelColor.color(entry.level))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(UIDesignSystem.Padding.sm)
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

/// OTA 独占模式覆盖层：OTA 进行中或等待重启时显示，只覆盖左侧操作区域
/// 右侧日志区域保持可操作，用户可以查看日志和切换日志等级
private struct OTAExclusiveOverlay: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    
    private var overlayTitle: String {
        if ble.isOTARebootDisconnected {
            return appLanguage.string("ota.title_reboot_disconnected")
        }
        if ble.isOTAFailed {
            return appLanguage.string("ota.exclusive_title_failed")
        }
        if ble.isOTACancelled {
            return appLanguage.string("ota.exclusive_title_cancelled")
        }
        if ble.isOTACompletedWaitingReboot {
            return appLanguage.string("ota.exclusive_title_reboot")
        }
        return appLanguage.string("ota.exclusive_title")
    }
    
    var body: some View {
        ZStack {
            // 半透明背景，覆盖左侧操作区域，阻止所有其他交互
            Color.black.opacity(UIDesignSystem.Opacity.overlay)
                .ignoresSafeArea(.all)
                .contentShape(Rectangle()) // 确保整个背景区域可接收点击事件
                .onTapGesture {
                    // 点击背景不执行任何操作，确保用户必须通过按钮来操作
                    // 这样可以防止用户误操作或尝试绕过OTA独占模式
                }
            
            // 中间的 OTA 视图（模态模式）
            VStack(spacing: UIDesignSystem.Spacing.xxl) {
                Text(overlayTitle)
                    .font(UIDesignSystem.Typography.pageTitle)
                    .foregroundStyle(UIDesignSystem.Foreground.primary)
                
                OTASectionView(ble: ble, isModal: true)
                    .shadow(color: .black.opacity(0.3), radius: UIDesignSystem.Spacing.xxl, x: 0, y: 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // 确保覆盖整个左侧区域
    }
}

/// 置顶按钮样式：根据是否置顶返回 .borderedProminent 或 .bordered，避免三元运算符类型推断问题
private struct PinTopButtonStyle: ButtonStyle {
    var isFloating: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, UIDesignSystem.Padding.lg)
            .padding(.vertical, UIDesignSystem.Padding.sm)
            .background(isFloating ? UIDesignSystem.Foreground.accent : Color.clear)
            .foregroundStyle(isFloating ? Color.white : UIDesignSystem.Foreground.primary)
            .clipShape(RoundedRectangle(cornerRadius: UIDesignSystem.CornerRadius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: UIDesignSystem.CornerRadius.sm, style: .continuous).strokeBorder(UIDesignSystem.Foreground.accent.opacity(isFloating ? 0 : 0.5), lineWidth: 1))
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSettings())
        .environmentObject(AppLanguage())
}
