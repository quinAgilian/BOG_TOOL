import Foundation
import SwiftUI

extension Notification.Name {
    static let auxValveHealthDidChange = Notification.Name("auxValveHealthDidChange")
}

private enum AuxValveSettingsKeys {
    static let enabled = "aux_valve_enabled"
    static let targetDeviceId = "aux_valve_target_device_id"
    static let token = "aux_valve_token"
    static let discoverTimeoutSec = "aux_valve_discover_timeout_sec"
    static let probeTimeoutSec = "aux_valve_probe_timeout_sec"
    static let httpTimeoutSec = "aux_valve_http_timeout_sec"
    static let operationBudgetSec = "aux_valve_operation_budget_sec"
    static let movingPollIntervalMs = "aux_valve_moving_poll_interval_ms"
    static let movingPollMaxSec = "aux_valve_moving_poll_max_sec"
    static let healthCheckIntervalSec = "aux_valve_health_check_interval_sec"
    static let healthHttpTimeoutSec = "aux_valve_health_http_timeout_sec"
    static let latencyGreenMaxMs = "aux_valve_latency_green_max_ms"
    static let latencyYellowMaxMs = "aux_valve_latency_yellow_max_ms"
    static let orchestrationRetryCount = "aux_valve_orchestration_retry_count"
    static let postValveSettleSec = "aux_valve_post_valve_settle_sec"
    static let keepaliveEnabled = "aux_valve_keepalive_enabled"
    static let keepaliveIntervalSec = "aux_valve_keepalive_interval_sec"
    static let cachedEndpointTtlSec = "aux_valve_cached_endpoint_ttl_sec"
    static let cachedHost = "aux_valve_cached_host"
    static let cachedPort = "aux_valve_cached_port"
    static let cachedAt = "aux_valve_cached_at"
    /// One-time migration: old default health poll was 15s (plan now 3s)
    static let migratedHealthInterval3s = "aux_valve_migrated_health_interval_3s"
}

/// 写入主界面日志区（由 ContentView 注入 BLEManager.appendLog）
typealias AuxValveLogHandler = (String, BLEManager.LogLevel) -> Void

/// WiFi 产线气阀工位配置（仿 ServerSettings）
final class AuxValveSettings: ObservableObject {
    /// 强引用；勿用 weak（App init 局部变量赋值后会释放，导致周期健康检查 client=false）
    let wifiClient: AuxValveWiFiClient
    private var logHandler: AuxValveLogHandler?

    /// 为 false 时抑制 debug/warning 级 aux 日志（定时 health 轮询，避免 mDNS/HTTP 刷屏）
    var auxHttpTraceEnabled = true

    /// 定时 health 且不可达时，每隔 N 次才做一次完整 mDNS（其余仅探测缓存 endpoint）
    private static let periodicFullDiscoveryEvery = 10
    private var periodicHealthPollIndex = 0

    /// 绑定日志区；msg 会自动加 `[AuxValve]` 前缀，level 默认 debug
    func bindLogHandler(_ handler: @escaping AuxValveLogHandler) {
        logHandler = handler
        auxLog("log handler attached")
    }

    func auxLog(_ message: String, level: BLEManager.LogLevel = .debug) {
        if !auxHttpTraceEnabled, level == .debug || level == .warning { return }
        guard let logHandler else { return }
        let line = "[AuxValve] \(message)"
        if Thread.isMainThread {
            logHandler(line, level)
        } else {
            DispatchQueue.main.async { logHandler(line, level) }
        }
    }

