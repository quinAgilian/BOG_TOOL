import SwiftUI

/// 调试用：按 UUID 选择特征，进行写/读。下拉框仅列出 GATT 配置中存在的特征。
struct UUIDDebugView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    
    /// 下拉选项：uuid 为完整 UUID，displayName 为「描述 (后8位)」
    private struct CharacteristicOption: Identifiable {
        let id: String
        let uuid: String
        let displayName: String
    }
    
    private var characteristicOptions: [CharacteristicOption] {
        var seen = Set<String>()
        var list: [CharacteristicOption] = []
        let uuidSet = GattMapping.appCharacteristicUUIDSet
        for service in GattMapping.services {
            for char in service.characteristics {
                guard uuidSet.contains(char.uuid), !seen.contains(char.uuid) else { continue }
                seen.insert(char.uuid)
                let suffix = char.uuid.count >= 8 ? String(char.uuid.suffix(8)) : char.uuid
                list.append(CharacteristicOption(
                    id: char.uuid,
                    uuid: char.uuid,
                    displayName: "\(char.description) (\(suffix))"
                ))
            }
        }
        return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    
    @State private var selectedWriteUUID: String = ""
    @State private var writeHexInput: String = ""
    @State private var selectedReadUUID: String = ""
    @State private var readResult: String = "--"
    
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
                        ForEach(characteristicOptions) { opt in
                            Text(opt.displayName).tag(opt.uuid)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 200, maxWidth: .infinity)
                    TextField(appLanguage.string("debug.uuid_hex_placeholder"), text: $writeHexInput)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 120)
                    Button(appLanguage.string("debug.uuid_send")) {
                        // TODO: 发送到设备
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ble.isConnected || selectedWriteUUID.isEmpty)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)
            
            // MARK: - Read
            VStack(alignment: .leading, spacing: 6) {
                Text(appLanguage.string("debug.uuid_read"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 8) {
                    Picker("", selection: $selectedReadUUID) {
                        Text(appLanguage.string("debug.uuid_select")).tag("")
                        ForEach(characteristicOptions) { opt in
                            Text(opt.displayName).tag(opt.uuid)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 200, maxWidth: .infinity)
                    Button(appLanguage.string("debug.uuid_read_btn")) {
                        // TODO: 从设备读取
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ble.isConnected || selectedReadUUID.isEmpty)
                }
                Text(readResult)
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
            if selectedWriteUUID.isEmpty, let first = characteristicOptions.first {
                selectedWriteUUID = first.uuid
            }
            if selectedReadUUID.isEmpty, let first = characteristicOptions.first {
                selectedReadUUID = first.uuid
            }
        }
    }
}
