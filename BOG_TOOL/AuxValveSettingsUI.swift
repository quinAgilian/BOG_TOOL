import SwiftUI

// MARK: - 底部状态条

struct AuxValveStatusFooter: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var auxValveSettings: AuxValveSettings

    private var statusColor: Color {
        guard auxValveSettings.enabled else {
            return Color.secondary
        }
        if let latency = auxValveSettings.lastHealthLatencyMs, auxValveSettings.isAuxValveReachable {
            if latency <= auxValveSettings.latencyGreenMaxMs {
                return Color.green
            }
            if latency <= auxValveSettings.latencyYellowMaxMs {
                return Color.yellow
            }
            return Color.yellow
        }
        if !auxValveSettings.isAuxValveReachable {
            return Color.red
        }
        return Color.secondary
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(appLanguage.string("aux_valve.footer_label"))
                .font(UIDesignSystem.Typography.monospacedCaption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            Circle()
                .fill(auxValveSettings.enabled ? statusColor : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            if !auxValveSettings.enabled {
                Text(appLanguage.string("aux_valve.footer_disabled"))
                    .font(UIDesignSystem.Typography.monospacedCaption)
                    .foregroundStyle(Color.secondary)
            } else if auxValveSettings.isAuxValveReachable {
                let id = auxValveSettings.normalizedTargetDeviceId
                if !id.isEmpty {
                    Text("BOG-VALVE-\(id)")
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .foregroundStyle(statusColor)
                }
                if let latency = auxValveSettings.lastHealthLatencyMs {
                    Text("·")
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .foregroundStyle(statusColor)
                    Text(String(format: appLanguage.string("aux_valve.footer_latency"), Int(latency.rounded())))
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .foregroundStyle(statusColor)
                }
            } else {
                Text(appLanguage.string("aux_valve.footer_offline"))
                    .font(UIDesignSystem.Typography.monospacedCaption)
                    .foregroundStyle(.red)
            }
        }
        .onTapGesture {
            auxValveSettings.showAuxValveSettingsSheet = true
        }
        .help(appLanguage.string("aux_valve.footer_hint"))
    }
}

// MARK: - 设置 Sheet

