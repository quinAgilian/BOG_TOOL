import Foundation

enum AuxValveOperationOutcome: Equatable {
    case success(valve: String, elapsedMs: Int?)
    case skipped
    case failed(reason: String, elapsedSec: TimeInterval)
}

/// 产测编排：发现 → 校验 device_id → open/close（受 operationBudgetSec 约束）
final class AuxValveCoordinator {
    private let client: AuxValveWiFiClient
    private let settings: AuxValveSettings

    init(settings: AuxValveSettings, client: AuxValveWiFiClient? = nil) {
        self.settings = settings
        self.client = client ?? settings.wifiClient
    }

    func ensureLineValveOpen() async -> AuxValveOperationOutcome {
        await ensureValve(action: "open", expectedState: "open")
    }

    func ensureLineValveClose() async -> AuxValveOperationOutcome {
        await ensureValve(action: "close", expectedState: "closed")
    }

    private func ensureValve(action: String, expectedState: String) async -> AuxValveOperationOutcome {
        guard settings.enabled, !settings.useManualValveForCurrentRun else {
            settings.auxLog("orchestration \(action) skipped: enabled=\(settings.enabled) manual=\(settings.useManualValveForCurrentRun)")
            return .skipped
        }
        guard !settings.normalizedTargetDeviceId.isEmpty else {
            return .failed(reason: AuxValveClientError.notConfigured.userFacingToken, elapsedSec: 0)
        }

        let budgetStart = Date()
        let budgetDeadline = budgetStart.addingTimeInterval(settings.operationBudgetSec)
        settings.auxLog("orchestration \(action) start budget=\(settings.operationBudgetSec)s")

        do {
            let endpoint = try await client.resolveTargetDevice(settings: settings, budgetDeadline: budgetDeadline)
            let status = try await client.getStatus(
                host: endpoint.host,
                port: endpoint.port,
                settings: settings,
                timeout: settings.httpTimeoutSec
            )
            try validateStatus(status)

            if status.ok, status.valve == expectedState, status.moving != true {
                let elapsed = Date().timeIntervalSince(budgetStart)
                return .success(valve: expectedState, elapsedMs: nil)
            }

            let postResult = try await client.postValve(
                action: action,
                host: endpoint.host,
                port: endpoint.port,
                settings: settings,
                timeout: settings.httpTimeoutSec
            )
            try validateValvePost(postResult)

            if postResult.valve != expectedState || postResult.moving == true {
                try await client.pollUntilValveState(
                    expectedState,
                    host: endpoint.host,
                    port: endpoint.port,
                    settings: settings,
                    budgetDeadline: budgetDeadline
                )
            }

            let elapsed = Date().timeIntervalSince(budgetStart)
            settings.auxLog("orchestration \(action) success \(String(format: "%.2f", elapsed))s")
            return .success(valve: expectedState, elapsedMs: postResult.elapsedMs)
        } catch {
            let elapsed = Date().timeIntervalSince(budgetStart)
            settings.auxLog("orchestration \(action) failed: \(error.localizedDescription)", level: .warning)
            return .failed(reason: AuxValveUserMessage.from(error), elapsedSec: elapsed)
        }
    }

    private func validateStatus(_ response: AuxValveHTTPResponse) throws {
        if response.httpStatus == 401 { throw AuxValveClientError.unauthorized }
        if response.errorCode == "wrong_device" { throw AuxValveClientError.wrongDevice }
        if response.deviceId?.uppercased() != settings.normalizedTargetDeviceId {
            throw AuxValveClientError.wrongDevice
        }
        guard response.ok else {
            throw AuxValveClientError.httpError(response.httpStatus, response.errorCode)
        }
    }

    private func validateValvePost(_ response: AuxValveHTTPResponse) throws {
        if response.httpStatus == 401 { throw AuxValveClientError.unauthorized }
        if response.httpStatus == 409, response.errorCode == "wrong_device" { throw AuxValveClientError.wrongDevice }
        guard response.ok else {
            throw AuxValveClientError.httpError(response.httpStatus, response.errorCode)
        }
        if response.deviceId?.uppercased() != settings.normalizedTargetDeviceId {
            throw AuxValveClientError.wrongDevice
        }
    }
}
