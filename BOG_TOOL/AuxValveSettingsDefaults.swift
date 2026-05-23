import Foundation

/// WiFi 气阀工位配置出厂默认值（唯一允许出现 2.0 / 5.0 / 500 等数字字面量的文件）
enum AuxValveSettingsDefaults {
    static let enabled = false
    static let targetDeviceId = ""

    static let discoverTimeoutSec: TimeInterval = 3.0
    static let probeTimeoutSec: TimeInterval = 2.0
    static let httpTimeoutSec: TimeInterval = 2.0
    static let operationBudgetSec: TimeInterval = 5.0

    static let movingPollIntervalMs: Int = 200
    static let movingPollMaxSec: TimeInterval = 1.0

    static let healthCheckIntervalSec: TimeInterval = 3.0
    /// Previous factory default before v3.10 alignment; migrated on load if still stored
    static let legacyHealthCheckIntervalSec: TimeInterval = 15.0
    static let healthHttpTimeoutSec: TimeInterval = 2.0

    static let latencyGreenMaxMs: Double = 500
    static let latencyYellowMaxMs: Double = 2000

    static let orchestrationRetryCount: Int = 1
    static let postValveSettleSec: TimeInterval = 0.6

    static let keepaliveEnabled = false
    static let keepaliveIntervalSec: TimeInterval = 45.0

    static let cachedEndpointTtlSec: TimeInterval = 300

    // MARK: - 允许范围（Sheet clamp）

    static let discoverTimeoutMin: TimeInterval = 1.0
    static let discoverTimeoutMax: TimeInterval = 5.0

    static let probeTimeoutMin: TimeInterval = 1.0
    static let probeTimeoutMax: TimeInterval = 5.0

    static let httpTimeoutMin: TimeInterval = 1.0
    static let httpTimeoutMax: TimeInterval = 10.0

    static let operationBudgetMin: TimeInterval = 2.0
    static let operationBudgetMax: TimeInterval = 20.0

    static let movingPollIntervalMinMs: Int = 100
    static let movingPollIntervalMaxMs: Int = 1000

    static let movingPollMaxMinSec: TimeInterval = 0.5
    static let movingPollMaxMaxSec: TimeInterval = 5.0

    static let healthCheckIntervalMin: TimeInterval = 2.0
    static let healthCheckIntervalMax: TimeInterval = 30.0

    static let healthHttpTimeoutMin: TimeInterval = 1.0
    static let healthHttpTimeoutMax: TimeInterval = 10.0

    static let latencyGreenMinMs: Double = 100
    static let latencyGreenMaxBoundMs: Double = 2000

    static let latencyYellowMinMs: Double = 500
    static let latencyYellowMaxBoundMs: Double = 5000

    static let orchestrationRetryMin: Int = 0
    static let orchestrationRetryMax: Int = 3

    static let postValveSettleMinSec: TimeInterval = 0
    static let postValveSettleMaxSec: TimeInterval = 3.0

    static let keepaliveIntervalMinSec: TimeInterval = 10.0
    static let keepaliveIntervalMaxSec: TimeInterval = 55.0

    static let cachedEndpointTtlMinSec: TimeInterval = 60
    static let cachedEndpointTtlMaxSec: TimeInterval = 600
}
