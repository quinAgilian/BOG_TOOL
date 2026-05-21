import Foundation

/// 产测 WiFi 气阀编排结果（§4.3 / §4.9）
enum AuxValveProductionWifiResult: Equatable {
    /// 未启用 / 本台改手动 / 无 device_id：走纯人工确认
    case useManualConfirm
    /// WiFi 到位，跳过工序确认弹窗
    case wifiSucceeded
    /// WiFi 失败或用户 Alert 后改手动：须走人工确认弹窗
    case wifiFailedUseManualConfirm(reason: String)
}

/// 产测 §4.9.3 失败 Alert 用户选择
enum AuxValveFailureAlertChoice {
    case useManualThisRun
    case retry
    case disableAutomation
}

/// 产测与 `auto-valve-wifi-system.md` 对齐的编排辅助（不碰 BLE）
enum AuxValveProductionBridge {

    /// §4.2 / §4.9.1：是否可能走 WiFi（不含健康可达性）
    static func shouldAttemptWifi(settings: AuxValveSettings) -> Bool {
        settings.enabled
            && !settings.useManualValveForCurrentRun
            && !settings.normalizedTargetDeviceId.isEmpty
    }

    /// §4.10.1：规则页 / 底栏联动用
    static func automationMode(settings: AuxValveSettings) -> AuxValveAutomationMode {
        if !settings.enabled { return .manualGlobalOff }
        if settings.canUseAuxValveAutomation { return .wifiAutomatic }
        return .enabledButUnreachable
    }

    static func ensureLineValveOpen(
        settings: AuxValveSettings,
        coordinator: AuxValveCoordinator,
        presentFailureAlert: @escaping (_ reason: String, _ elapsedSec: TimeInterval) async -> AuxValveFailureAlertChoice
    ) async -> AuxValveProductionWifiResult {
        await ensureValve(
            action: "open",
            expectedState: "open",
            settings: settings,
            coordinator: coordinator,
            presentFailureAlert: presentFailureAlert
        )
    }

    static func ensureLineValveClose(
        settings: AuxValveSettings,
        coordinator: AuxValveCoordinator,
        presentFailureAlert: @escaping (_ reason: String, _ elapsedSec: TimeInterval) async -> AuxValveFailureAlertChoice
    ) async -> AuxValveProductionWifiResult {
        await ensureValve(
            action: "close",
            expectedState: "closed",
            settings: settings,
            coordinator: coordinator,
            presentFailureAlert: presentFailureAlert
        )
    }

    private static func ensureValve(
        action: String,
        expectedState: String,
        settings: AuxValveSettings,
        coordinator: AuxValveCoordinator,
        presentFailureAlert: @escaping (_ reason: String, _ elapsedSec: TimeInterval) async -> AuxValveFailureAlertChoice
    ) async -> AuxValveProductionWifiResult {
        guard shouldAttemptWifi(settings: settings) else {
            return .useManualConfirm
        }

        // 产测编排以本次 HTTP 为准，不依赖底栏周期 health（避免 footer 离线但 LAN 仍可达时误弹关阀窗）
        return await runOrchestrationWithRetries(
            action: action,
            settings: settings,
            coordinator: coordinator,
            presentFailureAlert: presentFailureAlert
        )
    }

    private static func runOrchestrationWithRetries(
        action: String,
        settings: AuxValveSettings,
        coordinator: AuxValveCoordinator,
        presentFailureAlert: @escaping (_ reason: String, _ elapsedSec: TimeInterval) async -> AuxValveFailureAlertChoice
    ) async -> AuxValveProductionWifiResult {
        var retriesLeft = settings.orchestrationRetryCount
        while true {
            let outcome: AuxValveOperationOutcome
            if action == "open" {
                outcome = await coordinator.ensureLineValveOpen()
            } else {
                outcome = await coordinator.ensureLineValveClose()
            }

            switch outcome {
            case .success:
                let settle = max(0, settings.postValveSettleSec)
                if settle > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
                }
                return .wifiSucceeded
            case .skipped:
                return .useManualConfirm
            case .failed(let reason, let elapsedSec):
                let choice = await presentFailureAlert(reason, elapsedSec)
                applyFailureChoice(choice, settings: settings)
                switch choice {
                case .retry:
                    if retriesLeft > 0 {
                        retriesLeft -= 1
                        continue
                    }
                    return .wifiFailedUseManualConfirm(reason: reason)
                case .useManualThisRun, .disableAutomation:
                    return .wifiFailedUseManualConfirm(reason: reason)
                }
            }
        }
    }

    private static func applyFailureChoice(_ choice: AuxValveFailureAlertChoice, settings: AuxValveSettings) {
        switch choice {
        case .useManualThisRun:
            settings.useManualValveForCurrentRun = true
        case .disableAutomation:
            settings.enabled = false
        case .retry:
            break
        }
    }
}

enum AuxValveAutomationMode {
    case manualGlobalOff
    case enabledButUnreachable
    case wifiAutomatic
}
