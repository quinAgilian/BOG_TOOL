import SwiftUI
import CoreBluetooth

/// 将当前时间编码为 GATT RTC 协议 7 字节 hex：秒、分、时、日、星期(1–7)、月、年(2000+)
private func rtcHexFromDate(_ date: Date) -> String {
    let c = Calendar.current
    let sec = UInt8(c.component(.second, from: date))
    let min = UInt8(c.component(.minute, from: date))
    let hour = UInt8(c.component(.hour, from: date))
    let day = UInt8(c.component(.day, from: date))
    let weekday = UInt8(c.component(.weekday, from: date)) // 1–7 Sun–Sat
    let month = UInt8(c.component(.month, from: date))
    let year = UInt8(c.component(.year, from: date) % 100)
    return [sec, min, hour, day, weekday, month, year]
        .map { String(format: "%02X", $0) }.joined()
}

/// 调试用：按 UUID 选择特征，进行写/读。下拉框仅列出 GATT 配置中存在的特征。
struct UUIDDebugView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    
    /// 下拉选项：uuid 为完整 UUID，displayName 为「描述 (前缀…后缀)」避免仅后缀重复
    private struct CharacteristicOption: Identifiable {
        let id: String
        let uuid: String
        let displayName: String
    }
    
    /// UUID 简写：取前 8 位 + … + 后 8 位，便于区分同服务下不同特征
    private static func shortUUIDDisplay(_ uuid: String) -> String {
        let cleaned = uuid.replacingOccurrences(of: "-", with: "").uppercased()
        guard cleaned.count >= 16 else { return uuid }
        let prefix = String(cleaned.prefix(8))
        let suffix = String(cleaned.suffix(8))
        return "\(prefix)…\(suffix)"
    }
    
    /// 所有本 App 使用的特征（读区下拉用）
    private var characteristicOptions: [CharacteristicOption] {
        buildCharacteristicOptions { _, _ in true }
    }
    
    /// 仅可写特征（写区下拉用，排除只读如 CO2 Pressure closed/open）
    private var writableCharacteristicOptions: [CharacteristicOption] {
        buildCharacteristicOptions { char, _ in
            (char.properties ?? "").lowercased().contains("wr")
        }
    }
    
    private func buildCharacteristicOptions(_ include: (GattCharacteristicDefinition, String) -> Bool) -> [CharacteristicOption] {
        var seen = Set<String>()
        var list: [CharacteristicOption] = []
        let uuidSet = GattMapping.appCharacteristicUUIDSet
        for service in GattMapping.services {
            for char in service.characteristics {
                guard uuidSet.contains(char.uuid), !seen.contains(char.uuid), include(char, char.uuid) else { continue }
                seen.insert(char.uuid)
                let short = Self.shortUUIDDisplay(char.uuid)
                let nickname = GattMapping.characteristicKey(for: CBUUID(string: char.uuid)) ?? char.description
                list.append(CharacteristicOption(
                    id: char.uuid,
                    uuid: char.uuid,
                    displayName: "[\(short)] \(nickname)"
                ))
            }
        }
        return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    
    @State private var selectedWriteUUID: String = ""
    @State private var writeHexInput: String = ""
    /// 写区预设选择：nil = 自定义 hex，非 nil = 选中的单字节值
    @State private var selectedWritePresetValue: UInt8? = nil
    @State private var selectedReadUUID: String = ""
    
    /// Time Write 模式：Auto = 系统时间实时刷新，Custom = 0x00 占位自定义 hex
    private enum TimeWriteMode: String, CaseIterable {
        case auto
        case custom
    }
    @State private var timeWriteMode: TimeWriteMode = .auto
    
    /// 当前选中的写特征是否为 Time Write（Schedule 服务 RTC 写入）
    private var isTimeWriteSelected: Bool {
        guard let rtcUUID = GattMapping.characteristicUUID(forKey: GattMapping.Key.rtc) else { return false }
        return selectedWriteUUID.lowercased() == rtcUUID.uuidString.lowercased()
    }
    
    /// 当前选中的写特征在 GATT 协议中的 Write 预设（单字节 0–255 → 标签），Time Write 无预设
    private var writePresets: [(value: UInt8, label: String)] {
        guard !selectedWriteUUID.isEmpty else { return [] }
        return GattMapping.writePresets(forCharacteristicUUID: selectedWriteUUID)
    }
    
    /// 读区显示：若本次读取的 UUID 与当前选中一致，则显示 hex + 解码结果
    private var readResultText: String {
        guard ble.lastDebugReadUUID?.lowercased() == selectedReadUUID.lowercased(),
              let hex = ble.lastDebugReadHex else { return "--" }
        let data = ble.lastDebugReadData ?? Data()
        let decoded = ble.decodedString(forCharacteristicUUID: selectedReadUUID, data: data)
        return "\(hex)\n→ \(decoded)"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appLanguage.string("debug.uuid_title"))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            // MARK: - Write
            VStack(alignment: .leading, spacing: 6) {
                Text(appLanguage.string("debug.uuid_write"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 8) {
                    Picker("", selection: $selectedWriteUUID) {
                        Text(appLanguage.string("debug.uuid_select")).tag("")
                        ForEach(writableCharacteristicOptions) { opt in
                            Text(opt.displayName)
                                .font(.system(.body, design: .monospaced))
                                .tag(opt.uuid)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: actionButtonWidth, maxWidth: actionButtonWidth)
                    .onChange(of: selectedWriteUUID, perform: { _ in
                        selectedWritePresetValue = nil
                        if isTimeWriteSelected {
                            timeWriteMode = .auto
                            writeHexInput = rtcHexFromDate(Date())
                        } else {
                            writeHexInput = ""
                        }
                    })
                    if isTimeWriteSelected {
                        Picker("", selection: $timeWriteMode) {
                            Text(appLanguage.string("debug.uuid_time_auto")).tag(TimeWriteMode.auto)
                            Text(appLanguage.string("debug.uuid_time_custom")).tag(TimeWriteMode.custom)
                        }
                        .labelsHidden()
                        .frame(minWidth: 80)
                        .onChange(of: timeWriteMode, perform: { mode in
                            switch mode {
                            case .auto: writeHexInput = rtcHexFromDate(Date())
                            case .custom: writeHexInput = "00000000000000"
                            }
                        })
                    } else if !writePresets.isEmpty {
                        Picker("", selection: $selectedWritePresetValue) {
                            Text(appLanguage.string("debug.uuid_preset_custom")).tag(nil as UInt8?)
                            ForEach(writePresets, id: \.value) { p in
                                Text(p.label).tag(Optional(p.value))
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 100)
                        .onChange(of: selectedWritePresetValue, perform: { newValue in
                            if let v = newValue {
                                writeHexInput = String(format: "%02X", v)
                            }
                        })
                    }
                }
                HStack(alignment: .center, spacing: 8) {
                    TextField(appLanguage.string("debug.uuid_hex_placeholder"), text: $writeHexInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 120, maxWidth: .infinity)
                        .onChange(of: writeHexInput, perform: { _ in
                            selectedWritePresetValue = nil
                        })
                    Button(appLanguage.string("debug.uuid_send")) {
                        ble.writeToCharacteristic(uuidString: selectedWriteUUID, hex: writeHexInput)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: actionButtonWidth, maxWidth: actionButtonWidth)
                    .disabled(!ble.isConnected || selectedWriteUUID.isEmpty || writeHexInput.isEmpty)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if isTimeWriteSelected, timeWriteMode == .auto {
                    writeHexInput = rtcHexFromDate(Date())
                }
            }
            
            // MARK: - Read
            VStack(alignment: .leading, spacing: 6) {
                Text(appLanguage.string("debug.uuid_read"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 8) {
                    Picker("", selection: $selectedReadUUID) {
                        Text(appLanguage.string("debug.uuid_select")).tag("")
                        ForEach(characteristicOptions) { opt in
                            Text(opt.displayName)
                                .font(.system(.body, design: .monospaced))
                                .tag(opt.uuid)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 200, maxWidth: .infinity)
                    Button(appLanguage.string("debug.uuid_read_btn")) {
                        ble.readCharacteristic(uuidString: selectedReadUUID)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(width: 130)
                    .disabled(!ble.isConnected || selectedReadUUID.isEmpty)
                }
                Text(readResultText)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(6)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)
        }
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
        .onAppear {
            if selectedWriteUUID.isEmpty || !writableCharacteristicOptions.contains(where: { $0.uuid == selectedWriteUUID }),
               let first = writableCharacteristicOptions.first {
                selectedWriteUUID = first.uuid
            }
            if isTimeWriteSelected {
                timeWriteMode = .auto
                writeHexInput = rtcHexFromDate(Date())
            }
            if selectedReadUUID.isEmpty, let first = characteristicOptions.first {
                selectedReadUUID = first.uuid
            }
        }
    }
}
