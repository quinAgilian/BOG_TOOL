import Foundation

/// WiFi 辅材 HTTP / mDNS 协议常量（非工位可调项，见 auto-valve-wifi-system.md §4.11.3）
enum AuxValveProtocol {
    static let mdnsServiceType = "_bogvalve._tcp"
    static let mdnsDomain: String? = nil

    static let apiBasePath = "/api/v1"
    static let healthPath = "\(apiBasePath)/health"
    static let statusPath = "\(apiBasePath)/status"
    static let valvePath = "\(apiBasePath)/valve"
    static let pressurePath = "\(apiBasePath)/pressure"
    static let bindRequestPath = "\(apiBasePath)/bind/request"
    static let bindPath = "\(apiBasePath)/bind"
    static let unbindPath = "\(apiBasePath)/unbind"

    /// 与固件 `STATION_PAIRING_WINDOW_MS` 一致
    static let pairingWindowSec: TimeInterval = 30
    /// 与固件 `BUTTON_BIND_MS` 一致（配对物理确认）
    static let bindHoldMs = 3000
    static let wifiProvisionHoldMs = 10000
    static let factoryResetHoldMs = 30000

    /// 固件默认端口；mDNS TXT 若带端口则优先 TXT（见 API.md）
    static let defaultHTTPPort: UInt16 = 12306

    static func deviceName(for deviceId: String) -> String {
        "BOG-VALVE-\(deviceId.uppercased())"
    }

    /// 固件 mDNS hostname（`wifi_manager.c` / virtual_valve）
    static func mdnsHostname(for deviceId: String) -> String {
        "bog-valve-\(deviceId.uppercased()).local"
    }

    static func extractDeviceId(fromServiceName name: String) -> String? {
        let prefix = "BOG-VALVE-"
        guard name.uppercased().hasPrefix(prefix) else { return nil }
        let id = String(name.dropFirst(prefix.count)).uppercased()
        guard id.count == 4, id.allSatisfy({ $0.isHexDigit }) else { return nil }
        return id
    }

    /// 供 HTTP 使用的主机名（去掉 IPv6 zone `%en0`、方括号等，避免 `URL(string:)` 得到 invalid url）
    static func normalizedHTTPHost(_ raw: String) -> String? {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        if h.hasPrefix("["), h.hasSuffix("]") {
            h = String(h.dropFirst().dropLast())
        }
        if let zone = h.firstIndex(of: "%") {
            h = String(h[..<zone])
        }
        return h.isEmpty ? nil : h
    }

    static func makeHTTPURL(host: String, port: UInt16, path: String) -> URL? {
        guard let host = normalizedHTTPHost(host), port > 0 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        var p = path
        if !p.hasPrefix("/") { p = "/" + p }
        components.path = p
        return components.url
    }
}
