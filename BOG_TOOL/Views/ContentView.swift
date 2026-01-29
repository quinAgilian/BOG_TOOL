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
                    Button(appLanguage.string("log.clear")) {
                        ble.logMessages.removeAll()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor))
                
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(ble.logMessages.enumerated()), id: \.offset) { i, msg in
                                Text(msg)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(5)
                    }
                    .onChange(of: ble.logMessages.count, perform: { _ in
                        if let last = ble.logMessages.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
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
