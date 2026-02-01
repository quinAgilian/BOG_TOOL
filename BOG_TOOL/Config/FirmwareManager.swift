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

/// 固件管理：新增、删除、按版本查找；持久化到 UserDefaults
final class FirmwareManager: ObservableObject {
    static let shared = FirmwareManager()
    private static let storageKey = "firmware_manager_entries"
    
    @Published private(set) var entries: [FirmwareEntry] = []
    
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
