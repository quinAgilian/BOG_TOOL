import SwiftUI

// MARK: - 底部状态条

struct AuxValveStatusFooter: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var auxValveSettings: AuxValveSettings

    private var statusColor: Color {
        guard auxValveSettings.enabled else {
            return Color.secondary
        }
        if auxValveSettings.deviceBindingMismatch != .none {
            return Color.orange
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

    private var auxValveStatusTextColor: Color {
        if !auxValveSettings.enabled { return Color.secondary }
        if !auxValveSettings.isAuxValveReachable { return .red }
        if auxValveSettings.deviceBindingMismatch != .none { return .orange }
        return statusColor
    }

    /// 底栏单行：阀 · A1B2 · 45ms；绑定漂移时优先提示
    private var statusLine: String {
        guard auxValveSettings.enabled else {
            return appLanguage.string("aux_valve.footer_disabled")
        }
        guard auxValveSettings.isAuxValveReachable else {
            return appLanguage.string("aux_valve.footer_offline")
        }
        switch auxValveSettings.deviceBindingMismatch {
        case .deviceUnbound:
            if auxValveSettings.isPhysicalUnbindOnDevice {
                return appLanguage.string("aux_valve.footer_mismatch_physical")
            }
            return appLanguage.string("aux_valve.footer_mismatch_unbound")
        case .boundToOtherStation:
            return appLanguage.string("aux_valve.footer_mismatch_other")
        case .none:
            break
        }
        var parts: [String] = []
        let id = auxValveSettings.normalizedTargetDeviceId
        if !id.isEmpty { parts.append(id) }
        if let valveKey = footerValveStateKey {
            parts.append(appLanguage.string(valveKey))
        }
        if let latency = auxValveSettings.lastHealthLatencyMs {
            parts.append("\(Int(latency.rounded()))ms")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: "·")
    }

    private var footerValveStateKey: String? {
        if auxValveSettings.lastStatusMoving {
            return "aux_valve.footer_valve_moving"
        }
        switch auxValveSettings.lastStatusValve {
        case "open":
            return "aux_valve.footer_valve_open"
        case "closed":
            return "aux_valve.footer_valve_closed"
        case "moving":
            return "aux_valve.footer_valve_moving"
        default:
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(appLanguage.string("aux_valve.footer_label"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            Circle()
                .fill(auxValveSettings.enabled ? statusColor : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(statusLine)
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(auxValveStatusTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .layoutPriority(0)
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
    @State private var didCompleteScan = false
    @State private var selectedDeviceId: String?
    @State private var testMessage: String?
    @State private var testInProgress = false
    @State private var isUnbinding = false
    @State private var isBinding = false
    @State private var pairingWaitMessage: String?
    @State private var didAutoScanThisSession = false

    /// 本机已绑定 device_id（与阀是否在线无关）
    private var hasLocalBinding: Bool {
        !auxValveSettings.normalizedTargetDeviceId.isEmpty
    }

    private var canRunValveTest: Bool {
        hasLocalBinding && auxValveSettings.canRunManualValveTest && !testInProgress
    }

    private var valveTestDisabledReasonKey: String? {
        if testInProgress { return nil }
        if !hasLocalBinding { return nil }
        if !auxValveSettings.enabled {
            return "aux_valve.test_disabled_not_enabled"
        }
        if !auxValveSettings.isAuxValveReachable {
            return "aux_valve.test_disabled_offline"
        }
        if auxValveSettings.lastStatusMoving {
            return "aux_valve.test_disabled_moving"
        }
        switch auxValveSettings.deviceBindingMismatch {
        case .boundToOtherStation:
            return "aux_valve.error.wrong_client"
        case .deviceUnbound:
            return "aux_valve.test_disabled_not_bound_on_device"
        case .none:
            break
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xxl) {
                headerRow
                Toggle(isOn: $auxValveSettings.enabled) {
                    Text(appLanguage.string("aux_valve.enabled_toggle"))
                        .font(UIDesignSystem.Typography.body)
                }
                .toggleStyle(.switch)

                deviceBindingSection

                ledIndicatorSection

                DisclosureGroup(isExpanded: $showAdvanced) {
                    advancedSettingsGrid
                } label: {
                    Text(appLanguage.string("aux_valve.advanced_section"))
                        .font(UIDesignSystem.Typography.subsectionTitle)
                }

                if hasLocalBinding {
                    valveTestSection
                }

                footerStatusSection

                if let testMessage {
                    Text(testMessage)
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(testMessageIsError ? Color.red : UIDesignSystem.Foreground.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(UIDesignSystem.Padding.xxl)
        }
        .frame(minWidth: 440, minHeight: 420)
        .onAppear {
            syncSelectionFromSettings()
            clearScanSession()
            auxValveSettings.triggerHealthCheck()
            if !hasLocalBinding, !didAutoScanThisSession {
                didAutoScanThisSession = true
                scanDevices()
            }
        }
        .onDisappear {
            didAutoScanThisSession = false
        }
        .onChange(of: auxValveSettings.targetDeviceId) { _ in
            syncSelectionFromSettings()
            if hasLocalBinding {
                clearScanSession()
            } else if !didAutoScanThisSession, !isScanning {
                didAutoScanThisSession = true
                scanDevices()
            }
        }
    }

    private func clearScanSession() {
        discovered = []
        didCompleteScan = false
        isScanning = false
        if !hasLocalBinding {
            selectedDeviceId = nil
        }
    }

    private var headerRow: some View {
        HStack {
            Text(appLanguage.string("aux_valve.settings_title"))
                .font(.title2.weight(.semibold))
            Spacer()
            Button(appLanguage.string("firmware_manager.close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var deviceBindingSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.md) {
            Text(appLanguage.string(hasLocalBinding ? "aux_valve.binding_section_bound" : "aux_valve.binding_section_title"))
                .font(UIDesignSystem.Typography.subsectionTitle)

            valveButtonGuideSection

            if hasLocalBinding {
                boundDevicePanel
            } else {
                unboundDevicePanel
            }
        }
    }

    private var boundDevicePanel: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            currentBindingRow
            Text(appLanguage.string("aux_valve.bind_change_hint"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var valveTestSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            Text(appLanguage.string("aux_valve.test_section_title"))
                .font(UIDesignSystem.Typography.subsectionTitle)
            HStack(spacing: UIDesignSystem.Spacing.md) {
                Button(appLanguage.string("aux_valve.test_open")) {
                    runValveTest(action: "open")
                }
                .disabled(!canRunValveTest)
                Button(appLanguage.string("aux_valve.test_close")) {
                    runValveTest(action: "close")
                }
                .disabled(!canRunValveTest)
                if testInProgress {
                    ProgressView().controlSize(.small)
                }
            }
            if let key = valveTestDisabledReasonKey {
                Text(appLanguage.string(key))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unboundDevicePanel: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.md) {
            pairingReminderBanner

            HStack(spacing: UIDesignSystem.Spacing.sm) {
                Button(appLanguage.string("aux_valve.scan_button")) {
                    scanDevices()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isScanning)
                if isScanning {
                    ProgressView().controlSize(.small)
                    Text(appLanguage.string("aux_valve.scanning"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
            }

            if !discovered.isEmpty {
                Text(appLanguage.string("aux_valve.scan_results_hint"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                discoveredDeviceList
                Button(appLanguage.string("aux_valve.use_selected")) {
                    applySelectedDevice()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedDeviceId == nil || isScanning || isBinding)
                if isBinding {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appLanguage.string("aux_valve.binding_in_progress"))
                        if let pairingWaitMessage {
                            Text(pairingWaitMessage)
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else if isScanning {
                    Text(appLanguage.string("aux_valve.bind_wait_scan"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                } else if selectedDeviceId == nil {
                    Text(appLanguage.string("aux_valve.bind_select_first"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
            } else if didCompleteScan && !isScanning {
                emptyScanReminder
            }
        }
    }

    private var currentBindingRow: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.sm) {
            if let bannerKey = bindingMismatchBannerKey {
                Text(appLanguage.string(bannerKey))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLanguage.string("aux_valve.current_binding_label"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text(AuxValveProtocol.deviceName(for: auxValveSettings.normalizedTargetDeviceId))
                        .font(UIDesignSystem.Typography.body.weight(.semibold))
                    Text(bindingFirmwareVersionLine)
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    bindingReachabilityBadge
                }
                Spacer()
                Button(appLanguage.string("aux_valve.unbind")) {
                    unbindDevice()
                }
                .buttonStyle(.bordered)
                .disabled(isUnbinding)
            }
            if isUnbinding {
                HStack(spacing: UIDesignSystem.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(appLanguage.string("aux_valve.unbind_in_progress"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
            }
        }
        .padding(UIDesignSystem.Padding.sm)
        .background(bindingPanelBackground)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
    }

    private var bindingFirmwareVersionLine: String {
        let label = appLanguage.string("aux_valve.firmware_version_label")
        if let fw = auxValveSettings.lastFirmwareVersionOnDevice, !fw.isEmpty {
            return "\(label) \(fw)"
        }
        if auxValveSettings.isAuxValveReachable {
            return "\(label) \(appLanguage.string("aux_valve.firmware_version_unknown"))"
        }
        return "\(label) \(appLanguage.string("aux_valve.firmware_version_offline"))"
    }

    private var bindingMismatchBannerKey: String? {
        switch auxValveSettings.deviceBindingMismatch {
        case .deviceUnbound:
            if auxValveSettings.isPhysicalUnbindOnDevice {
                return "aux_valve.binding_mismatch_banner_physical"
            }
            return "aux_valve.binding_mismatch_banner_unbound"
        case .boundToOtherStation:
            return "aux_valve.binding_mismatch_banner_other"
        case .none:
            return nil
        }
    }

    private var bindingPanelBackground: Color {
        switch auxValveSettings.deviceBindingMismatch {
        case .none:
            return Color.green.opacity(0.06)
        case .deviceUnbound, .boundToOtherStation:
            return Color.orange.opacity(0.10)
        }
    }

    @ViewBuilder
    private var bindingReachabilityBadge: some View {
        if !auxValveSettings.enabled {
            Text(appLanguage.string("aux_valve.binding_status_disabled"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        } else if !auxValveSettings.isAuxValveReachable {
            Text(appLanguage.string("aux_valve.binding_status_offline"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(.orange)
        } else if auxValveSettings.isWorkstationAuthorizedOnDevice {
            Text(appLanguage.string("aux_valve.binding_status_online_synced"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(.green)
        } else if auxValveSettings.deviceBindingMismatch == .deviceUnbound {
            Text(
                appLanguage.string(
                    auxValveSettings.isPhysicalUnbindOnDevice
                        ? "aux_valve.binding_status_online_mismatch_physical"
                        : "aux_valve.binding_status_online_mismatch_unbound"
                )
            )
            .font(UIDesignSystem.Typography.caption)
            .foregroundStyle(.orange)
        } else {
            Text(appLanguage.string("aux_valve.binding_status_online_mismatch_other"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(.orange)
        }
    }

    private var valveButtonGuideSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
            Text(appLanguage.string("aux_valve.button_ops_title"))
                .font(UIDesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            buttonGuideRow(key: "aux_valve.button_op_short")
            buttonGuideRow(key: "aux_valve.button_op_bind_3s")
            buttonGuideRow(key: "aux_valve.button_op_wifi_10s")
            buttonGuideRow(key: "aux_valve.button_op_factory_30s")
        }
        .padding(UIDesignSystem.Padding.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(UIDesignSystem.CornerRadius.md)
    }

    private func buttonGuideRow(key: String) -> some View {
        HStack(alignment: .top, spacing: UIDesignSystem.Spacing.sm) {
            Text("•")
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            Text(appLanguage.string(key))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pairingReminderBanner: some View {
        Label(appLanguage.string("aux_valve.pairing_banner_compact"), systemImage: "hand.tap.fill")
            .font(UIDesignSystem.Typography.caption)
            .foregroundStyle(.orange)
            .padding(UIDesignSystem.Padding.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(UIDesignSystem.CornerRadius.md)
    }

    private var emptyScanReminder: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
            Text(appLanguage.string("aux_valve.scan_empty_title"))
                .font(UIDesignSystem.Typography.caption.weight(.semibold))
            Text(appLanguage.string("aux_valve.scan_empty_steps"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UIDesignSystem.Padding.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(UIDesignSystem.CornerRadius.md)
    }

    private var discoveredDeviceList: some View {
        VStack(spacing: 0) {
            ForEach(discovered) { item in
                discoveredDeviceRow(item)
                if item.id != discovered.last?.id {
                    Divider()
                }
            }
        }
        .background(UIDesignSystem.Background.light)
        .cornerRadius(UIDesignSystem.CornerRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: UIDesignSystem.CornerRadius.md)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func scanRowFirmwareLine(for item: AuxValveDiscoveredService) -> String {
        let label = appLanguage.string("aux_valve.firmware_version_label")
        if let fw = item.firmwareVersion, !fw.isEmpty {
            return "\(label) \(fw)"
        }
        if isScanning {
            return "\(label) …"
        }
        return "\(label) \(appLanguage.string("aux_valve.firmware_version_unknown"))"
    }

    private func discoveredDeviceRow(_ item: AuxValveDiscoveredService) -> some View {
        let isSelected = selectedDeviceId == item.deviceId
        return Button {
            selectedDeviceId = item.deviceId
            applySelectedDevice()
        } label: {
            HStack(spacing: UIDesignSystem.Spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.serviceName)
                        .font(UIDesignSystem.Typography.body.weight(.medium))
                    Text("\(item.host):\(item.port)")
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text(scanRowFirmwareLine(for: item))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, UIDesignSystem.Padding.sm)
            .padding(.vertical, UIDesignSystem.Padding.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var ledIndicatorSection: some View {
        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
            Text(appLanguage.string("aux_valve.led_section_title"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            Text(appLanguage.string("aux_valve.led_modulation"))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            ledLegendRow(color: .red, textKey: "aux_valve.led_tier_red")
            ledLegendRow(color: .blue, textKey: "aux_valve.led_tier_blue")
            ledLegendRow(color: .white, textKey: "aux_valve.led_tier_white", stroke: true)
            ledLegendRow(color: .green, textKey: "aux_valve.led_tier_green")
        }
    }

    private func ledLegendRow(color: Color, textKey: String, stroke: Bool = false) -> some View {
        HStack(spacing: UIDesignSystem.Spacing.sm) {
            Circle()
                .fill(color)
                .overlay {
                    if stroke {
                        Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                    }
                }
                .frame(width: 7, height: 7)
            Text(appLanguage.string(textKey))
                .font(UIDesignSystem.Typography.caption)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
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
                    Text(String(
                        format: appLanguage.string("aux_valve.status_valve"),
                        valve,
                        auxValveSettings.lastStatusMoving
                            ? appLanguage.string("common.yes")
                            : appLanguage.string("common.no")
                    ))
                        .font(UIDesignSystem.Typography.monospacedCaption)
                }
                if let latency = auxValveSettings.lastHealthLatencyMs {
                    Text(String(format: appLanguage.string("aux_valve.status_latency"), Int(latency.rounded())))
                        .font(UIDesignSystem.Typography.monospacedCaption)
                }
                if let err = auxValveSettings.lastHealthError {
                    Text(AuxValveUserMessage.localize(err, language: appLanguage))
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

    private var testMessageIsError: Bool {
        guard let testMessage else { return false }
        let errors = [
            appLanguage.string("aux_valve.scan_empty_permission_hint"),
            appLanguage.string("aux_valve.bind_no_selection"),
            appLanguage.string("aux_valve.error.bind_not_armed"),
            appLanguage.string("aux_valve.error.pairing_timeout"),
        ]
        if errors.contains(testMessage) { return true }
        return testMessage.contains("HTTP") || testMessage.contains("错误") || testMessage.contains("失败")
    }

    private func scanDevices() {
        guard !hasLocalBinding else { return }
        isScanning = true
        didCompleteScan = false
        discovered = []
        testMessage = nil
        let traceWasEnabled = auxValveSettings.auxHttpTraceEnabled
        auxValveSettings.auxHttpTraceEnabled = true
        auxValveSettings.auxLog("settings sheet: manual scan started")
        Task {
            let list = await auxValveSettings.wifiClient.discoverServices(
                timeout: auxValveSettings.discoverTimeoutSec,
                settings: auxValveSettings
            )
            let sorted = list.sorted {
                $0.serviceName.localizedCaseInsensitiveCompare($1.serviceName) == .orderedAscending
            }
            await MainActor.run {
                discovered = sorted
            }
            let enriched = await auxValveSettings.wifiClient.enrichDiscoveredWithFirmwareVersions(
                sorted,
                settings: auxValveSettings
            )
            await MainActor.run {
                auxValveSettings.auxHttpTraceEnabled = traceWasEnabled
                discovered = enriched
                isScanning = false
                didCompleteScan = true
                if discovered.isEmpty {
                    testMessage = appLanguage.string("aux_valve.scan_empty_permission_hint")
                } else if selectedDeviceId == nil {
                    selectedDeviceId = discovered.first?.deviceId
                }
            }
        }
    }

    private func applySelectedDevice() {
        guard !isBinding else {
            auxValveSettings.auxLog("bind ignored: already in progress", level: .warning)
            return
        }
        guard let id = selectedDeviceId,
              let item = discovered.first(where: { $0.deviceId == id }) else {
            auxValveSettings.auxHttpTraceEnabled = true
            auxValveSettings.auxLog(
                "bind aborted: no selection (selected=\(selectedDeviceId ?? "nil") discovered=\(discovered.count) scanning=\(isScanning))",
                level: .warning
            )
            testMessage = isScanning
                ? appLanguage.string("aux_valve.bind_wait_scan")
                : appLanguage.string("aux_valve.bind_no_selection")
            return
        }
        isBinding = true
        pairingWaitMessage = nil
        testMessage = nil
        let traceWasEnabled = auxValveSettings.auxHttpTraceEnabled
        auxValveSettings.auxHttpTraceEnabled = true
        let myClientId = auxValveSettings.workstationClientId
        auxValveSettings.auxLog(
            "bind step 1/5 (pairing v2): start device=\(id) endpoint=\(item.host):\(item.port) "
            + "client_id=\(myClientId.prefix(8))… label=\(auxValveSettings.workstationLabel)",
            level: .info
        )
        Task {
            defer {
                Task { @MainActor in
                    isBinding = false
                    pairingWaitMessage = nil
                    auxValveSettings.auxHttpTraceEnabled = traceWasEnabled
                    auxValveSettings.auxLog("bind finished device=\(id)", level: .info)
                }
            }
            do {
                auxValveSettings.saveCachedEndpoint(host: item.host, port: item.port)
                auxValveSettings.auxLog("bind step 2/5: cached endpoint \(item.host):\(item.port)", level: .info)

                auxValveSettings.auxLog("bind step 3/5: GET /health …", level: .info)
                let health = try await auxValveSettings.wifiClient.getHealth(
                    host: item.host,
                    port: item.port,
                    settings: auxValveSettings,
                    timeout: auxValveSettings.httpTimeoutSec
                )
                guard health.httpStatus == 200, health.ok else {
                    auxValveSettings.auxLog(
                        "bind failed: health HTTP \(health.httpStatus) ok=\(health.ok) err=\(health.errorCode ?? "—")",
                        level: .warning
                    )
                    throw AuxValveClientError.httpError(health.httpStatus, health.errorCode)
                }
                guard health.deviceId?.uppercased() == id.uppercased() else {
                    auxValveSettings.auxLog(
                        "bind failed: device_id mismatch health=\(health.deviceId ?? "nil") expected=\(id)",
                        level: .warning
                    )
                    throw AuxValveClientError.wrongDevice
                }
                let remoteBound = health.boundClientId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                auxValveSettings.auxLog(
                    "bind health OK valve=\(health.valve ?? "—") remote_bound=\(remoteBound.isEmpty ? "none" : String(remoteBound.prefix(8)) + "…") "
                    + "bind_armed=\(health.bindArmed == true)",
                    level: .info
                )

                if remoteBound == myClientId, !remoteBound.isEmpty {
                    await MainActor.run {
                        auxValveSettings.targetDeviceId = id
                        auxValveSettings.auxLog(
                            "bind step 5/5: skipped — valve already bound to this station device=\(id)",
                            level: .info
                        )
                        auxValveSettings.triggerHealthCheck()
                        testMessage = String(format: appLanguage.string("aux_valve.bind_success_relinked"), id)
                    }
                    return
                }

                auxValveSettings.auxLog("bind step 3/5: POST /bind/request …", level: .info)
                let pairReq = try await auxValveSettings.wifiClient.postBindRequest(
                    host: item.host,
                    port: item.port,
                    settings: auxValveSettings,
                    timeout: auxValveSettings.httpTimeoutSec
                )
                guard pairReq.ok, pairReq.bindPending == true else {
                    auxValveSettings.auxLog(
                        "bind failed: POST /bind/request HTTP \(pairReq.httpStatus) err=\(pairReq.errorCode ?? "—")",
                        level: .warning
                    )
                    throw AuxValveClientError.httpError(pairReq.httpStatus, pairReq.errorCode)
                }

                await MainActor.run {
                    pairingWaitMessage = appLanguage.string("aux_valve.pairing_wait_press_valve")
                }

                let pairingDeadline = Date().addingTimeInterval(AuxValveProtocol.pairingWindowSec)
                auxValveSettings.auxLog(
                    "bind step 4/5: wait bind_armed (long-press valve ~3s within \(Int(AuxValveProtocol.pairingWindowSec))s) …",
                    level: .info
                )
                try await auxValveSettings.wifiClient.waitForBindArmed(
                    host: item.host,
                    port: item.port,
                    settings: auxValveSettings,
                    deadline: pairingDeadline
                ) { poll in
                    if poll.buttonBindReady {
                        pairingWaitMessage = appLanguage.string("aux_valve.pairing_release_now")
                    } else if poll.buttonPressed {
                        pairingWaitMessage = String(
                            format: appLanguage.string("aux_valve.pairing_hold_progress"),
                            poll.buttonHoldMs,
                            AuxValveProtocol.bindHoldMs,
                            poll.secondsLeft
                        )
                    } else {
                        pairingWaitMessage = String(
                            format: appLanguage.string("aux_valve.pairing_wait_countdown"),
                            poll.secondsLeft
                        )
                    }
                }

                auxValveSettings.auxLog("bind step 5/5: POST /bind …", level: .info)
                let bindResp = try await auxValveSettings.wifiClient.postBind(
                    host: item.host,
                    port: item.port,
                    settings: auxValveSettings,
                    timeout: auxValveSettings.httpTimeoutSec
                )
                guard bindResp.ok else {
                    auxValveSettings.auxLog(
                        "bind failed: POST /bind HTTP \(bindResp.httpStatus) err=\(bindResp.errorCode ?? "—")",
                        level: .warning
                    )
                    throw AuxValveClientError.httpError(bindResp.httpStatus, bindResp.errorCode)
                }
                await MainActor.run {
                    auxValveSettings.targetDeviceId = id
                    auxValveSettings.auxLog(
                        "bind success: device=\(id) client_id=\(myClientId.prefix(8))… bound_client=\(bindResp.boundClientId.map { String($0.prefix(8)) + "…" } ?? "—")",
                        level: .info
                    )
                    auxValveSettings.triggerHealthCheck()
                    testMessage = String(format: appLanguage.string("aux_valve.bind_success"), id)
                }
            } catch {
                await MainActor.run {
                    let msg = AuxValveUserMessage.localize(AuxValveUserMessage.from(error), language: appLanguage)
                    auxValveSettings.auxLog("bind failed: \(msg)", level: .warning)
                    testMessage = msg
                }
            }
        }
    }

    private func unbindDevice() {
        guard hasLocalBinding else {
            auxValveSettings.auxLog("unbind ignored: no local binding", level: .warning)
            return
        }
        guard !isUnbinding else {
            auxValveSettings.auxLog("unbind ignored: already in progress", level: .warning)
            return
        }
        let previousId = auxValveSettings.normalizedTargetDeviceId
        isUnbinding = true
        testMessage = nil
        let traceWasEnabled = auxValveSettings.auxHttpTraceEnabled
        auxValveSettings.auxHttpTraceEnabled = true
        auxValveSettings.auxLog(
            "unbind step 1/3: start device=\(previousId) client_id=\(auxValveSettings.workstationClientId.prefix(8))… enabled=\(auxValveSettings.enabled)",
            level: .info
        )
        Task {
            var remoteOk = false
            var remoteDetail = "skipped (WiFi valve disabled)"
            defer {
                Task { @MainActor in
                    isUnbinding = false
                    auxValveSettings.auxHttpTraceEnabled = traceWasEnabled
                    auxValveSettings.auxLog(
                        "unbind finished device=\(previousId) remote=\(remoteOk) (\(remoteDetail))",
                        level: .info
                    )
                }
            }
            if auxValveSettings.enabled {
                do {
                    auxValveSettings.auxLog("unbind step 2/3: resolve endpoint …", level: .info)
                    let endpoint = try await auxValveSettings.wifiClient.resolveTargetDevice(
                        settings: auxValveSettings,
                        budgetDeadline: nil
                    )
                    auxValveSettings.auxLog(
                        "unbind step 2/3: endpoint \(endpoint.host):\(endpoint.port)",
                        level: .info
                    )
                    auxValveSettings.auxLog("unbind step 3/3: POST /unbind …", level: .info)
                    let resp = try await auxValveSettings.wifiClient.postUnbind(
                        host: endpoint.host,
                        port: endpoint.port,
                        settings: auxValveSettings,
                        timeout: auxValveSettings.httpTimeoutSec
                    )
                    remoteOk = resp.ok
                    remoteDetail = resp.ok
                        ? "POST /unbind OK"
                        : "POST /unbind HTTP \(resp.httpStatus) err=\(resp.errorCode ?? "—")"
                    if resp.ok {
                        auxValveSettings.auxLog("unbind remote OK device=\(previousId)", level: .info)
                    } else {
                        auxValveSettings.auxLog("unbind remote rejected: \(remoteDetail)", level: .warning)
                    }
                } catch {
                    remoteDetail = error.localizedDescription
                    auxValveSettings.auxLog(
                        "unbind remote failed (local unbind continues): \(error.localizedDescription)",
                        level: .warning
                    )
                }
            }
            await MainActor.run {
                auxValveSettings.targetDeviceId = ""
                selectedDeviceId = nil
                clearScanSession()
                auxValveSettings.auxLog(
                    "unbind step 3/3: cleared local targetDeviceId (was \(previousId))",
                    level: .info
                )
                testMessage = remoteOk
                    ? appLanguage.string("aux_valve.unbind_success")
                    : appLanguage.string("aux_valve.unbind_success_local_only")
                didAutoScanThisSession = true
                scanDevices()
            }
        }
    }

    private func syncSelectionFromSettings() {
        let normalized = auxValveSettings.normalizedTargetDeviceId
        selectedDeviceId = normalized.isEmpty ? nil : normalized
    }

    private func runValveTest(action: String) {
        guard canRunValveTest else { return }
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
                    testMessage = AuxValveUserMessage.localize(AuxValveUserMessage.from(error), language: appLanguage)
                    testInProgress = false
                }
            }
        }
    }
}
