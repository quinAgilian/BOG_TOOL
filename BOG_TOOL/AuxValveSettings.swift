import Foundation
import SwiftUI

extension Notification.Name {
    static let auxValveHealthDidChange = Notification.Name("auxValveHealthDidChange")
}

/// 本地已选阀与阀 NVS 绑定是否一致（方案 A：保留本地 target，不对齐时禁自动并提示）
enum AuxValveBindingMismatch: Equatable {
    case none
    case deviceUnbound
    case boundToOtherStation
}

private enum AuxValveSettingsKeys {
    static let enabled = "aux_valve_enabled"
    static let targetDeviceId = "aux_valve_target_device_id"
    static let workstationClientId = "aux_valve_workstation_client_id"
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
    static let ackedPhysicalUnbindSeq = "aux_valve_acked_physical_unbind_seq"
    static let lastPhysicalUnbindAlertSeq = "aux_valve_last_physical_unbind_alert_seq"
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

    @Published private(set) var lastBoundClientIdOnDevice: String?
    @Published private(set) var lastBindArmedOnDevice = false
    @Published private(set) var lastPhysicalUnbindPending = false
    @Published private(set) var lastPhysicalUnbindSeq: Int?
    @Published private(set) var lastValveRevOnDevice: Int?
    @Published private(set) var lastFirmwareVersionOnDevice: String?
    @Published var showPhysicalUnbindNotice = false

    private var valveBurstPollTask: Task<Void, Never>?

    /// 本工位 UUID（首次启动生成，与阀 NVS `bound_client_id` 对应）
    var workstationClientId: String {
        let ud = UserDefaults.standard
        if let existing = ud.string(forKey: AuxValveSettingsKeys.workstationClientId), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        ud.set(created, forKey: AuxValveSettingsKeys.workstationClientId)
        return created
    }

    var workstationLabel: String {
        ProcessInfo.processInfo.hostName
    }

