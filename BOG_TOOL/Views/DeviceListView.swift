import SwiftUI

/// 设备列表与连接区域
struct DeviceListView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    @State private var showFilterPopover = false
    @State private var showGattProtocol = false

    private var connectionErrorMessage: String? {
        if let key = ble.errorMessageKey { return appLanguage.string(key) }
        return ble.errorMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let msg = connectionErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(appLanguage.string("error.dismiss")) {
                        ble.clearError()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }
            HStack {
                Text(appLanguage.string("device_list.title"))
                    .font(.headline)
                Spacer()
                Button(appLanguage.string("device_list.gatt_protocol")) {
                    showGattProtocol = true
                }
                .buttonStyle(.bordered)
                if ble.isConnected {
                    Text(ble.connectedDeviceName ?? appLanguage.string("device_list.connected"))
                        .foregroundStyle(.green)
                    Button(appLanguage.string("device_list.disconnect")) {
                        ble.disconnect()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(appLanguage.string("device_list.filter_rules")) {
                        showFilterPopover = true
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showFilterPopover, arrowEdge: .bottom) {
                        ScanFilterRuleView(ble: ble)
                            .frame(width: 280)
                            .padding()
                    }
                    if ble.isScanning {
                        Button(appLanguage.string("device_list.stop_scan")) { ble.stopScan() }
                            .buttonStyle(.bordered)
                    } else {
                        Button(appLanguage.string("device_list.scan")) { ble.startScan() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            if !ble.isConnected {
                DeviceTableSection(ble: ble)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .sheet(isPresented: $showGattProtocol) {
            GattProtocolView()
        }
    }
}

/// 扫描结果表格：点击列标题按该列排序，列有 Name | RSSI | 标识
struct DeviceTableSection: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    @State private var sortOrder: [KeyPathComparator<BLEDevice>] = [KeyPathComparator(\.name, order: .forward)]
    @State private var selectedId: Set<UUID> = []

    private var sortedDevices: [BLEDevice] {
        ble.discoveredDevices.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Table(sortedDevices, selection: $selectedId, sortOrder: $sortOrder) {
                TableColumn(appLanguage.string("device_list.name_column"), value: \.name)
                TableColumn(appLanguage.string("device_list.rssi_column"), value: \.sortKeyForRssi) { (device: BLEDevice) in
                    Text(verbatim: String(device.rssi))
                }
                TableColumn(appLanguage.string("device_list.id_column"), value: \.shortId)
            }
            .frame(height: 140)
            HStack {
                if let id = selectedId.first, let device = ble.discoveredDevices.first(where: { $0.id == id }) {
                    Button(appLanguage.string("device_list.connect")) {
                        ble.connect(to: device)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        }
    }
}

/// 扫描过滤规则弹窗：RSSI/名称/无名 各规则独立使能
struct ScanFilterRuleView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appLanguage.string("filter.title"))
                .font(.headline)

            // RSSI：右侧开关 + 最小值（文本左对齐，开关右对齐）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(appLanguage.string("filter.rssi"))
                    Spacer(minLength: 8)
                    Toggle("", isOn: $ble.scanFilterRSSIEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                TextField(appLanguage.string("filter.min_dbm"), value: $ble.scanFilterMinRSSI, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .disabled(!ble.scanFilterRSSIEnabled)
                Text(appLanguage.string("filter.signal_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: ble.scanFilterRSSIEnabled) { _ in ble.reapplyScanFilter() }
            .onChange(of: ble.scanFilterMinRSSI) { _ in if ble.scanFilterRSSIEnabled { ble.reapplyScanFilter() } }

            // 名称：右侧开关 + 关键词（逗号分隔，满足其一即可）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(appLanguage.string("filter.name"))
                    Spacer(minLength: 8)
                    Toggle("", isOn: $ble.scanFilterNameEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                TextField(appLanguage.string("filter.name_placeholder"), text: $ble.scanFilterNamePrefix)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!ble.scanFilterNameEnabled)
                Text(appLanguage.string("filter.name_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: ble.scanFilterNameEnabled) { _ in ble.reapplyScanFilter() }
            .onChange(of: ble.scanFilterNamePrefix) { _ in if ble.scanFilterNameEnabled { ble.reapplyScanFilter() } }

            // 无名设备：右侧开关
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(appLanguage.string("filter.exclude_unnamed"))
                    Spacer(minLength: 8)
                    Toggle("", isOn: $ble.scanFilterExcludeUnnamed)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Text(appLanguage.string("filter.empty_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: ble.scanFilterExcludeUnnamed) { _ in ble.reapplyScanFilter() }
        }
    }
}