struct AuxValveSettingsView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var auxValveSettings: AuxValveSettings
    @Environment(\.dismiss) private var dismiss

    @State private var showAdvanced = false
    @State private var discovered: [AuxValveDiscoveredService] = []
    @State private var isScanning = false
    @State private var testMessage: String?
    @State private var testInProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xxl) {
            HStack {
                Text(appLanguage.string("aux_valve.settings_title"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(appLanguage.string("firmware_manager.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Toggle(isOn: $auxValveSettings.enabled) {
                Text(appLanguage.string("aux_valve.enabled_toggle"))
                    .font(UIDesignSystem.Typography.body)
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
                Text(appLanguage.string("aux_valve.device_id_label"))
                    .font(UIDesignSystem.Typography.subsectionTitle)
                HStack {
                    TextField(appLanguage.string("aux_valve.device_id_placeholder"), text: $auxValveSettings.targetDeviceId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Button(appLanguage.string("aux_valve.scan_button")) {
                        scanDevices()
                    }
                    .disabled(isScanning)
                }
                if isScanning {
                    Text(appLanguage.string("aux_valve.scanning"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
                if !discovered.isEmpty {
                    ForEach(discovered) { item in
                        Button {
                            auxValveSettings.targetDeviceId = item.deviceId
                        } label: {
                            Text("\(item.serviceName) — \(item.host):\(item.port)")
                                .font(UIDesignSystem.Typography.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
                Text(appLanguage.string("aux_valve.token_label"))
                    .font(UIDesignSystem.Typography.subsectionTitle)
                SecureField(appLanguage.string("aux_valve.token_placeholder"), text: $auxValveSettings.token)
                    .textFieldStyle(.roundedBorder)
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                advancedSettingsGrid
            } label: {
                Text(appLanguage.string("aux_valve.advanced_section"))
                    .font(UIDesignSystem.Typography.subsectionTitle)
            }

            HStack(spacing: UIDesignSystem.Spacing.md) {
                Button(appLanguage.string("aux_valve.test_open")) {
                    runValveTest(action: "open")
                }
                .disabled(testInProgress || !auxValveSettings.enabled)
                Button(appLanguage.string("aux_valve.test_close")) {
                    runValveTest(action: "close")
                }
                .disabled(testInProgress || !auxValveSettings.enabled)
            }

            footerStatusSection

            if let testMessage {
                Text(testMessage)
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
            }
        }
        .padding(UIDesignSystem.Padding.xxl)
        .frame(minWidth: 420, minHeight: 360)
        .onAppear {
            auxValveSettings.triggerHealthCheck()
        }
    }

    private var advancedSettingsGrid: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            intervalRow("aux_valve.discover_timeout", value: $auxValveSettings.discoverTimeoutSec)
            intervalRow("aux_valve.probe_timeout", value: $auxValveSettings.probeTimeoutSec)
            intervalRow("aux_valve.http_timeout", value: $auxValveSettings.httpTimeoutSec)
            intervalRow("aux_valve.operation_budget", value: $auxValveSettings.operationBudgetSec)
            intRow("aux_valve.moving_poll_interval_ms", value: $auxValveSettings.movingPollIntervalMs)
            intervalRow("aux_valve.moving_poll_max", value: $auxValveSettings.movingPollMaxSec)
            intervalRow("aux_valve.health_interval", value: $auxValveSettings.healthCheckIntervalSec)
            intervalRow("aux_valve.health_timeout", value: $auxValveSettings.healthHttpTimeoutSec)
            doubleRow("aux_valve.latency_green", value: $auxValveSettings.latencyGreenMaxMs)
            doubleRow("aux_valve.latency_yellow", value: $auxValveSettings.latencyYellowMaxMs)
            intRow("aux_valve.retry_count", value: $auxValveSettings.orchestrationRetryCount)
            intervalRow("aux_valve.post_settle", value: $auxValveSettings.postValveSettleSec)
            Toggle(isOn: $auxValveSettings.keepaliveEnabled) {
                Text(appLanguage.string("aux_valve.keepalive_enabled"))
            }
            intervalRow("aux_valve.keepalive_interval", value: $auxValveSettings.keepaliveIntervalSec)
            intervalRow("aux_valve.cache_ttl", value: $auxValveSettings.cachedEndpointTtlSec)
        }
        .padding(.top, UIDesignSystem.Spacing.sm)
    }

    private var footerStatusSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
            Divider()
            Text(appLanguage.string("aux_valve.status_footer_title"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            if auxValveSettings.enabled {
                if let valve = auxValveSettings.lastStatusValve {
                    Text(String(format: appLanguage.string("aux_valve.status_valve"), valve, auxValveSettings.lastStatusMoving ? "yes" : "no"))
                        .font(UIDesignSystem.Typography.monospacedCaption)
                }
                if let latency = auxValveSettings.lastHealthLatencyMs {
                    Text(String(format: appLanguage.string("aux_valve.status_latency"), Int(latency.rounded())))
                        .font(UIDesignSystem.Typography.monospacedCaption)
                }
                if let err = auxValveSettings.lastHealthError {
                    Text(err)
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(.red)
                }
            } else {
                Text(appLanguage.string("aux_valve.footer_disabled"))
                    .font(UIDesignSystem.Typography.caption)
            }
        }
    }

    private func intervalRow(_ key: String, value: Binding<TimeInterval>) -> some View {
        HStack {
            Text(appLanguage.string(key))
                .frame(width: 220, alignment: .leading)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
        }
        .font(UIDesignSystem.Typography.caption)
    }

    private func doubleRow(_ key: String, value: Binding<Double>) -> some View {
        HStack {
            Text(appLanguage.string(key))
                .frame(width: 220, alignment: .leading)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
        }
        .font(UIDesignSystem.Typography.caption)
    }

    private func intRow(_ key: String, value: Binding<Int>) -> some View {
        HStack {
            Text(appLanguage.string(key))
                .frame(width: 220, alignment: .leading)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
        }
        .font(UIDesignSystem.Typography.caption)
    }

    private func scanDevices() {
        isScanning = true
        discovered = []
        Task {
            let list = await auxValveSettings.wifiClient.discoverServices(timeout: auxValveSettings.discoverTimeoutSec, settings: auxValveSettings)
            await MainActor.run {
                discovered = list
                isScanning = false
            }
        }
    }

    private func runValveTest(action: String) {
        testInProgress = true
        testMessage = nil
        auxValveSettings.auxLog("manual test \(action) from settings sheet")
        Task {
            do {
                let endpoint = try await auxValveSettings.wifiClient.resolveTargetDevice(settings: auxValveSettings, budgetDeadline: nil)
                let result = try await auxValveSettings.wifiClient.postValve(
                    action: action,
                    host: endpoint.host,
                    port: endpoint.port,
                    settings: auxValveSettings,
                    timeout: auxValveSettings.httpTimeoutSec
                )
                await MainActor.run {
                    if result.ok {
                        testMessage = String(
                            format: appLanguage.string("aux_valve.test_ok"),
                            result.valve ?? "—",
                            result.elapsedMs ?? 0
                        )
                    } else {
                        testMessage = result.errorCode ?? appLanguage.string("aux_valve.test_failed")
                    }
                    testInProgress = false
                    auxValveSettings.triggerHealthCheck()
                }
            } catch {
                await MainActor.run {
                    testMessage = error.localizedDescription
                    testInProgress = false
                }
            }
        }
    }
}
