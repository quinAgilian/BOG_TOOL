import Foundation

/// 固件管理：从服务器拉取固件列表；按需下载并缓存，OTA 时本地有则直接用
final class FirmwareManager: ObservableObject {
    static let shared = FirmwareManager()
    private static let firmwareCacheSubdir = "firmware_cache"
    /// Debug 模式：从服务器拉取的全部 OTA 固件（channel=debugging）
    @Published private(set) var serverItemsForDebug: [ServerFirmwareItem] = []
    /// 产测模式：从服务器拉取的产线可见 OTA 固件（channel=production）
    @Published private(set) var serverItemsForProduction: [ServerFirmwareItem] = []
    @Published private(set) var serverItemsLoading = false
    /// 服务器固件相关错误提示（可由视图设置）
    @Published var serverItemsError: String?

    init() {}

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

    /// 从服务器拉取 OTA 固件列表（usage_type=ota_app）
    /// - Parameter channel: "debugging" = 全部固件（Debug OTA）；"production" = 仅产线可见（产测规则/产测 OTA）
    @MainActor
    func fetchServerFirmware(serverClient: ServerClientProtocol, channel: String) async {
        serverItemsLoading = true
        serverItemsError = nil
        defer { serverItemsLoading = false }
        do {
            let items = try await serverClient.listFirmware(usageType: "ota_app", channel: channel)
            if channel == "production" {
                serverItemsForProduction = items
            } else {
                serverItemsForDebug = items
            }
        } catch {
            if channel == "production" {
                serverItemsForProduction = []
            } else {
                serverItemsForDebug = []
            }
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
}
