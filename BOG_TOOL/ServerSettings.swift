import Foundation
import SwiftUI
import AppKit

// MARK: - 服务器配置（持久化到 UserDefaults）

private enum ServerSettingsKeys {
    static let baseURL = "server_base_url"
    static let uploadEnabled = "server_upload_enabled"
    static let localServerPath = "server_local_path"
    static let defaultBaseURL = "http://8.129.99.18:8000"
}

/// 产测服务器配置与本地服务进程管理
final class ServerSettings: ObservableObject {
    @Published var serverBaseURL: String {
        didSet {
            let v = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(v.isEmpty ? Self.defaultBaseURL : v, forKey: ServerSettingsKeys.baseURL)
        }
    }

    @Published var uploadToServerEnabled: Bool {
        didSet { UserDefaults.standard.set(uploadToServerEnabled, forKey: ServerSettingsKeys.uploadEnabled) }
    }

    @Published var localServerPath: String {
        didSet { UserDefaults.standard.set(localServerPath, forKey: ServerSettingsKeys.localServerPath) }
    }

    /// 用于菜单触发显示「服务器设置」面板
    @Published var showServerSettingsSheet: Bool = false

    /// 本地 uvicorn 进程是否已启动（由本 App 启动时为 true）
    @Published private(set) var isLocalServerRunning: Bool = false
    private var serverProcess: Process?

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
        self.localServerPath = UserDefaults.standard.string(forKey: ServerSettingsKeys.localServerPath) ?? ""
        DispatchQueue.main.async { [weak self] in self?.refreshPendingUploadsCount() }
        startNetworkHealthTimer()
        performNetworkHealthCheck()
    }

    /// 用于打开预览、启动服务等的 base URL（保证有值）
    var effectiveBaseURL: String {
        let v = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? Self.defaultBaseURL : v
    }

    /// 从 base URL 解析端口（用于启动本地服务时传参）
    var serverPort: Int {
        guard let url = URL(string: effectiveBaseURL), let port = url.port else { return 8000 }
        return port
    }

    /// 在默认浏览器中打开数据概览页
    func openPreviewInBrowser() {
        guard let url = URL(string: effectiveBaseURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 启动本地 bog-test-server（需已配置 localServerPath 且该路径下存在 .venv/bin/uvicorn）
    func startLocalServer() {
        let path = (localServerPath as NSString).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        let uvicornPath = (path as NSString).appendingPathComponent(".venv/bin/uvicorn")
        guard FileManager.default.isExecutableFile(atPath: uvicornPath) else { return }
        let workDir = URL(fileURLWithPath: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvicornPath)
        process.arguments = ["main:app", "--host", "127.0.0.1", "--port", "\(serverPort)"]
        process.currentDirectoryURL = workDir
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.isLocalServerRunning = false }
        }
        do {
            try process.run()
            serverProcess = process
            isLocalServerRunning = true
        } catch {
            serverProcess = nil
            isLocalServerRunning = false
        }
    }

    /// 停止由本 App 启动的本地服务
    func stopLocalServer() {
        serverProcess?.terminate()
        serverProcess = nil
        isLocalServerRunning = false
    }

    /// 产测结果上报接口 URL
    var productionTestReportURL: URL? {
        let base = effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base + "/api/production-test")
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
        guard !items.isEmpty, let baseURL = productionTestReportURL else {
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
                guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { continue }
                var request = URLRequest(url: baseURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = jsonData
                request.timeoutInterval = 30
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                        pending.remove(at: i)
                        pendingUploadsFileQueue.sync { savePendingToFile(pending) }
                        sentCount += 1
                        await MainActor.run {
                            refreshPendingUploadsCount()
                            log("已重传待上传产测结果 1 条")
                        }
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
        let base = effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/summary") else { return }

        let start = Date()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }

            if let _ = error {
                DispatchQueue.main.async {
                    self.isServerReachable = false
                    self.lastPingLatencyMs = nil
                }
                return
            }

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                DispatchQueue.main.async {
                    self.isServerReachable = false
                    self.lastPingLatencyMs = nil
                }
                return
            }

            let latencyMs = Date().timeIntervalSince(start) * 1000.0
            DispatchQueue.main.async {
                self.isServerReachable = true
                self.lastPingLatencyMs = latencyMs

                if self.uploadToServerEnabled && self.pendingUploadsCount > 0 {
                    self.retryPendingUploadsSilently()
                }
            }
        }.resume()
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

            // 服务器地址
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

            // 本地服务路径（用于启动/停止）
            VStack(alignment: .leading, spacing: 6) {
                Text(appLanguage.string("server.local_path_label"))
                    .font(.subheadline.weight(.medium))
                TextField(appLanguage.string("server.local_path_placeholder"), text: $serverSettings.localServerPath)
                    .textFieldStyle(.roundedBorder)
                Text(appLanguage.string("server.local_path_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button(appLanguage.string("server.start_server")) {
                    serverSettings.startLocalServer()
                }
                .disabled(serverSettings.localServerPath.trimmingCharacters(in: .whitespaces).isEmpty || serverSettings.isLocalServerRunning)

                Button(appLanguage.string("server.stop_server")) {
                    serverSettings.stopLocalServer()
                }
                .disabled(!serverSettings.isLocalServerRunning)

                if serverSettings.isLocalServerRunning {
                    Text(appLanguage.string("server.status_running"))
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Divider()

            Button(appLanguage.string("server.open_preview")) {
                serverSettings.openPreviewInBrowser()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 380)
    }
}
