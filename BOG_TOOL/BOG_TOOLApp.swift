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

    init() {
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
                #if DEBUG
                .modifier(InjectionObserver())
                #endif
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .windowList) {
                Toggle(appLanguage.string("menu.floating"), isOn: $appSettings.windowFloating)
            }
        }
    }
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