    @Published var targetDeviceId: String {
        didSet {
            let normalized = Self.normalizeDeviceId(targetDeviceId)
            if normalized != targetDeviceId { targetDeviceId = normalized; return }
            UserDefaults.standard.set(normalized, forKey: AuxValveSettingsKeys.targetDeviceId)
        }
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

    /// 产线 WiFi 自动：须在线且阀 NVS 认本工位（与本地 target 对齐，方案 A 不清本地 ID）
    var canUseAuxValveAutomation: Bool {
        enabled
            && !normalizedTargetDeviceId.isEmpty
            && isAuxValveReachable
            && isWorkstationAuthorizedOnDevice
    }

    /// 手动试阀：与自动同一授权门槛 + 非 moving
    var canRunManualValveTest: Bool {
        canUseAuxValveAutomation && !lastStatusMoving
    }

    /// health 可达时：阀 NVS `bound_client_id` 与本工位一致
    var isWorkstationAuthorizedOnDevice: Bool {
        guard isAuxValveReachable else { return false }
        guard let bound = lastBoundClientIdOnDevice, !bound.isEmpty else { return false }
        return bound == workstationClientId
    }

    /// 已选 target 且在线，但阀侧未认本工位（保留本地绑定，仅禁自动）
    var deviceBindingMismatch: AuxValveBindingMismatch {
        guard enabled, !normalizedTargetDeviceId.isEmpty, isAuxValveReachable else {
            return .none
        }
        guard let bound = lastBoundClientIdOnDevice, !bound.isEmpty else {
            return .deviceUnbound
        }
        if bound != workstationClientId {
            return .boundToOtherStation
        }
        return .none
    }

    private var lastLoggedBindingMismatch: AuxValveBindingMismatch = .none

    private var ackedPhysicalUnbindSeq: Int {
        UserDefaults.standard.integer(forKey: AuxValveSettingsKeys.ackedPhysicalUnbindSeq)
    }

    /// 阀上 3s 物理解绑且本 App 尚未确认该序号
    var isPhysicalUnbindOnDevice: Bool {
        guard lastPhysicalUnbindPending, let seq = lastPhysicalUnbindSeq, seq > 0 else {
            return false
        }
        return seq > ackedPhysicalUnbindSeq
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
        if ud.string(forKey: AuxValveSettingsKeys.workstationClientId)?.isEmpty != false {
            ud.set(UUID().uuidString, forKey: AuxValveSettingsKeys.workstationClientId)
        }
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
            auxLog("health check start target=\(normalizedTargetDeviceId)")
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
        let wasMoving = lastStatusMoving
        isAuxValveReachable = result.reachable
        lastHealthLatencyMs = result.latencyMs
        lastStatusValve = result.valve
        lastStatusMoving = result.moving
        lastHealthError = result.errorMessage
        lastBoundClientIdOnDevice = result.boundClientId
        lastBindArmedOnDevice = result.bindArmed
        lastPhysicalUnbindPending = result.physicalUnbindPending
        lastPhysicalUnbindSeq = result.physicalUnbindSeq
        let wasRev = lastValveRevOnDevice
        lastValveRevOnDevice = result.valveRev
        if result.reachable, let fw = result.firmwareVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !fw.isEmpty {
            lastFirmwareVersionOnDevice = fw
        }
        processPhysicalUnbindNotice(from: result)
        logBindingMismatchIfChanged()
        let valveChanged = wasValve != result.valve
            || wasMoving != result.moving
            || wasRev != result.valveRev
        let changed = wasReachable != isAuxValveReachable
            || wasError != lastHealthError
            || valveChanged
        if result.reachable, valveChanged {
            scheduleValveStateBurstPollIfNeeded(from: result)
        }
        if !logOnlyOnChange || changed {
            if result.reachable {
                let ms = result.latencyMs.map { String(format: "%.0f", $0) } ?? "—"
                let boundHint = result.boundClientId.map { String($0.prefix(8)) + "…" } ?? "none"
                auxLog(
                    "health OK valve=\(result.valve ?? "?") moving=\(result.moving) latency=\(ms)ms "
                    + "bound=\(boundHint) auto=\(canUseAuxValveAutomation)"
                )
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

    /// 阀动作中或阀态变化时加密 health 轮询，便于底栏跟上本地短按
    private func scheduleValveStateBurstPollIfNeeded(from result: AuxValveHealthResult) {
        guard result.moving || result.valve == "moving" else { return }
        valveBurstPollTask?.cancel()
        let intervalMs = movingPollIntervalMs
        let maxSec = movingPollMaxSec
        valveBurstPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(maxSec)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
                if Task.isCancelled { break }
                let snap = await self.wifiClient.performHealthCheck(settings: self, periodic: true)
                self.applyHealthResult(snap, logOnlyOnChange: true)
                if !snap.moving, snap.valve != "moving" { break }
            }
            self.valveBurstPollTask = nil
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
        lastBoundClientIdOnDevice = nil
        lastBindArmedOnDevice = false
        lastPhysicalUnbindPending = false
        lastPhysicalUnbindSeq = nil
        lastValveRevOnDevice = nil
        lastFirmwareVersionOnDevice = nil
        valveBurstPollTask?.cancel()
        valveBurstPollTask = nil
        lastLoggedBindingMismatch = .none
        NotificationCenter.default.post(name: .auxValveHealthDidChange, object: self)
    }

    private var lastShownPhysicalUnbindAlertSeq: Int {
        UserDefaults.standard.integer(forKey: AuxValveSettingsKeys.lastPhysicalUnbindAlertSeq)
    }

    private func processPhysicalUnbindNotice(from result: AuxValveHealthResult) {
        guard result.reachable, !normalizedTargetDeviceId.isEmpty else { return }
        guard result.physicalUnbindPending, let seq = result.physicalUnbindSeq, seq > ackedPhysicalUnbindSeq else {
            return
        }
        guard seq > lastShownPhysicalUnbindAlertSeq else { return }
        showPhysicalUnbindNotice = true
        auxLog(
            "physical unbind on valve seq=\(seq) (acked=\(ackedPhysicalUnbindSeq)) — WiFi automation disabled",
            level: .warning
        )
    }

    func acknowledgePhysicalUnbindNotice() {
        guard let seq = lastPhysicalUnbindSeq, seq > 0 else {
            showPhysicalUnbindNotice = false
            return
        }
        UserDefaults.standard.set(seq, forKey: AuxValveSettingsKeys.ackedPhysicalUnbindSeq)
        UserDefaults.standard.set(seq, forKey: AuxValveSettingsKeys.lastPhysicalUnbindAlertSeq)
        showPhysicalUnbindNotice = false
        auxLog("physical unbind notice acknowledged seq=\(seq)")
    }

    private func logBindingMismatchIfChanged() {
        let mismatch = deviceBindingMismatch
        guard mismatch != lastLoggedBindingMismatch else { return }
        lastLoggedBindingMismatch = mismatch
        switch mismatch {
        case .none:
            if !normalizedTargetDeviceId.isEmpty, isAuxValveReachable {
                auxLog("binding sync OK: device \(normalizedTargetDeviceId) recognizes this station")
            }
        case .deviceUnbound:
            if isPhysicalUnbindOnDevice {
                auxLog(
                    "binding drift (A): valve 3s physical unbind detected — re-bind or clear local target",
                    level: .warning
                )
            } else {
                auxLog(
                    "binding drift (A): local target=\(normalizedTargetDeviceId) but valve has no bound_client_id — "
                    + "WiFi automation disabled; re-bind or unbind in settings",
                    level: .warning
                )
            }
        case .boundToOtherStation:
            let remote = lastBoundClientIdOnDevice.map { String($0.prefix(8)) + "…" } ?? "?"
            auxLog(
                "binding drift (A): local target=\(normalizedTargetDeviceId) valve bound to \(remote) "
                + "(not this station) — WiFi automation disabled",
                level: .warning
            )
        }
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
        valveBurstPollTask?.cancel()
        valveBurstPollTask = nil
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
    let boundClientId: String?
    let bindArmed: Bool
    let physicalUnbindPending: Bool
    let physicalUnbindSeq: Int?
    let valveRev: Int?
    let firmwareVersion: String?
}
