import SwiftUI

#if DEBUG
private let injectionNotification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")
#endif

/// 全局置顶状态，供菜单与 ContentView 共用
final class AppSettings: ObservableObject {
    private let key = "windowFloating"
    @Published var windowFloating: Bool {
        didSet { UserDefaults.standard.set(windowFloating, forKey: key) }
    }
    init() {
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(true, forKey: key)
        }
        self.windowFloating = UserDefaults.standard.bool(forKey: key)
    }
}

@main
struct BOG_TOOLApp: App {
    @StateObject private var appSettings = AppSettings()
    @StateObject private var appLanguage = AppLanguage()
    @StateObject private var serverSettings: ServerSettings
    @StateObject private var serverClient: ServerClient

    init() {
        let settings = ServerSettings()
        let client = ServerClient(serverSettings: settings)
        settings.serverClient = client
        _serverSettings = StateObject(wrappedValue: settings)
        _serverClient = StateObject(wrappedValue: client)
        #if DEBUG
        // InjectionIII 热重载：加载后保存 Swift 文件即可在运行中的 App 里看到 UI 更新
        _ = Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/macOSInjection.bundle")?.load()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appSettings)
                .environmentObject(appLanguage)
                .environmentObject(serverSettings)
                .environmentObject(serverClient)
                #if DEBUG
                .modifier(InjectionObserver())
                #endif
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1440, height: 900)
        .commands {
            // 保留系统默认的「新建窗口」(Cmd+N)，便于同进程多窗口；SOP 规则存 UserDefaults，规则变更通过 productionTestRulesDidChange 通知各窗口同步
            CommandGroup(after: .windowList) {
                Toggle(appLanguage.string("menu.floating"), isOn: $appSettings.windowFloating)
            }
            CommandMenu(appLanguage.string("menu.firmware")) {
                Button(appLanguage.string("menu.firmware_manage")) {
                    NotificationCenter.default.post(name: .openFirmwareManager, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
            }
            CommandMenu(appLanguage.string("menu.server")) {
                Button(appLanguage.string("server.settings_title")) {
                    serverSettings.showServerSettingsSheet = true
                }
                .keyboardShortcut(",", modifiers: [.command])
                Divider()
                Toggle(appLanguage.string("server.upload_enabled"), isOn: $serverSettings.uploadToServerEnabled)
                Button(appLanguage.string("server.open_preview")) {
                    serverSettings.openPreviewInBrowser()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let openFirmwareManager = Notification.Name("OpenFirmwareManager")
}

#if DEBUG
/// 监听 InjectionIII 注入通知，触发 SwiftUI 刷新以便热重载生效
private struct InjectionObserver: ViewModifier {
    @State private var injectionCount = 0

    func body(content: Content) -> some View {
        content
            .id(injectionCount)
            .onReceive(NotificationCenter.default.publisher(for: injectionNotification)) { _ in
                injectionCount += 1
            }
    }
}
#endif
