import Foundation
import SwiftUI
import AppKit

// MARK: - 服务器配置（持久化到 UserDefaults）

private enum ServerSettingsKeys {
    static let baseURL = "server_base_url"
    static let uploadEnabled = "server_upload_enabled"
    /// 默认服务器地址；生产经 Nginx 对外为 80（境外）或 8080（国内），当前 8080 不可达时使用 80
    static let defaultBaseURL = "http://bog.generalquin.top"
}

/// 固定服务器环境枚举，禁止用户随意输入 URL
private enum ServerEnvironment: String, CaseIterable, Identifiable {
    case production
    case testing
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .production:
            return "Production (80)"
        case .testing:
            return "Testing (8081)"
        case .local:
            return "Local (localhost:8000)"
        }
    }

    var baseURL: String {
        switch self {
        case .production:
            return "http://bog.generalquin.top"
        case .testing:
            return "http://bog.generalquin.top:8081"
        case .local:
            return "http://localhost:8000"
        }
    }

    static func from(baseURL: String) -> ServerEnvironment {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        for env in ServerEnvironment.allCases {
            if env.baseURL == trimmed {
                return env
            }
        }
        // 兜底：未知配置则默认视为 production
        return .production
    }
}

/// 产测服务器配置（仅支持远程服务器）
final class ServerSettings: ObservableObject {
    weak var serverClient: ServerClient?

    @Published var serverBaseURL: String {
        didSet {
            let v = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(v.isEmpty ? ServerSettingsKeys.defaultBaseURL : v, forKey: ServerSettingsKeys.baseURL)
        }
    }

    @Published var uploadToServerEnabled: Bool {
        didSet { UserDefaults.standard.set(uploadToServerEnabled, forKey: ServerSettingsKeys.uploadEnabled) }
    }

    /// 用于菜单触发显示「服务器设置」面板
    @Published var showServerSettingsSheet: Bool = false

    /// 待重传产测结果条数（失败落盘），供底部状态栏显示
    @Published private(set) var pendingUploadsCount: Int = 0

    /// 当前自动重传进度（已上传条数 / 本轮总条数），仅在重传任务进行时有效
    @Published private(set) var retryUploadedCount: Int = 0
    @Published private(set) var retryTotalCount: Int = 0

    /// 当前服务器连通性与延迟（基于定期对 /api/summary 的 HTTP 探测）
    @Published private(set) var isServerReachable: Bool = false
    @Published private(set) var lastPingLatencyMs: Double? = nil

    private var networkTimer: Timer?
    @Published private(set) var isRetryingPendingUploads: Bool = false

    static let defaultBaseURL = ServerSettingsKeys.defaultBaseURL

    init() {
        let stored = UserDefaults.standard.string(forKey: ServerSettingsKeys.baseURL)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURL: String
        if let s = stored {
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // 兼容旧版本：历史上使用过 IP/端口 的配置，统一映射到新的域名与可用端口
            if v.contains("8.129.99.18:8080") || v.contains("bog.generalquin.top:8080") || v == "http://bog.generalquin.top" {
                resolvedBaseURL = ServerEnvironment.production.baseURL
            } else if v.contains("8.129.99.18:8081") {
                resolvedBaseURL = ServerEnvironment.testing.baseURL
            } else if v.contains("127.0.0.1:8000") {
                resolvedBaseURL = ServerEnvironment.local.baseURL
            } else {
                resolvedBaseURL = v.isEmpty ? ServerSettingsKeys.defaultBaseURL : v
            }
        } else {
            resolvedBaseURL = ServerSettingsKeys.defaultBaseURL
        }
        self.serverBaseURL = resolvedBaseURL
        UserDefaults.standard.set(resolvedBaseURL, forKey: ServerSettingsKeys.baseURL)
        self.uploadToServerEnabled = UserDefaults.standard.object(forKey: ServerSettingsKeys.uploadEnabled) as? Bool ?? false
        DispatchQueue.main.async { [weak self] in self?.refreshPendingUploadsCount() }
        startNetworkHealthTimer()
        performNetworkHealthCheck()
    }

    /// 用于打开预览等的 base URL（保证有值）
    var effectiveBaseURL: String {
        let v = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? Self.defaultBaseURL : v
    }

    /// 在默认浏览器中打开数据概览页
    func openPreviewInBrowser() {
        // 预览入口统一指向外部站点，由站点内再区分产测/调试/固件管理
        guard let url = URL(string: "https://generalquin.top/bog") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 失败落盘与下次启动重传

    private static let pendingUploadsFileName = "pending_uploads.json"
    private let pendingUploadsFileQueue = DispatchQueue(label: "ServerSettings.pendingUploads")

    private var pendingUploadsFileURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("BOG Tool", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(Self.pendingUploadsFileName)
    }

    /// 从磁盘读取待重传列表；每项为 ["recordType": "production_test"|"firmware_upgrade", "body": ...]，旧格式无 recordType 则视为 production_test
    private func loadPendingFromFile() -> [[String: Any]] {
        guard let url = pendingUploadsFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        return items
    }

    /// 将待重传列表写回磁盘
    private func savePendingToFile(_ items: [[String: Any]]) {
        guard let url = pendingUploadsFileURL else { return }
        let wrapper: [String: Any] = ["items": items]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper) else { return }
        try? data.write(to: url)
    }

