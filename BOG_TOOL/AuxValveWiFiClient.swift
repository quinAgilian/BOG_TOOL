import Foundation
import Network

struct AuxValveDiscoveredService: Identifiable, Equatable {
    let id: String
    let deviceId: String
    let serviceName: String
    let host: String
    let port: UInt16
    /// From `GET /health` after scan; nil if unreachable or legacy firmware.
    var firmwareVersion: String?
}

struct AuxValveHTTPResponse {
    let httpStatus: Int
    let ok: Bool
    let deviceId: String?
    let firmwareVersion: String?
    let valve: String?
    let moving: Bool?
    let elapsedMs: Int?
    let errorCode: String?
    let latencyMs: Double
    let boundClientId: String?
    let bindArmed: Bool?
    let bindPending: Bool?
    let pairingSecondsLeft: Int?
    let buttonPressed: Bool?
    let buttonHoldMs: Int?
    let buttonBindReady: Bool?
    let physicalUnbindPending: Bool?
    let physicalUnbindSeq: Int?
    let physicalUnbindAgeMs: Int?
    let valveRev: Int?
}

/// 配对轮询时上报给 UI 的状态（来自 `/health`）
struct AuxValvePairingPollState {
    let secondsLeft: Int
    let buttonPressed: Bool
    let buttonHoldMs: Int
    let buttonBindReady: Bool
}

struct AuxValvePressureReading: Equatable {
    let sensorOk: Bool
    let valid: Bool
    let pressureMbar: Double?
    let temperatureC: Double?
    let sampleIntervalMs: Int
    let ageMs: Int?
}

enum AuxValveClientError: LocalizedError {
    case notConfigured
    case discoveryTimeout
    case deviceNotFound
    case unreachable(String)
    case wrongDevice
    case wrongClient
    case unauthorized
    case httpError(Int, String?)
    case decodeFailed
    case budgetExceeded
    case pairingTimeout

    /// `Localizable.strings` 键（点号分隔，供 `AppLanguage.string` 解析）
    var localizationKey: String? {
        switch self {
        case .notConfigured: return "aux_valve.error.not_configured"
        case .discoveryTimeout: return "aux_valve.error.discovery_timeout"
        case .deviceNotFound: return "aux_valve.error.device_not_found"
        case .unreachable: return nil
        case .wrongDevice: return "aux_valve.error.wrong_device"
        case .wrongClient: return "aux_valve.error.wrong_client"
        case .unauthorized: return "aux_valve.error.unauthorized"
        case .httpError: return "aux_valve.error.http"
        case .decodeFailed: return "aux_valve.error.decode_failed"
        case .budgetExceeded: return "aux_valve.error.budget_exceeded"
        case .pairingTimeout: return "aux_valve.error.pairing_timeout"
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
            if case .httpError(_, let code) = aux {
                switch code {
                case "bind_not_armed": return "aux_valve.error.bind_not_armed"
                case "pairing_timeout": return "aux_valve.error.pairing_timeout"
                default: break
                }
            }
            return aux.userFacingToken
        }
        return error.localizedDescription
    }
}

/// 解析阀 endpoint：`full` 含 mDNS；`cachedOnly` 仅探测缓存（定时 health 降频用）
enum AuxValveDiscoveryPolicy {
    case full
    case cachedOnly
}

/// mDNS 发现 + HTTP（/health、/status、POST /valve）
final class AuxValveWiFiClient {
    private let browserQueue = DispatchQueue(label: "AuxValveWiFiClient.browser")
    private let resolveQueue = DispatchQueue(label: "AuxValveWiFiClient.resolve")

    // MARK: - Discovery

