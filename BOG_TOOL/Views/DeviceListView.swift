import SwiftUI

/// 设备列表与连接区域
struct DeviceListView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    var selectedMode: AppMode  // 当前模式：产测或Debug
    @State private var showFilterPopover = false
    @State private var showProductionTestRules = false
    @State private var showGattProtocol = false
    @State private var selectedId: Set<UUID> = []  // 选中的设备ID

    private var connectionErrorMessage: String? {
        if let key = ble.errorMessageKey { return appLanguage.string(key) }
        return ble.errorMessage
    }
    
    /// 获取当前选中的设备
    private var selectedDevice: BLEDevice? {
        guard let id = selectedId.first else { return nil }
        return ble.discoveredDevices.first(where: { $0.id == id })
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
                Button(appLanguage.string("device_list.production_test_rules")) {
                    showProductionTestRules = true
                }
                .buttonStyle(.bordered)
                Button(appLanguage.string("device_list.gatt_protocol")) {
                    showGattProtocol = true
                }
                .buttonStyle(.bordered)
                if ble.isConnected {
                    Text(ble.connectedDeviceName ?? appLanguage.string("device_list.connected"))
                        .foregroundStyle(.green)
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
                DeviceTableSection(ble: ble, selectedId: $selectedId, selectedMode: selectedMode)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .sheet(isPresented: $showProductionTestRules) {
            ProductionTestRulesView(ble: ble)
        }
        .sheet(isPresented: $showGattProtocol) {
            GattProtocolView()
        }
        .onChange(of: selectedId) { newValue in
            // 更新 BLEManager 中的选中设备ID
            ble.selectedDeviceId = newValue.first
        }
        .onChange(of: ble.selectedDeviceId) { newValue in
            // 当 BLEManager 中的选中设备ID变化时，同步到 UI（如果 UI 中未选中）
            if newValue != nil && selectedId.isEmpty {
                selectedId = [newValue!]
            }
        }
        .onChange(of: ble.isConnected) { connected in
            // 连接成功时，如果 UI 中未选中设备，自动选中连接的设备
            if connected, let deviceId = ble.selectedDeviceId, selectedId.isEmpty {
                selectedId = [deviceId]
            }
        }
    }
}

/// 扫描结果表格：点击列标题按该列排序，列有 Name | RSSI | 标识
struct DeviceTableSection: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    @Binding var selectedId: Set<UUID>  // 从父视图传入
    var selectedMode: AppMode  // 当前模式
    @State private var sortOrder: [KeyPathComparator<BLEDevice>] = [KeyPathComparator(\.name, order: .forward)]

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