    /// 失败落盘：将当次产测 body 追加到待重传列表
    func savePendingUpload(body: [String: Any]) {
        savePendingItem(recordType: "production_test", body: body)
    }

    /// 失败落盘：将 OTA 固件升级记录追加到待重传列表
    func savePendingFirmwareUpgrade(body: [String: Any]) {
        savePendingItem(recordType: "firmware_upgrade", body: body)
    }

    private func savePendingItem(recordType: String, body: [String: Any]) {
        pendingUploadsFileQueue.sync {
            var items = loadPendingFromFile()
            items.append(["recordType": recordType, "body": body])
            savePendingToFile(items)
        }
        refreshPendingUploadsCount()
        if uploadToServerEnabled && isServerReachable {
            retryPendingUploadsSilently()
        }
    }

    /// 从磁盘刷新待重传条数并更新 @Published，供底部状态栏等 UI 使用
    func refreshPendingUploadsCount() {
        let count = pendingUploadsFileQueue.sync { loadPendingFromFile().count }
        DispatchQueue.main.async { [weak self] in self?.pendingUploadsCount = count }
    }

    /// 下次启动或恢复网络后调用：逐条重传，成功则从列表中移除
    func retryPendingUploads(log: @escaping (String) -> Void) {
        let items: [[String: Any]] = pendingUploadsFileQueue.sync { loadPendingFromFile() }
        guard !items.isEmpty, let client = serverClient else {
            if !items.isEmpty { log("待重传 \(items.count) 条，但当前未配置服务器地址，跳过重传") }
            return
        }
        if isRetryingPendingUploads {
            return
        }
        let total = items.count
        isRetryingPendingUploads = true
        Task {
            var pending = items
            var sentCount = 0
            await MainActor.run {
                self.retryTotalCount = total
                self.retryUploadedCount = 0
            }
            for i in (0..<pending.count).reversed() {
                let item = pending[i]
                let recordType = item["recordType"] as? String ?? "production_test"
                let body = (item["body"] as? [String: Any]) ?? item
                do {
                    if recordType == "firmware_upgrade" {
                        try await client.uploadFirmwareUpgradeRecord(body: body)
                    } else {
                        try await client.uploadProductionTest(body: body)
                    }
                    pending.remove(at: i)
                    pendingUploadsFileQueue.sync { savePendingToFile(pending) }
                    sentCount += 1
                    let currentSent = sentCount
                    await MainActor.run {
                        self.retryUploadedCount = currentSent
                        refreshPendingUploadsCount()
                        log("已重传待上传产测结果 1 条")
                    }
                } catch {
                    await MainActor.run { log("重传失败: \(error.localizedDescription)") }
                }
            }
            let finalSent = sentCount
            await MainActor.run {
                if finalSent > 0 {
                    log("本次启动共重传 \(finalSent) 条产测结果")
                }
                self.retryUploadedCount = 0
                self.retryTotalCount = 0
                self.isRetryingPendingUploads = false
            }
        }
    }

    /// 无日志的重传，供网络探测成功后自动调用
    func retryPendingUploadsSilently() {
        retryPendingUploads { _ in }
    }

    // MARK: - 网络探测与延迟

    private func startNetworkHealthTimer() {
        networkTimer?.invalidate()
        // 每 3 秒进行一次健康检查（请求本身也设置 3 秒超时）
        networkTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.performNetworkHealthCheck()
        }
    }

    /// 供外部在注入 serverClient 后立即触发一次健康检查，避免首屏长时间显示 offline
    func triggerHealthCheck() {
        performNetworkHealthCheck()
    }

    private func performNetworkHealthCheck() {
        guard let client = serverClient else { return }
        Task {
            let (reachable, latencyMs) = await client.performHealthCheck()
            await MainActor.run {
                self.isServerReachable = reachable
                self.lastPingLatencyMs = latencyMs
                if self.uploadToServerEnabled && self.pendingUploadsCount > 0 {
                    self.retryPendingUploadsSilently()
                }
            }
        }
    }

    deinit {
        networkTimer?.invalidate()
    }
}

// MARK: - 服务器设置面板（Sheet）

struct ServerSettingsView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var serverSettings: ServerSettings
    @Environment(\.dismiss) private var dismiss

    @State private var selectedEnvironment: ServerEnvironment

    init(serverSettings: ServerSettings) {
        self.serverSettings = serverSettings
        _selectedEnvironment = State(initialValue: ServerEnvironment.from(baseURL: serverSettings.effectiveBaseURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(appLanguage.string("server.settings_title"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(appLanguage.string("firmware_manager.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            // 服务器环境（固定枚举，禁止手动输入）
            VStack(alignment: .leading, spacing: 6) {
                Text(appLanguage.string("server.base_url_label"))
                    .font(.subheadline.weight(.medium))
                Picker("", selection: $selectedEnvironment) {
                    ForEach(ServerEnvironment.allCases) { env in
                        Text(env.displayName).tag(env)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: selectedEnvironment) { newValue in
                    serverSettings.serverBaseURL = newValue.baseURL
                }
                Text(serverSettings.effectiveBaseURL)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // 是否上传至服务器
            Toggle(isOn: $serverSettings.uploadToServerEnabled) {
                Text(appLanguage.string("server.upload_enabled"))
            }

            Divider()

            Button(appLanguage.string("server.open_preview")) {
                serverSettings.openPreviewInBrowser()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 300)
    }
}