    func discoverServices(timeout: TimeInterval, settings: AuxValveSettings? = nil) async -> [AuxValveDiscoveredService] {
        let resolveGrace = settings?.probeTimeoutSec ?? AuxValveSettingsDefaults.probeTimeoutSec
        settings?.auxLog("mDNS browse \(AuxValveProtocol.mdnsServiceType) timeout=\(timeout)s resolveGrace=\(resolveGrace)s")
        return await withCheckedContinuation { continuation in
            var collected: [String: AuxValveDiscoveredService] = [:]
            var skippedNames: [String] = []
            var pendingResolves = 0
            var browseEnded = false
            let lock = NSLock()
            var finished = false

            let browser = NWBrowser(
                for: .bonjour(type: AuxValveProtocol.mdnsServiceType, domain: AuxValveProtocol.mdnsDomain),
                using: .tcp
            )

            func sortedList() -> [AuxValveDiscoveredService] {
                Array(collected.values).sorted { $0.deviceId < $1.deviceId }
            }

            func finish(_ services: [AuxValveDiscoveredService]) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                browser.cancel()
                continuation.resume(returning: services)
            }

            func maybeFinish(force: Bool) {
                lock.lock()
                let pending = pendingResolves
                let ended = browseEnded
                let list = sortedList()
                let done = finished
                lock.unlock()
                guard !done else { return }
                if force || (ended && pending == 0) {
                    if list.isEmpty {
                        settings?.auxLog("mDNS browse done: 0 devices (skipped names: \(skippedNames.isEmpty ? "none" : skippedNames.joined(separator: ", ")))", level: .warning)
                    } else {
                        let summary = list.map { "\($0.deviceId)@\($0.host):\($0.port)" }.joined(separator: ", ")
                        settings?.auxLog("mDNS browse done: \(list.count) device(s): \(summary)")
                    }
                    finish(list)
                }
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let err):
                    settings?.auxLog("mDNS browser failed: \(err.localizedDescription)", level: .warning)
                    maybeFinish(force: true)
                case .ready:
                    settings?.auxLog("mDNS browser ready")
                case .waiting(let err):
                    settings?.auxLog("mDNS browser waiting: \(err.localizedDescription)", level: .warning)
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
                    lock.lock()
                    pendingResolves += 1
                    lock.unlock()
                    self.resolveEndpoint(result.endpoint, serviceName: name, deviceId: deviceId, settings: settings) { host, port in
                        defer {
                            lock.lock()
                            pendingResolves -= 1
                            lock.unlock()
                            maybeFinish(force: false)
                        }
                        let resolvedHost = host ?? AuxValveProtocol.mdnsHostname(for: deviceId)
                        let resolvedPort = port ?? AuxValveProtocol.defaultHTTPPort
                        if host == nil {
                            settings?.auxLog("mDNS resolve fallback for \(name) -> \(resolvedHost):\(resolvedPort)", level: .warning)
                        }
                        lock.lock()
                        collected[deviceId] = AuxValveDiscoveredService(
                            id: deviceId,
                            deviceId: deviceId,
                            serviceName: name,
                            host: resolvedHost,
                            port: resolvedPort,
                            firmwareVersion: nil
                        )
                        lock.unlock()
                        settings?.auxLog("mDNS resolved \(name) -> \(resolvedHost):\(resolvedPort)")
                    }
                }
            }

            browser.start(queue: browserQueue)
            browserQueue.asyncAfter(deadline: .now() + timeout) {
                lock.lock()
                browseEnded = true
                lock.unlock()
                maybeFinish(force: false)
                self.browserQueue.asyncAfter(deadline: .now() + resolveGrace) {
                    maybeFinish(force: true)
                }
            }
        }
    }

    /// After mDNS browse: probe each valve with `GET /health` for `firmware_version`.
    func enrichDiscoveredWithFirmwareVersions(
        _ services: [AuxValveDiscoveredService],
        settings: AuxValveSettings
    ) async -> [AuxValveDiscoveredService] {
        guard !services.isEmpty else { return [] }
        let timeout = settings.healthHttpTimeoutSec
        settings.auxLog("scan: probing firmware_version on \(services.count) device(s), timeout=\(timeout)s")
        return await withTaskGroup(of: (String, AuxValveDiscoveredService).self) { group in
            for service in services {
                group.addTask { [self] in
                    var updated = service
                    do {
                        let response = try await self.getHealth(
                            host: service.host,
                            port: service.port,
                            settings: settings,
                            timeout: timeout
                        )
                        if response.httpStatus == 200,
                           response.ok,
                           response.deviceId?.uppercased() == service.deviceId.uppercased(),
                           let fw = response.firmwareVersion?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !fw.isEmpty {
                            updated.firmwareVersion = fw
                        }
                    } catch {
                        settings.auxLog(
                            "scan: health failed \(service.deviceId) @ \(service.host):\(service.port): "
                            + error.localizedDescription,
                            level: .warning
                        )
                    }
                    return (service.deviceId, updated)
                }
            }
            var byId: [String: AuxValveDiscoveredService] = [:]
            for await (deviceId, item) in group {
                byId[deviceId] = item
            }
            let result = services.map { byId[$0.deviceId] ?? $0 }
            let withFw = result.filter { $0.firmwareVersion != nil }.count
            settings.auxLog("scan: firmware_version on \(withFw)/\(result.count) device(s)")
            return result
        }
    }

    func resolveTargetDevice(
        settings: AuxValveSettings,
        budgetDeadline: Date?,
        discoveryPolicy: AuxValveDiscoveryPolicy = .full
    ) async throws -> (host: String, port: UInt16) {
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

        guard discoveryPolicy == .full else {
            throw AuxValveClientError.deviceNotFound
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
            return resp.httpStatus == 200
                && resp.ok
                && resp.deviceId?.uppercased() == settings.normalizedTargetDeviceId
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
        let lock = NSLock()
        var finished = false
        func finishOnce(_ host: String?, _ port: UInt16?) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            completion(host, port)
        }

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
                        finishOnce(hostStr, portNum)
                    } else {
                        finishOnce(nil, nil)
                    }
                } else {
                    connection.cancel()
                    finishOnce(nil, nil)
                }
            case .failed(let err):
                settings?.auxLog("NWConnection resolve failed \(serviceName): \(err.localizedDescription)", level: .warning)
                finishOnce(nil, nil)
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: resolveQueue)
        let probeTimeout = settings?.probeTimeoutSec ?? AuxValveSettingsDefaults.probeTimeoutSec
        resolveQueue.asyncAfter(deadline: .now() + probeTimeout) {
            if !finished {
                connection.cancel()
                finishOnce(nil, nil)
            }
        }
    }

    // MARK: - HTTP

    func performHealthCheck(settings: AuxValveSettings, periodic: Bool = false) async -> AuxValveHealthResult {
        guard settings.enabled, !settings.normalizedTargetDeviceId.isEmpty else {
            return AuxValveHealthResult(reachable: false, latencyMs: nil, valve: nil, moving: false, errorMessage: nil, boundClientId: nil, bindArmed: false, physicalUnbindPending: false, physicalUnbindSeq: nil, valveRev: nil, firmwareVersion: nil)
        }
        let discoveryPolicy: AuxValveDiscoveryPolicy
        if !periodic || settings.isAuxValveReachable || settings.consumePeriodicFullDiscoverySlot() {
            discoveryPolicy = .full
        } else {
            discoveryPolicy = .cachedOnly
        }
        do {
            let endpoint = try await resolveTargetDevice(
                settings: settings,
                budgetDeadline: nil,
                discoveryPolicy: discoveryPolicy
            )
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
                settings.auxLog("health rejected: 401 (device may require legacy token in NVS)", level: .warning)
                return AuxValveHealthResult(reachable: false, latencyMs: response.latencyMs, valve: response.valve, moving: false, errorMessage: AuxValveClientError.unauthorized.userFacingToken, boundClientId: nil, bindArmed: false, physicalUnbindPending: false, physicalUnbindSeq: nil, valveRev: nil, firmwareVersion: response.firmwareVersion)
            }
            guard response.ok, response.deviceId?.uppercased() == settings.normalizedTargetDeviceId else {
                settings.auxLog(
                    "health rejected: want device_id=\(settings.normalizedTargetDeviceId) got=\(response.deviceId ?? "nil")",
                    level: .warning
                )
                return AuxValveHealthResult(reachable: false, latencyMs: response.latencyMs, valve: response.valve, moving: false, errorMessage: AuxValveClientError.wrongDevice.userFacingToken, boundClientId: nil, bindArmed: false, physicalUnbindPending: false, physicalUnbindSeq: nil, valveRev: nil, firmwareVersion: response.firmwareVersion)
            }
            let moving = response.moving ?? (response.valve == "moving")
            return AuxValveHealthResult(
                reachable: true,
                latencyMs: response.latencyMs,
                valve: response.valve,
                moving: moving,
                errorMessage: nil,
                boundClientId: response.boundClientId,
                bindArmed: response.bindArmed ?? false,
                physicalUnbindPending: response.physicalUnbindPending ?? false,
                physicalUnbindSeq: response.physicalUnbindSeq,
                valveRev: response.valveRev,
                firmwareVersion: response.firmwareVersion
            )
        } catch {
            return AuxValveHealthResult(reachable: false, latencyMs: nil, valve: nil, moving: false, errorMessage: AuxValveUserMessage.from(error), boundClientId: nil, bindArmed: false, physicalUnbindPending: false, physicalUnbindSeq: nil, valveRev: nil, firmwareVersion: nil)
        }
    }

    func getHealth(host: String, port: UInt16, settings: AuxValveSettings, timeout: TimeInterval) async throws -> AuxValveHTTPResponse {
        try await request(path: AuxValveProtocol.healthPath, host: host, port: port, method: "GET", body: nil, settings: settings, timeout: timeout)
    }

    func getStatus(host: String, port: UInt16, settings: AuxValveSettings, timeout: TimeInterval) async throws -> AuxValveHTTPResponse {
        try await request(path: AuxValveProtocol.statusPath, host: host, port: port, method: "GET", body: nil, settings: settings, timeout: timeout)
    }

    func fetchPressure(settings: AuxValveSettings) async throws -> AuxValvePressureReading {
        let endpoint = try await resolveTargetDevice(settings: settings, budgetDeadline: nil)
        return try await getPressure(
            host: endpoint.host,
            port: endpoint.port,
            settings: settings,
            timeout: settings.httpTimeoutSec
        )
    }

    func getPressure(host: String, port: UInt16, settings: AuxValveSettings, timeout: TimeInterval) async throws -> AuxValvePressureReading {
        guard let url = AuxValveProtocol.makeHTTPURL(host: host, port: port, path: AuxValveProtocol.pressurePath) else {
            throw AuxValveClientError.unreachable("invalid url (\(host):\(port))")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        settings.auxLog("GET \(url.absoluteString) timeout=\(timeout)s")
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
        if httpStatus == 401 { throw AuxValveClientError.unauthorized }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AuxValveClientError.decodeFailed
        }
        let ok = json["ok"] as? Bool ?? false
        let errorCode = json["error"] as? String
        settings.auxLog(
            "HTTP response \(httpStatus) ok=\(ok) err=\(errorCode ?? "—") "
            + "\(String(format: "%.0f", latencyMs))ms"
        )
        guard httpStatus == 200, ok else {
            throw AuxValveClientError.httpError(httpStatus, errorCode)
        }
        return parsePressureJSON(json)
    }

    private func parsePressureJSON(_ json: [String: Any]) -> AuxValvePressureReading {
        AuxValvePressureReading(
            sensorOk: json["sensor_ok"] as? Bool ?? false,
            valid: json["valid"] as? Bool ?? false,
            pressureMbar: json["pressure_mbar"] as? Double,
            temperatureC: json["temperature_c"] as? Double,
            sampleIntervalMs: json["sample_interval_ms"] as? Int ?? 1000,
            ageMs: json["age_ms"] as? Int
        )
    }

    func postValve(action: String, host: String, port: UInt16, settings: AuxValveSettings, timeout: TimeInterval) async throws -> AuxValveHTTPResponse {
        var body: [String: Any] = [
            "action": action,
            "device_id": settings.normalizedTargetDeviceId,
            "client_id": settings.workstationClientId,
        ]
        settings.auxLog("POST /valve \(host):\(port) action=\(action) device_id=\(settings.normalizedTargetDeviceId) client_id=\(settings.workstationClientId.prefix(8))…")
        return try await request(path: AuxValveProtocol.valvePath, host: host, port: port, method: "POST", body: body, settings: settings, timeout: timeout)
    }

    func postBindRequest(host: String, port: UInt16, settings: AuxValveSettings, timeout: TimeInterval) async throws -> AuxValveHTTPResponse {
        let body: [String: Any] = [
            "client_id": settings.workstationClientId,
        ]
        settings.auxLog("POST /bind/request \(host):\(port) client_id=\(settings.workstationClientId.prefix(8))…")
        return try await request(
            path: AuxValveProtocol.bindRequestPath,
            host: host,
            port: port,
            method: "POST",
            body: body,
            settings: settings,
            timeout: timeout
        )
    }

    /// 配对申请后须阀 3s 长按；轮询 `/health` 直至 `bind_armed` 或 30s 超时
    func waitForBindArmed(
        host: String,
        port: UInt16,
        settings: AuxValveSettings,
        deadline: Date,
        onProgress: (@MainActor (AuxValvePairingPollState) -> Void)? = nil
    ) async throws {
        let pollNs: UInt64 = 500_000_000
        while Date() < deadline {
            let health = try await getHealth(
                host: host,
                port: port,
                settings: settings,
                timeout: settings.healthHttpTimeoutSec
            )
            guard health.httpStatus == 200, health.ok else {
                throw AuxValveClientError.httpError(health.httpStatus, health.errorCode)
            }
            if health.bindArmed == true {
                settings.auxLog("pairing: bind_armed=true", level: .info)
                return
            }
            let left = health.pairingSecondsLeft ?? max(0, Int(deadline.timeIntervalSinceNow))
            let poll = AuxValvePairingPollState(
                secondsLeft: left,
                buttonPressed: health.buttonPressed ?? false,
                buttonHoldMs: health.buttonHoldMs ?? 0,
                buttonBindReady: health.buttonBindReady ?? false
            )
            if let onProgress {
                await onProgress(poll)
            }
            if health.bindPending != true {
                settings.auxLog("pairing: window ended without bind_armed", level: .warning)
                throw AuxValveClientError.pairingTimeout
            }
            if poll.buttonBindReady {
                settings.auxLog("pairing: button_bind_ready hold=\(poll.buttonHoldMs)ms — release to confirm", level: .info)
            } else if poll.buttonPressed {
                settings.auxLog("pairing: button held \(poll.buttonHoldMs)ms, ~\(left)s window left", level: .info)
            } else {
                settings.auxLog("pairing: waiting for 3s press, ~\(left)s left", level: .info)
            }
            try await Task.sleep(nanoseconds: pollNs)
        }
        throw AuxValveClientError.pairingTimeout
    }

    func postBind(host: String, port: UInt16, settings: AuxValveSettings, timeout: TimeInterval) async throws -> AuxValveHTTPResponse {
        let body: [String: Any] = [
            "client_id": settings.workstationClientId,
            "station_label": settings.workstationLabel,
        ]
        settings.auxLog("POST /bind \(host):\(port) client_id=\(settings.workstationClientId.prefix(8))… label=\(settings.workstationLabel)")
        return try await request(path: AuxValveProtocol.bindPath, host: host, port: port, method: "POST", body: body, settings: settings, timeout: timeout)
    }

    func postUnbind(host: String, port: UInt16, settings: AuxValveSettings, timeout: TimeInterval) async throws -> AuxValveHTTPResponse {
        let body: [String: Any] = [
            "client_id": settings.workstationClientId,
        ]
        settings.auxLog("POST /unbind \(host):\(port) client_id=\(settings.workstationClientId.prefix(8))…")
        return try await request(path: AuxValveProtocol.unbindPath, host: host, port: port, method: "POST", body: body, settings: settings, timeout: timeout)
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
            if status.errorCode == "wrong_client" {
                throw AuxValveClientError.wrongClient
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
        settings.auxLog("\(method) \(url.absoluteString) timeout=\(timeout)s")

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
            firmwareVersion: json?["firmware_version"] as? String,
            valve: json?["valve"] as? String,
            moving: json?["moving"] as? Bool,
            elapsedMs: (json?["elapsed_ms"] as? NSNumber)?.intValue,
            errorCode: json?["error"] as? String,
            latencyMs: latencyMs,
            boundClientId: json?["bound_client_id"] as? String,
            bindArmed: json?["bind_armed"] as? Bool,
            bindPending: json?["bind_pending"] as? Bool,
            pairingSecondsLeft: json?["pairing_seconds_left"] as? Int,
            buttonPressed: json?["button_pressed"] as? Bool,
            buttonHoldMs: json?["button_hold_ms"] as? Int,
            buttonBindReady: json?["button_bind_ready"] as? Bool,
            physicalUnbindPending: json?["physical_unbind_pending"] as? Bool,
            physicalUnbindSeq: json?["physical_unbind_seq"] as? Int,
            physicalUnbindAgeMs: json?["physical_unbind_age_ms"] as? Int,
            valveRev: json?["valve_rev"] as? Int
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
