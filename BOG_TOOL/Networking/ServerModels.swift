import Foundation

/// API path constants matching bog-test-server/main.py.
/// Keep in sync with the FastAPI routes.
enum ServerAPI {
    static let productionTest = "/api/production-test"
    static let summary = "/api/summary"
    static let firmwareUpgradeRecord = "/api/firmware-upgrade-record"
    /// 只读固件列表（无需 admin）
    static let firmwareList = "/api/firmware"
    /// 固件下载路径，需拼接 id：/api/firmware/{id}/download
    static func firmwareDownload(id: String) -> String { "/api/firmware/\(id)/download" }
}

/// 服务器返回的固件条目（GET /api/firmware）
struct ServerFirmwareItem: Identifiable, Codable, Equatable {
    let id: String
    let createdAt: String?
    let usageType: String?
    let channel: String?
    let version: String
    let fileName: String
    let originalFileName: String?
    let fileSizeBytes: Int?
    let checksum: String?
    let description: String?
    let isActive: Bool?
    let downloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, version, fileName, checksum, description
        case createdAt = "createdAt"
        case usageType = "usageType"
        case channel = "channel"
        case originalFileName = "originalFileName"
        case fileSizeBytes = "fileSizeBytes"
        case isActive = "isActive"
        case downloadUrl = "downloadUrl"
    }
}

/// GET /api/firmware 响应
struct ServerFirmwareListResponse: Codable {
    let items: [ServerFirmwareItem]
}
