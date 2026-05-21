import Foundation
import Network

struct AuxValveDiscoveredService: Identifiable, Equatable {
    let id: String
    let deviceId: String
    let serviceName: String
    let host: String
    let port: UInt16
}

struct AuxValveHTTPResponse {
    let httpStatus: Int
    let ok: Bool
    let deviceId: String?
    let valve: String?
    let moving: Bool?
    let elapsedMs: Int?
    let errorCode: String?
    let latencyMs: Double
}

enum AuxValveClientError: LocalizedError {
    case notConfigured
    case discoveryTimeout
    case deviceNotFound
    case unreachable(String)
    case wrongDevice
    case unauthorized
    case httpError(Int, String?)
    case decodeFailed
    case budgetExceeded

    /// `Localizable.strings` 键（点号分隔，供 `AppLanguage.string` 解析）
    var localizationKey: String? {
        switch self {
        case .notConfigured: return "aux_valve.error.not_configured"
        case .discoveryTimeout: return "aux_valve.error.discovery_timeout"
        case .deviceNotFound: return "aux_valve.error.device_not_found"
        case .unreachable: return nil
        case .wrongDevice: return "aux_valve.error.wrong_device"
        case .unauthorized: return "aux_valve.error.unauthorized"
        case .httpError: return "aux_valve.error.http"
        case .decodeFailed: return "aux_valve.error.decode_failed"
        case .budgetExceeded: return "aux_valve.error.budget_exceeded"
        }
    }

    func message(using language: AppLanguage) -> String {
        switch self {
        case .unreachable(let msg):
            return String(format: language.string("aux_valve.error.unreachable"), msg)
        case .httpError(let code, let err):
            return String(format: language.string("aux_valve.error.http"), code, err ?? "—")
        default:
            guard let key = localizationKey else { return language.string("aux_valve.test_failed") }
            return language.string(key)
        }
    }

    /// 存 Health/Coordinator：优先 i18n 键，由 UI 用 `AuxValveUserMessage.localize` 显示
    var userFacingToken: String {
        if let key = localizationKey { return key }
        switch self {
        case .unreachable(let msg): return msg
        case .httpError(let code, let err): return "HTTP \(code) \(err ?? "")"
        default: return "aux_valve.error.unknown"
        }
    }

    var errorDescription: String? { userFacingToken }
}

/// 将 Coordinator / Health 存的 token 按当前 App 语言显示
enum AuxValveUserMessage {
    static func localize(_ token: String, language: AppLanguage) -> String {
        if token.hasPrefix("aux_valve.error.") {
            return language.string(token)
        }
        if token.hasPrefix("aux_valve.error ") {
            return language.string(token.replacingOccurrences(of: " ", with: "."))
        }
        return token
    }

    static func from(_ error: Error) -> String {
        if let aux = error as? AuxValveClientError {
            return aux.userFacingToken
        }
        return error.localizedDescription
    }
}

/// mDNS 发现 + HTTP（/health、/status、POST /valve）
final class AuxValveWiFiClient {
    private let browserQueue = DispatchQueue(label: "AuxValveWiFiClient.browser")
    private let resolveQueue = DispatchQueue(label: "AuxValveWiFiClient.resolve")

    // MARK: - Discovery

