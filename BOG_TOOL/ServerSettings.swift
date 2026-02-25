import Foundation
import SwiftUI
import AppKit

// MARK: - 服务器配置（持久化到 UserDefaults）

private enum ServerSettingsKeys {
    static let baseURL = "server_base_url"
    static let uploadEnabled = "server_upload_enabled"
    /// 默认服务器地址；推荐部署远程服务器后在此配置，或首次启动时由用户输入
    static let defaultBaseURL = "https://bog-test.generalquin.top"
}

/// 产测服务器配置（仅支持远程服务器）
final class ServerSettings: ObservableObject {
    weak var serverClient: ServerClient?

    @Published var serverBaseURL: String {
        didSet {
            let v = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(v.isEmpty ? Self.defaultBaseURL : v, forKey: ServerSettingsKeys.baseURL)
        }
    }

    @Published var uploadToServerEnabled: Bool {
        didSet { UserDefaults.standard.set(uploadToServerEnabled, forKey: ServerSettingsKeys.uploadEnabled) }
    }

    /// 用于菜单触发显示「服务器设置」面板
    @Published var showServerSettingsSheet: Bool = false

    /// 待重传产测结果条数（失败落盘），供底部状态栏显示
    @Published private(set) var pendingUploadsCount: Int = 0

    /// 当前服务器连通性与延迟（基于定期对 /api/summary 的 HTTP 探测）
    @Published private(set) var isServerReachable: Bool = false
    @Published private(set) var lastPingLatencyMs: Double? = nil

    private var networkTimer: Timer?
    private var isRetryingPendingUploads: Bool = false

    static let defaultBaseURL = ServerSettingsKeys.defaultBaseURL

    init() {
        self.serverBaseURL = UserDefaults.standard.string(forKey: ServerSettingsKeys.baseURL) ?? Self.defaultBaseURL
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
        guard let url = URL(string: effectiveBaseURL) else { return }
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

    /// 从磁盘读取待重传列表（仅 body 数组）
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
        pendingUploadsFileQueue.sync {
            var items = loadPendingFromFile()
            items.append(body)
            savePendingToFile(items)
        }
        refreshPendingUploadsCount()
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
        isRetryingPendingUploads = true
        Task {
            var pending = items
            var sentCount = 0
            for i in (0..<pending.count).reversed() {
                let body = pending[i]
                do {
                    try await client.uploadProductionTest(body: body)
                    pending.remove(at: i)
                    pendingUploadsFileQueue.sync { savePendingToFile(pending) }
                    sentCount += 1
                    await MainActor.run {
                        refreshPendingUploadsCount()
                        log("已重传待上传产测结果 1 条")
                    }
                } catch {
                    await MainActor.run { log("重传失败: \(error.localizedDescription)") }
                }
            }
            if sentCount > 0 {
                await MainActor.run { log("本次启动共重传 \(sentCount) 条产测结果") }
            }
            await MainActor.run {
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
        networkTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.performNetworkHealthCheck()
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(appLanguage.string("server.settings_title"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(appLanguage.string("firmware_manager.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            // 服务器地址（推荐配置远程部署的 bog-test-server 地址）
            VStack(alignment: .leading, spacing: 6) {
                Text(appLanguage.string("server.base_url_label"))
                    .font(.subheadline.weight(.medium))
                TextField(appLanguage.string("server.base_url_placeholder"), text: $serverSettings.serverBaseURL)
                    .textFieldStyle(.roundedBorder)
                Text(appLanguage.string("server.base_url_hint"))
                    .font(.caption)
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