    var tokenConfiguredDescription: String {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "none" }
        if t.count <= 8 { return "len=\(t.count)" }
        return "len=\(t.count) prefix=\(t.prefix(4))…"
    }

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: AuxValveSettingsKeys.enabled)
            if enabled {
                startHealthTimerIfNeeded()
                triggerHealthCheck()
            } else {
                stopHealthTimer()
                clearReachability()
            }
        }
    }

    @Published var targetDeviceId: String {
        didSet {
            let normalized = Self.normalizeDeviceId(targetDeviceId)
            if normalized != targetDeviceId { targetDeviceId = normalized; return }
            UserDefaults.standard.set(normalized, forKey: AuxValveSettingsKeys.targetDeviceId)
        }
    }

    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: AuxValveSettingsKeys.token) }
    }

    @Published var discoverTimeoutSec: TimeInterval {
        didSet {
            let v = Self.clamp(discoverTimeoutSec, min: AuxValveSettingsDefaults.discoverTimeoutMin, max: AuxValveSettingsDefaults.discoverTimeoutMax)
            if v != discoverTimeoutSec { discoverTimeoutSec = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.discoverTimeoutSec)
        }
    }

    @Published var probeTimeoutSec: TimeInterval {
        didSet {
            let v = Self.clamp(probeTimeoutSec, min: AuxValveSettingsDefaults.probeTimeoutMin, max: AuxValveSettingsDefaults.probeTimeoutMax)
            if v != probeTimeoutSec { probeTimeoutSec = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.probeTimeoutSec)
        }
    }

    @Published var httpTimeoutSec: TimeInterval {
        didSet {
            let v = Self.clamp(httpTimeoutSec, min: AuxValveSettingsDefaults.httpTimeoutMin, max: AuxValveSettingsDefaults.httpTimeoutMax)
            if v != httpTimeoutSec { httpTimeoutSec = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.httpTimeoutSec)
        }
    }

    @Published var operationBudgetSec: TimeInterval {
        didSet {
            let v = Self.clamp(operationBudgetSec, min: AuxValveSettingsDefaults.operationBudgetMin, max: AuxValveSettingsDefaults.operationBudgetMax)
            if v != operationBudgetSec { operationBudgetSec = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.operationBudgetSec)
        }
    }

    @Published var movingPollIntervalMs: Int {
        didSet {
            let v = min(max(movingPollIntervalMs, AuxValveSettingsDefaults.movingPollIntervalMinMs), AuxValveSettingsDefaults.movingPollIntervalMaxMs)
            if v != movingPollIntervalMs { movingPollIntervalMs = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.movingPollIntervalMs)
        }
    }

    @Published var movingPollMaxSec: TimeInterval {
        didSet {
            let v = Self.clamp(movingPollMaxSec, min: AuxValveSettingsDefaults.movingPollMaxMinSec, max: AuxValveSettingsDefaults.movingPollMaxMaxSec)
            if v != movingPollMaxSec { movingPollMaxSec = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.movingPollMaxSec)
        }
    }

    @Published var healthCheckIntervalSec: TimeInterval {
        didSet {
            let v = Self.clamp(healthCheckIntervalSec, min: AuxValveSettingsDefaults.healthCheckIntervalMin, max: AuxValveSettingsDefaults.healthCheckIntervalMax)
            if v != healthCheckIntervalSec { healthCheckIntervalSec = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.healthCheckIntervalSec)
            restartHealthTimerIfNeeded()
        }
    }

    @Published var healthHttpTimeoutSec: TimeInterval {
        didSet {
            let v = Self.clamp(healthHttpTimeoutSec, min: AuxValveSettingsDefaults.healthHttpTimeoutMin, max: AuxValveSettingsDefaults.healthHttpTimeoutMax)
            if v != healthHttpTimeoutSec { healthHttpTimeoutSec = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.healthHttpTimeoutSec)
        }
    }

    @Published var latencyGreenMaxMs: Double {
        didSet {
            let v = Self.clamp(latencyGreenMaxMs, min: AuxValveSettingsDefaults.latencyGreenMinMs, max: AuxValveSettingsDefaults.latencyGreenMaxBoundMs)
            if v != latencyGreenMaxMs { latencyGreenMaxMs = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.latencyGreenMaxMs)
            enforceYellowAtLeastGreen()
        }
    }

    @Published var latencyYellowMaxMs: Double {
        didSet {
            let v = Self.clamp(latencyYellowMaxMs, min: AuxValveSettingsDefaults.latencyYellowMinMs, max: AuxValveSettingsDefaults.latencyYellowMaxBoundMs)
            if v != latencyYellowMaxMs { latencyYellowMaxMs = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.latencyYellowMaxMs)
            enforceYellowAtLeastGreen()
        }
    }

    @Published var orchestrationRetryCount: Int {
        didSet {
            let v = min(max(orchestrationRetryCount, AuxValveSettingsDefaults.orchestrationRetryMin), AuxValveSettingsDefaults.orchestrationRetryMax)
            if v != orchestrationRetryCount { orchestrationRetryCount = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.orchestrationRetryCount)
        }
    }

    @Published var postValveSettleSec: TimeInterval {
        didSet {
            let v = Self.clamp(postValveSettleSec, min: AuxValveSettingsDefaults.postValveSettleMinSec, max: AuxValveSettingsDefaults.postValveSettleMaxSec)
            if v != postValveSettleSec { postValveSettleSec = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.postValveSettleSec)
        }
    }

    @Published var keepaliveEnabled: Bool {
        didSet { UserDefaults.standard.set(keepaliveEnabled, forKey: AuxValveSettingsKeys.keepaliveEnabled) }
    }

    @Published var keepaliveIntervalSec: TimeInterval {
        didSet {
            let v = Self.clamp(keepaliveIntervalSec, min: AuxValveSettingsDefaults.keepaliveIntervalMinSec, max: AuxValveSettingsDefaults.keepaliveIntervalMaxSec)
            if v != keepaliveIntervalSec { keepaliveIntervalSec = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.keepaliveIntervalSec)
        }
    }

    @Published var cachedEndpointTtlSec: TimeInterval {
        didSet {
            let v = Self.clamp(cachedEndpointTtlSec, min: AuxValveSettingsDefaults.cachedEndpointTtlMinSec, max: AuxValveSettingsDefaults.cachedEndpointTtlMaxSec)
            if v != cachedEndpointTtlSec { cachedEndpointTtlSec = v; return }
            UserDefaults.standard.set(v, forKey: AuxValveSettingsKeys.cachedEndpointTtlSec)
        }
    }

    /// 本台 FQC 会话强制人工阀（§4.9，不持久化）
    @Published var useManualValveForCurrentRun = false

    @Published var showAuxValveSettingsSheet = false

    @Published private(set) var isAuxValveReachable = false
    @Published private(set) var lastHealthLatencyMs: Double?
    @Published private(set) var lastStatusValve: String?
    @Published private(set) var lastStatusMoving = false
    @Published private(set) var lastHealthError: String?

    var canUseAuxValveAutomation: Bool {
        enabled && !normalizedTargetDeviceId.isEmpty && isAuxValveReachable
    }

    var normalizedTargetDeviceId: String {
        Self.normalizeDeviceId(targetDeviceId)
    }

    var expectedDeviceName: String {
        AuxValveProtocol.deviceName(for: normalizedTargetDeviceId)
    }

    private var healthTimer: Timer?

    init() {
        wifiClient = AuxValveWiFiClient()
        let ud = UserDefaults.standard
        enabled = ud.object(forKey: AuxValveSettingsKeys.enabled) as? Bool ?? AuxValveSettingsDefaults.enabled
        targetDeviceId = Self.normalizeDeviceId(ud.string(forKey: AuxValveSettingsKeys.targetDeviceId) ?? AuxValveSettingsDefaults.targetDeviceId)
        token = ud.string(forKey: AuxValveSettingsKeys.token) ?? AuxValveSettingsDefaults.token
        discoverTimeoutSec = Self.loadInterval(ud, key: AuxValveSettingsKeys.discoverTimeoutSec, defaultValue: AuxValveSettingsDefaults.discoverTimeoutSec, min: AuxValveSettingsDefaults.discoverTimeoutMin, max: AuxValveSettingsDefaults.discoverTimeoutMax)
        probeTimeoutSec = Self.loadInterval(ud, key: AuxValveSettingsKeys.probeTimeoutSec, defaultValue: AuxValveSettingsDefaults.probeTimeoutSec, min: AuxValveSettingsDefaults.probeTimeoutMin, max: AuxValveSettingsDefaults.probeTimeoutMax)
        httpTimeoutSec = Self.loadInterval(ud, key: AuxValveSettingsKeys.httpTimeoutSec, defaultValue: AuxValveSettingsDefaults.httpTimeoutSec, min: AuxValveSettingsDefaults.httpTimeoutMin, max: AuxValveSettingsDefaults.httpTimeoutMax)
        operationBudgetSec = Self.loadInterval(ud, key: AuxValveSettingsKeys.operationBudgetSec, defaultValue: AuxValveSettingsDefaults.operationBudgetSec, min: AuxValveSettingsDefaults.operationBudgetMin, max: AuxValveSettingsDefaults.operationBudgetMax)
        movingPollIntervalMs = Self.loadInt(ud, key: AuxValveSettingsKeys.movingPollIntervalMs, defaultValue: AuxValveSettingsDefaults.movingPollIntervalMs, min: AuxValveSettingsDefaults.movingPollIntervalMinMs, max: AuxValveSettingsDefaults.movingPollIntervalMaxMs)
        movingPollMaxSec = Self.loadInterval(ud, key: AuxValveSettingsKeys.movingPollMaxSec, defaultValue: AuxValveSettingsDefaults.movingPollMaxSec, min: AuxValveSettingsDefaults.movingPollMaxMinSec, max: AuxValveSettingsDefaults.movingPollMaxMaxSec)
        Self.migrateLegacyHealthCheckInterval(ud: ud)
        healthCheckIntervalSec = Self.loadInterval(ud, key: AuxValveSettingsKeys.healthCheckIntervalSec, defaultValue: AuxValveSettingsDefaults.healthCheckIntervalSec, min: AuxValveSettingsDefaults.healthCheckIntervalMin, max: AuxValveSettingsDefaults.healthCheckIntervalMax)
        healthHttpTimeoutSec = Self.loadInterval(ud, key: AuxValveSettingsKeys.healthHttpTimeoutSec, defaultValue: AuxValveSettingsDefaults.healthHttpTimeoutSec, min: AuxValveSettingsDefaults.healthHttpTimeoutMin, max: AuxValveSettingsDefaults.healthHttpTimeoutMax)
        latencyGreenMaxMs = Self.loadDouble(ud, key: AuxValveSettingsKeys.latencyGreenMaxMs, defaultValue: AuxValveSettingsDefaults.latencyGreenMaxMs, min: AuxValveSettingsDefaults.latencyGreenMinMs, max: AuxValveSettingsDefaults.latencyGreenMaxBoundMs)
        latencyYellowMaxMs = Self.loadDouble(ud, key: AuxValveSettingsKeys.latencyYellowMaxMs, defaultValue: AuxValveSettingsDefaults.latencyYellowMaxMs, min: AuxValveSettingsDefaults.latencyYellowMinMs, max: AuxValveSettingsDefaults.latencyYellowMaxBoundMs)
        orchestrationRetryCount = Self.loadInt(ud, key: AuxValveSettingsKeys.orchestrationRetryCount, defaultValue: AuxValveSettingsDefaults.orchestrationRetryCount, min: AuxValveSettingsDefaults.orchestrationRetryMin, max: AuxValveSettingsDefaults.orchestrationRetryMax)
        postValveSettleSec = Self.loadInterval(ud, key: AuxValveSettingsKeys.postValveSettleSec, defaultValue: AuxValveSettingsDefaults.postValveSettleSec, min: AuxValveSettingsDefaults.postValveSettleMinSec, max: AuxValveSettingsDefaults.postValveSettleMaxSec)
        keepaliveEnabled = ud.object(forKey: AuxValveSettingsKeys.keepaliveEnabled) as? Bool ?? AuxValveSettingsDefaults.keepaliveEnabled
        keepaliveIntervalSec = Self.loadInterval(ud, key: AuxValveSettingsKeys.keepaliveIntervalSec, defaultValue: AuxValveSettingsDefaults.keepaliveIntervalSec, min: AuxValveSettingsDefaults.keepaliveIntervalMinSec, max: AuxValveSettingsDefaults.keepaliveIntervalMaxSec)
        cachedEndpointTtlSec = Self.loadInterval(ud, key: AuxValveSettingsKeys.cachedEndpointTtlSec, defaultValue: AuxValveSettingsDefaults.cachedEndpointTtlSec, min: AuxValveSettingsDefaults.cachedEndpointTtlMinSec, max: AuxValveSettingsDefaults.cachedEndpointTtlMaxSec)
        enforceYellowAtLeastGreen(persist: false)
        if enabled { startHealthTimerIfNeeded() }
    }

    func resetManualValveForNewRun() {
        useManualValveForCurrentRun = false
    }

    /// - Parameter periodic: 定时器触发的轮询；降低 debug 日志量，仅在可达性/阀位变化时记录摘要
    func triggerHealthCheck(periodic: Bool = false) {
        guard enabled, !normalizedTargetDeviceId.isEmpty else {
            if !periodic {
                auxLog("health skip: enabled=\(enabled) targetId=\(normalizedTargetDeviceId.isEmpty ? "empty" : normalizedTargetDeviceId)")
            }
            clearReachability(log: !periodic)
            return
        }
        if !periodic {
            auxLog("health check start target=\(normalizedTargetDeviceId) token=\(tokenConfiguredDescription)")
        }
        Task {
            let wasTracing = self.auxHttpTraceEnabled
            if periodic { self.auxHttpTraceEnabled = false }
            let result = await wifiClient.performHealthCheck(settings: self, periodic: periodic)
            if periodic { self.auxHttpTraceEnabled = wasTracing }
            await MainActor.run {
                self.applyHealthResult(result, logOnlyOnChange: periodic)
            }
        }
    }

    func cachedEndpointIfValid() -> (host: String, port: UInt16)? {
        let ud = UserDefaults.standard
        guard let host = ud.string(forKey: AuxValveSettingsKeys.cachedHost), !host.isEmpty else { return nil }
        let port = ud.object(forKey: AuxValveSettingsKeys.cachedPort) as? Int ?? Int(AuxValveProtocol.defaultHTTPPort)
        let at = ud.double(forKey: AuxValveSettingsKeys.cachedAt)
        guard at > 0, Date().timeIntervalSince1970 - at <= cachedEndpointTtlSec else { return nil }
        return (host, UInt16(clamping: port))
    }

    func saveCachedEndpoint(host: String, port: UInt16) {
        guard let normalized = AuxValveProtocol.normalizedHTTPHost(host) else { return }
        let ud = UserDefaults.standard
        ud.set(normalized, forKey: AuxValveSettingsKeys.cachedHost)
        ud.set(Int(port), forKey: AuxValveSettingsKeys.cachedPort)
        ud.set(Date().timeIntervalSince1970, forKey: AuxValveSettingsKeys.cachedAt)
    }

    private func applyHealthResult(_ result: AuxValveHealthResult, logOnlyOnChange: Bool = false) {
        let wasReachable = isAuxValveReachable
        let wasError = lastHealthError
        let wasValve = lastStatusValve
        isAuxValveReachable = result.reachable
        lastHealthLatencyMs = result.latencyMs
        lastStatusValve = result.valve
        lastStatusMoving = result.moving
        lastHealthError = result.errorMessage
        let changed = wasReachable != isAuxValveReachable
            || wasError != lastHealthError
            || wasValve != lastStatusValve
        if !logOnlyOnChange || changed {
            if result.reachable {
                let ms = result.latencyMs.map { String(format: "%.0f", $0) } ?? "—"
                auxLog("health OK valve=\(result.valve ?? "?") moving=\(result.moving) latency=\(ms)ms")
            } else {
                auxLog("health FAIL: \(result.errorMessage ?? "unknown")", level: .warning)
            }
        }
        if result.reachable {
            periodicHealthPollIndex = 0
        }
        if wasReachable != isAuxValveReachable || changed {
            NotificationCenter.default.post(name: .auxValveHealthDidChange, object: self)
        }
    }

    /// 定时轮询且当前不可达：是否本轮做完整 mDNS（约每 30s 一次，3s 间隔 × 10）
    func consumePeriodicFullDiscoverySlot() -> Bool {
        periodicHealthPollIndex += 1
        guard periodicHealthPollIndex >= Self.periodicFullDiscoveryEvery else { return false }
        periodicHealthPollIndex = 0
        return true
    }

    private func clearReachability(log: Bool = true) {
        if log { auxLog("reachability cleared") }
        isAuxValveReachable = false
        lastHealthLatencyMs = nil
        lastStatusValve = nil
        lastStatusMoving = false
        lastHealthError = nil
        NotificationCenter.default.post(name: .auxValveHealthDidChange, object: self)
    }

    private func startHealthTimerIfNeeded() {
        stopHealthTimer()
        guard enabled else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: healthCheckIntervalSec, repeats: true) { [weak self] _ in
            self?.triggerHealthCheck(periodic: true)
        }
    }

    private func restartHealthTimerIfNeeded() {
        guard enabled else { return }
        startHealthTimerIfNeeded()
    }

    private func stopHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func enforceYellowAtLeastGreen(persist: Bool = true) {
        if latencyYellowMaxMs < latencyGreenMaxMs {
            latencyYellowMaxMs = latencyGreenMaxMs
            if persist {
                UserDefaults.standard.set(latencyYellowMaxMs, forKey: AuxValveSettingsKeys.latencyYellowMaxMs)
            }
        }
    }

    /// v3.10: 工位若仍存旧默认 15s，一次性改为 3s（用户显式设为其他值不动）
    private static func migrateLegacyHealthCheckInterval(ud: UserDefaults) {
        guard !ud.bool(forKey: AuxValveSettingsKeys.migratedHealthInterval3s) else { return }
        defer { ud.set(true, forKey: AuxValveSettingsKeys.migratedHealthInterval3s) }
        guard ud.object(forKey: AuxValveSettingsKeys.healthCheckIntervalSec) != nil else { return }
        let stored = ud.double(forKey: AuxValveSettingsKeys.healthCheckIntervalSec)
        if abs(stored - AuxValveSettingsDefaults.legacyHealthCheckIntervalSec) < 0.001 {
            ud.set(
                AuxValveSettingsDefaults.healthCheckIntervalSec,
                forKey: AuxValveSettingsKeys.healthCheckIntervalSec
            )
        }
    }

    private static func normalizeDeviceId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count >= 4 else { return trimmed }
        return String(trimmed.prefix(4))
    }

    private static func clamp<T: Comparable>(_ value: T, min: T, max: T) -> T {
        Swift.min(Swift.max(value, min), max)
    }

    private static func loadInterval(_ ud: UserDefaults, key: String, defaultValue: TimeInterval, min: TimeInterval, max: TimeInterval) -> TimeInterval {
        let v = ud.object(forKey: key) as? Double ?? defaultValue
        return clamp(v, min: min, max: max)
    }

    private static func loadDouble(_ ud: UserDefaults, key: String, defaultValue: Double, min: Double, max: Double) -> Double {
        let v = ud.object(forKey: key) as? Double ?? defaultValue
        return clamp(v, min: min, max: max)
    }

    private static func loadInt(_ ud: UserDefaults, key: String, defaultValue: Int, min: Int, max: Int) -> Int {
        let v = ud.object(forKey: key) as? Int ?? defaultValue
        return Swift.min(Swift.max(v, min), max)
    }

    deinit {
        stopHealthTimer()
    }
}

struct AuxValveHealthResult {
    let reachable: Bool
    let latencyMs: Double?
    let valve: String?
    let moving: Bool
    let errorMessage: String?
}
