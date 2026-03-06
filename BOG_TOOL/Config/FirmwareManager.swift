import Foundation
import AppKit

/// 固件管理单条：书签、路径显示、解析版本
struct FirmwareEntry: Identifiable, Codable, Equatable {
    let id: UUID
    /// 安全作用域书签（持久化）
    let bookmarkData: Data
    /// 路径字符串（仅用于列表显示，不用于解析）
    var pathDisplay: String
    /// 解析出的固件版本（如 1.0.5）
    var parsedVersion: String
    
    init(id: UUID = UUID(), bookmarkData: Data, pathDisplay: String, parsedVersion: String) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.pathDisplay = pathDisplay
        self.parsedVersion = parsedVersion
    }
    
    /// 从书签解析出 URL（需调用方在需要时 startAccessingSecurityScopedResource）
    func resolveURL() -> URL? {
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}

/// 固件管理：本地条目 + 服务器列表；按需下载并缓存，OTA 时本地有则直接用
final class FirmwareManager: ObservableObject {
    static let shared = FirmwareManager()
    private static let storageKey = "firmware_manager_entries"
    private static let firmwareCacheSubdir = "firmware_cache"

    @Published private(set) var entries: [FirmwareEntry] = []
    /// 从服务器拉取的固件列表（下拉框数据源）
    @Published private(set) var serverItems: [ServerFirmwareItem] = []
    @Published private(set) var serverItemsLoading = false
    /// 服务器固件相关错误提示（可由视图设置）
    @Published var serverItemsError: String?

    init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([FirmwareEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    /// 服务器固件缓存目录：Application Support/BOG Tool/firmware_cache
    private var firmwareCacheDir: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("BOG Tool", isDirectory: true).appendingPathComponent(Self.firmwareCacheSubdir, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 某服务器固件 id 对应的本地缓存文件 URL（未下载时文件不存在）
    func cacheURL(forServerFirmwareId id: String) -> URL? {
        guard let dir = firmwareCacheDir else { return nil }
        return dir.appendingPathComponent("\(id).bin", isDirectory: false)
    }

    /// 本地是否已有该服务器固件的缓存（一致则 OTA 时无需再下载）
    func hasCachedFirmware(serverFirmwareId id: String) -> Bool {
        guard let url = cacheURL(forServerFirmwareId: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 从服务器拉取固件列表（usage_type=ota_app），供下拉框使用
    @MainActor
    func fetchServerFirmware(serverClient: ServerClientProtocol) async {
        serverItemsLoading = true
        serverItemsError = nil
        defer { serverItemsLoading = false }
        do {
            serverItems = try await serverClient.listFirmware(usageType: "ota_app", channel: nil)
        } catch {
            serverItems = []
            serverItemsError = error.localizedDescription
        }
    }

    /// 解析出可用于 OTA 的本地 URL：若本地已有该服务器固件缓存则直接返回，否则下载后写入缓存再返回
    func resolveLocalURL(for item: ServerFirmwareItem, serverClient: ServerClientProtocol) async throws -> URL {
        let id = item.id
        if let cache = cacheURL(forServerFirmwareId: id), FileManager.default.fileExists(atPath: cache.path) {
            return cache
        }
        let data = try await serverClient.downloadFirmware(id: id)
        guard let dir = firmwareCacheDir else { throw NSError(domain: "FirmwareManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cache directory unavailable"]) }
        let fileURL = dir.appendingPathComponent("\(id).bin", isDirectory: false)
        try data.write(to: fileURL)
        return fileURL
    }
    
    /// 新增固件：从文件 URL 创建书签并解析版本
    @MainActor
    func add(url: URL) -> Bool {
        guard let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        let pathDisplay = url.path
        let parsedVersion = BLEManager.parseFirmwareVersion(from: url) ?? "—"
        let entry = FirmwareEntry(bookmarkData: bookmarkData, pathDisplay: pathDisplay, parsedVersion: parsedVersion)
        entries.append(entry)
        save()
        return true
    }
    
    /// 删除指定 id 的固件
    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }
    
    /// 按版本号返回第一个匹配的 URL（解析书签；调用方使用后由 BLEManager 持有书签）
    func url(forVersion version: String) -> URL? {
        guard let entry = entries.first(where: { $0.parsedVersion == version }) else { return nil }
        return entry.resolveURL()
    }
    
    /// 按 id 返回 URL
    func url(forId id: UUID) -> URL? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        return entry.resolveURL()
    }
    
    /// 根据 id 取 entry
    func entry(forId id: UUID) -> FirmwareEntry? {
        entries.first { $0.id == id }
    }
}