    func discoverServices(timeout: TimeInterval, settings: AuxValveSettings? = nil) async -> [AuxValveDiscoveredService] {
        settings?.auxLog("mDNS browse \(AuxValveProtocol.mdnsServiceType) timeout=\(timeout)s")
        return await withCheckedContinuation { continuation in
            var collected: [String: AuxValveDiscoveredService] = [:]
            var skippedNames: [String] = []
            let lock = NSLock()
            var finished = false

            let browser = NWBrowser(
                for: .bonjour(type: AuxValveProtocol.mdnsServiceType, domain: AuxValveProtocol.mdnsDomain),
                using: .tcp
            )

            func finish(_ services: [AuxValveDiscoveredService]) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                browser.cancel()
                continuation.resume(returning: services)
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let err):
                    settings?.auxLog("mDNS browser failed: \(err.localizedDescription)", level: .warning)
                    finish(Array(collected.values).sorted { $0.deviceId < $1.deviceId })
                case .ready:
                    settings?.auxLog("mDNS browser ready")
                case .waiting(let err):
                    settings?.auxLog("mDNS browser waiting: \(err.localizedDescription)")
                default:
                    break
                }
            }

            browser.browseResultsChangedHandler = { results, _ in
                settings?.auxLog("mDNS browse results count=\(results.count)")
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    guard let deviceId = AuxValveProtocol.extractDeviceId(fromServiceName: name) else {
                        lock.lock()
                        if !skippedNames.contains(name) {
                            skippedNames.append(name)
                        }
                        lock.unlock()
                        settings?.auxLog("mDNS skip invalid instance name (need BOG-VALVE-XXXX hex): \"\(name)\"")
                        continue
                    }
                    self.resolveEndpoint(result.endpoint, serviceName: name, deviceId: deviceId, settings: settings) { host, port in
                        guard let host, let port else {
                            settings?.auxLog("mDNS resolve failed for \(name) id=\(deviceId)")
                            return
                        }
                        lock.lock()
                        collected[deviceId] = AuxValveDiscoveredService(
                            id: deviceId,
                            deviceId: deviceId,
                            serviceName: name,
                            host: host,
                            port: port
                        )
                        lock.unlock()
                        settings?.auxLog("mDNS resolved \(name) -> \(host):\(port)")
                    }
                }
            }

            browser.start(queue: browserQueue)
            browserQueue.asyncAfter(deadline: .now() + timeout) {
                lock.lock()
                let list = Array(collected.values).sorted { $0.deviceId < $1.deviceId }
                lock.unlock()
                if list.isEmpty {
                    settings?.auxLog("mDNS browse done: 0 devices (skipped names: \(skippedNames.isEmpty ? "none" : skippedNames.joined(separator: ", ")))", level: .warning)
                } else {
                    let summary = list.map { "\($0.deviceId)@\($0.host):\($0.port)" }.joined(separator: ", ")
                    settings?.auxLog("mDNS browse done: \(list.count) device(s): \(summary)")
                }
                finish(list)
            }
        }
    }

    func resolveTargetDevice(settings: AuxValveSettings, budgetDeadline: Date?) async throws -> (host: String, port: UInt16) {
        let targetId = settings.normalizedTargetDeviceId
        guard !targetId.isEmpty else { throw AuxValveClientError.notConfigured }

        if let cached = settings.cachedEndpointIfValid() {
            settings.auxLog("try cached endpoint \(cached.host):\(cached.port) ttl=\(settings.cachedEndpointTtlSec)s")
            let probeTimeout = settings.probeTimeoutSec
            if await probeReachable(host: cached.host, port: cached.port, settings: settings, timeout: probeTimeout) {
                settings.auxLog("cached endpoint OK")
                return cached
            }
            settings.auxLog("cached endpoint probe failed, fall back to mDNS", level: .warning)
        } else {
            settings.auxLog("no valid cached endpoint")
        }

        try checkBudget(budgetDeadline)
        let services = await discoverServices(timeout: settings.discoverTimeoutSec, settings: settings)
        guard let match = services.first(where: { $0.deviceId == targetId }) else {
            let found = services.map(\.deviceId).joined(separator: ",")
            settings.auxLog("target \(targetId) not in browse list [\(found.isEmpty ? "empty" : found)]", level: .warning)
            throw AuxValveClientError.deviceNotFound
        }
        settings.saveCachedEndpoint(host: match.host, port: match.port)
        settings.auxLog("using mDNS match \(match.serviceName) -> \(match.host):\(match.port)")
        return (match.host, match.port)
    }

    private func probeReachable(host: String, port: UInt16, settings: AuxValveSettings, timeout: TimeInterval) async -> Bool {
        do {
            let resp = try await getHealth(host: host, port: port, settings: settings, timeout: timeout)
            settings.auxLog("probe GET /health \(host):\(port) -> HTTP \(resp.httpStatus) ok=\(resp.ok) device_id=\(resp.deviceId ?? "nil")")
            return true
        } catch {
            settings.auxLog("probe GET /health \(host):\(port) failed: \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    private func resolveEndpoint(
        _ endpoint: NWEndpoint,
        serviceName: String,
        deviceId: String,
        settings: AuxValveSettings?,
        completion: @escaping (String?, UInt16?) -> Void
    ) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint ?? endpoint {
                    let hostStr = Self.hostString(from: host)
                    let portNum = port.rawValue == 0 ? AuxValveProtocol.defaultHTTPPort : port.rawValue
                    if port.rawValue == 0 {
                        settings?.auxLog("mDNS port missing for \(serviceName), fallback defaultHTTPPort=\(AuxValveProtocol.defaultHTTPPort)")
                    }
                    connection.cancel()
                    if let hostStr {
                        completion(hostStr, portNum)
                    } else {
                        completion(nil, nil)
                    }
                } else {
                    connection.cancel()
                    completion(nil, nil)
                }
            case .failed(let err):
                settings?.auxLog("NWConnection resolve failed \(serviceName): \(err.localizedDescription)", level: .warning)
                completion(nil, nil)
            case .cancelled:
                completion(nil, nil)
            default:
                break
            }
        }
        connection.start(queue: resolveQueue)
        let probeTimeout = settings?.probeTimeoutSec ?? AuxValveSettingsDefaults.probeTimeoutSec
        resolveQueue.asyncAfter(deadline: .now() + probeTimeout) {
            if connection.state != .ready && connection.state != .cancelled {
                connection.cancel()
                completion(nil, nil)
            }
        }
    }

    // MARK: - HTTP

    func performHealthCheck(settings: AuxValveSettings) async -> AuxValveHealthResult {
        guard settings.enabled, !settings.normalizedTargetDeviceId.isEmpty else {
            return AuxValveHealthResult(reachable: false, latencyMs: nil, valve: nil, moving: false, errorMessage: nil)
        }
        do {
            let endpoint = try await resolveTargetDevice(settings: settings, budgetDeadline: nil)
            let response = try await getHealth(
                host: endpoint.host,
                port: endpoint.port,
                settings: settings,
                timeout: settings.healthHttpTimeoutSec
            )
            if settings.auxHttpTraceEnabled {
                settings.auxLog(
                    "GET /health \(endpoint.host):\(endpoint.port) -> HTTP \(response.httpStatus) ok=\(response.ok) "
                    + "device_id=\(response.deviceId ?? "nil") valve=\(response.valve ?? "nil") "
                    + "latency=\(String(format: "%.0f", response.latencyMs))ms"
                )
            }
            if response.httpStatus == 401 {
                settings.auxLog("health rejected: 401 token mismatch (configured \(settings.tokenConfiguredDescription))", level: .warning)
                return AuxValveHealthResult(reachable: false, latencyMs: response.latencyMs, valve: response.valve, moving: false, errorMessage: AuxValveClientError.unauthorized.userFacingToken)
            }
            guard response.ok, response.deviceId?.uppercased() == settings.normalizedTargetDeviceId else {
                settings.auxLog(
                    "health rejected: want device_id=\(settings.normalizedTargetDeviceId) got=\(response.deviceId ?? "nil")",
                    level: .warning
                )
                return AuxValveHealthResult(reachable: false, latencyMs: response.latencyMs, valve: response.valve, moving: false, errorMessage: AuxValveClientError.wrongDevice.userFacingToken)
            }
            return AuxValveHealthResult(
                reachable: true,
                latencyMs: response.latencyMs,
                valve: response.valve,
                moving: response.moving ?? false,
                errorMessage: nil
            )
        } catch {
            settings.auxLog("health check error: \(error.localizedDescription)", level: .warning)
            return AuxValveHealthResult(reachable: false, latencyMs: nil, valve: nil, moving: false, errorMessage: AuxValveUserMessage.from(error))
        }
    }

    func getHealth(host: String, port: UInt16, settings: AuxValveSettings, timeout: TimeInterval) async throws -> AuxValveHTTPResponse {
        try await request(path: AuxValveProtocol.healthPath, host: host, port: port, method: "GET", body: nil, settings: settings, timeout: timeout)
    }

    func getStatus(host: String, port: UInt16, settings: AuxValveSettings, timeout: TimeInterval) async throws -> AuxValveHTTPResponse {
        try await request(path: AuxValveProtocol.statusPath, host: host, port: port, method: "GET", body: nil, settings: settings, timeout: timeout)
    }

    func postValve(action: String, host: String, port: UInt16, settings: AuxValveSettings, timeout: TimeInterval) async throws -> AuxValveHTTPResponse {
        let body: [String: Any] = [
            "action": action,
            "device_id": settings.normalizedTargetDeviceId,
        ]
        settings.auxLog("POST /valve \(host):\(port) action=\(action) device_id=\(settings.normalizedTargetDeviceId)")
        return try await request(path: AuxValveProtocol.valvePath, host: host, port: port, method: "POST", body: body, settings: settings, timeout: timeout)
    }

    func pollUntilValveState(
        _ expected: String,
        host: String,
        port: UInt16,
        settings: AuxValveSettings,
        budgetDeadline: Date?
    ) async throws {
        let deadline = Date().addingTimeInterval(settings.movingPollMaxSec)
        settings.auxLog("poll valve until=\(expected) max=\(settings.movingPollMaxSec)s")
        while Date() < deadline {
            try checkBudget(budgetDeadline)
            let status = try await getStatus(host: host, port: port, settings: settings, timeout: settings.httpTimeoutSec)
            if status.httpStatus == 401 { throw AuxValveClientError.unauthorized }
            if status.errorCode == "wrong_device" || status.deviceId?.uppercased() != settings.normalizedTargetDeviceId {
                throw AuxValveClientError.wrongDevice
            }
            if status.ok, status.valve == expected, status.moving != true {
                settings.auxLog("poll valve reached \(expected)")
                return
            }
            settings.auxLog("poll valve=\(status.valve ?? "?") moving=\(status.moving ?? false)")
            try await Task.sleep(nanoseconds: UInt64(settings.movingPollIntervalMs) * 1_000_000)
        }
        throw AuxValveClientError.unreachable("valve not \(expected)")
    }

    /// 将 `NWEndpoint.Host` 转为可用于 URL 的主机字符串（避免 IPv6 `%` zone 导致 invalid url）
    private static func hostString(from host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let ipv4):
            let octets = [UInt8](ipv4.rawValue)
            guard octets.count == 4 else { return nil }
            return octets.map(String.init).joined(separator: ".")
        case .ipv6(let ipv6):
            return AuxValveProtocol.normalizedHTTPHost(ipv6.debugDescription)
        case .name(let name, _):
            return AuxValveProtocol.normalizedHTTPHost(name)
        @unknown default:
            return nil
        }
    }

    private func request(
        path: String,
        host: String,
        port: UInt16,
        method: String,
        body: [String: Any]?,
        settings: AuxValveSettings,
        timeout: TimeInterval
    ) async throws -> AuxValveHTTPResponse {
        guard let url = AuxValveProtocol.makeHTTPURL(host: host, port: port, path: path) else {
            settings.auxLog("invalid URL host=\(host) port=\(port) path=\(path)", level: .warning)
            throw AuxValveClientError.unreachable("invalid url (\(host):\(port))")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
        }
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Device-Token")
        }

        settings.auxLog("\(method) \(url.absoluteString) timeout=\(timeout)s token=\(settings.tokenConfiguredDescription)")

        let start = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            settings.auxLog("HTTP transport error: \(error.localizedDescription)", level: .warning)
            throw AuxValveClientError.unreachable(error.localizedDescription)
        }
        let latencyMs = Date().timeIntervalSince(start) * 1000
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let parsed = AuxValveHTTPResponse(
            httpStatus: httpStatus,
            ok: json?["ok"] as? Bool ?? false,
            deviceId: json?["device_id"] as? String,
            valve: json?["valve"] as? String,
            moving: json?["moving"] as? Bool,
            elapsedMs: json?["elapsed_ms"] as? Int,
            errorCode: json?["error"] as? String,
            latencyMs: latencyMs
        )
        settings.auxLog(
            "HTTP response \(httpStatus) ok=\(parsed.ok) err=\(parsed.errorCode ?? "—") "
            + "device_id=\(parsed.deviceId ?? "—") valve=\(parsed.valve ?? "—") "
            + "\(String(format: "%.0f", parsed.latencyMs))ms"
        )
        return parsed
    }

    private func checkBudget(_ deadline: Date?) throws {
        if let deadline, Date() >= deadline {
            throw AuxValveClientError.budgetExceeded
        }
    }
}
