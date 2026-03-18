import Foundation

/// 产测规则顶层结构，与 `rules/default_production_rules.json` 对应
struct ProductionRules: Codable, Equatable {
    struct Meta: Codable, Equatable {
        var projectName: String
        var author: String
        var createdAt: String
        var updatedAt: String
        var notes: String

        enum CodingKeys: String, CodingKey {
            case projectName = "project_name"
            case author
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case notes
        }
    }

    struct Global: Codable, Equatable {
        struct FailurePolicy: Codable, Equatable {
            var fatalDefault: [String]
            var overrides: [String: Bool]

            enum CodingKeys: String, CodingKey {
                case fatalDefault = "fatal_default"
                case overrides
            }
        }

        var stepIntervalMs: Int
        var skipFactoryResetAndDisconnectOnFail: Bool
        var failurePolicy: FailurePolicy

        enum CodingKeys: String, CodingKey {
            case stepIntervalMs = "step_interval_ms"
            case skipFactoryResetAndDisconnectOnFail = "skip_factory_reset_and_disconnect_on_fail"
            case failurePolicy = "failure_policy"
        }
    }

    struct Environment: Codable, Equatable {
        struct BleScan: Codable, Equatable {
            var rssiFilterEnabled: Bool
            var minRssiDbm: Int
            var nameWhitelistEnabled: Bool
            var nameWhitelistKeywords: [String]
            var nameBlacklistKeywords: [String]

            enum CodingKeys: String, CodingKey {
                case rssiFilterEnabled = "rssi_filter_enabled"
                case minRssiDbm = "min_rssi_dbm"
                case nameWhitelistEnabled = "name_whitelist_enabled"
                case nameWhitelistKeywords = "name_whitelist_keywords"
                case nameBlacklistKeywords = "name_blacklist_keywords"
            }
        }

        var bleScan: BleScan

        enum CodingKeys: String, CodingKey {
            case bleScan = "ble_scan"
        }
    }

    struct Step: Codable, Equatable {
        struct Config: Codable, Equatable {
            // step_connect
            var bluetoothPermissionWaitSeconds: Double?

            // step_verify_firmware
            var allowedBootloaderVersions: [String]?
            var allowedFirmwareVersions: [String]?
            var allowedHardwareVersions: [String]?
            var firmwareUpgradeEnabled: Bool?

            // step_read_rtc
            var passThresholdSeconds: Double?
            var failThresholdSeconds: Double?
            var writeEnabled: Bool?
            var writeRetryCount: Int?
            var readTimeoutSeconds: Double?

            // step_read_pressure
            var closedMinMbar: Double?
            var closedMaxMbar: Double?
            var openMinMbar: Double?
            var openMaxMbar: Double?
            var diffCheckEnabled: Bool?
            var diffMinMbar: Double?
            var diffMaxMbar: Double?
            var failRetryConfirmEnabled: Bool?

            // step_disable_diag
            var waitSeconds: Double?
            var expectedGasStatusValues: [Int]?
            var pollTimeoutSeconds: Double?
            var pollEnabled: Bool?
            /// Disable diag 后是否执行阀门开/关检查并记录压力（仅观测，不参与阀值判定）
            var valveCheckEnabled: Bool?
            /// 阀门开/关命令后等待稳定的秒数（默认 0.5）
            var valveCheckSettleSeconds: Double?
            /// 触发读压后等待回读的秒数（默认 0.6）
            var valveCheckPressureReadDelaySeconds: Double?

            // step_gas_leak_closed
            var preCloseDurationSeconds: Int?
            var postCloseDurationSeconds: Int?
            var intervalSeconds: Double?
            var dropThresholdMbar: Double?
            var startPressureMinMbar: Double?
            var requirePipelineReadyConfirm: Bool?
            var requireValveClosedConfirm: Bool?
            var limitSource: String?
            var limitFloorBar: Double?
            var phase4Enabled: Bool?
            var phase4MonitorDurationSeconds: Int?
            var phase4DropWithinSeconds: Int?
            var phase4PressureBelowMbar: Double?
            var skipClosedWhenOpenPasses: Bool?

            // step_valve
            var openTimeoutSeconds: Double?

            enum CodingKeys: String, CodingKey {
                case bluetoothPermissionWaitSeconds = "bluetooth_permission_wait_seconds"

                case allowedBootloaderVersions = "allowed_bootloader_versions"
                case allowedFirmwareVersions = "allowed_firmware_versions"
                case allowedHardwareVersions = "allowed_hardware_versions"
                case firmwareUpgradeEnabled = "firmware_upgrade_enabled"

                case passThresholdSeconds = "pass_threshold_seconds"
                case failThresholdSeconds = "fail_threshold_seconds"
                case writeEnabled = "write_enabled"
                case writeRetryCount = "write_retry_count"
                case readTimeoutSeconds = "read_timeout_seconds"

                case closedMinMbar = "closed_min_mbar"
                case closedMaxMbar = "closed_max_mbar"
                case openMinMbar = "open_min_mbar"
                case openMaxMbar = "open_max_mbar"
                case diffCheckEnabled = "diff_check_enabled"
                case diffMinMbar = "diff_min_mbar"
                case diffMaxMbar = "diff_max_mbar"
                case failRetryConfirmEnabled = "fail_retry_confirm_enabled"

                case waitSeconds = "wait_seconds"
                case expectedGasStatusValues = "expected_gas_status_values"
                case pollTimeoutSeconds = "poll_timeout_seconds"
                case pollEnabled = "poll_enabled"
                case valveCheckEnabled = "valve_check_enabled"
                case valveCheckSettleSeconds = "valve_check_settle_seconds"
                case valveCheckPressureReadDelaySeconds = "valve_check_pressure_read_delay_seconds"

                case preCloseDurationSeconds = "pre_close_duration_seconds"
                case postCloseDurationSeconds = "post_close_duration_seconds"
                case intervalSeconds = "interval_seconds"
                case dropThresholdMbar = "drop_threshold_mbar"
                case startPressureMinMbar = "start_pressure_min_mbar"
                case requirePipelineReadyConfirm = "require_pipeline_ready_confirm"
                case requireValveClosedConfirm = "require_valve_closed_confirm"
                case limitSource = "limit_source"
                case limitFloorBar = "limit_floor_bar"
                case phase4Enabled = "phase4_enabled"
                case phase4MonitorDurationSeconds = "phase4_monitor_duration_seconds"
                case phase4DropWithinSeconds = "phase4_drop_within_seconds"
                case phase4PressureBelowMbar = "phase4_pressure_below_mbar"
                case skipClosedWhenOpenPasses = "skip_closed_when_open_passes"

                case openTimeoutSeconds = "open_timeout_seconds"
            }
        }

        var id: String
        var enabled: Bool
        var order: Int
        /// nil 表示沿用 global.failurePolicy
        var fatalOnFailure: Bool?
        var config: Config

        enum CodingKeys: String, CodingKey {
            case id
            case enabled
            case order
            case fatalOnFailure = "fatal_on_failure"
            case config
        }
    }

    var schemaVersion: Int
    var rulesVersion: String
    var meta: Meta
    var global: Global
    var environment: Environment
    var steps: [Step]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case rulesVersion = "rules_version"
        case meta
        case global
        case environment
        case steps
    }
}

