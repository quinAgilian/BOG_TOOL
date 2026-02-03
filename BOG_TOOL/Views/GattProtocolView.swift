import SwiftUI

/// BLE GATT 协议展示：按服务分组，展示服务名、UUID、特征及属性，便于人类阅读
struct GattProtocolView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    private let services = GattMapping.services
    private let appServiceSet = GattMapping.appServiceUUIDSet
    private let appCharSet = GattMapping.appCharacteristicUUIDSet

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if services.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(appLanguage.string("gatt.not_loaded"))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(services.enumerated()), id: \.element.uuid) { _, service in
                            ServiceSectionView(
                                service: service,
                                isAppService: appServiceSet.contains(service.uuid),
                                appCharacteristicSet: appCharSet
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(appLanguage.string("gatt.title"))
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                if let version = GattMapping.specVersion, !version.isEmpty {
                    Text("\(appLanguage.string("gatt.data_source")) (\(version))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text(appLanguage.string("gatt.data_source"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding()
    }
}

// MARK: - 单个服务区块：服务名 + UUID，下挂特征列表
private struct ServiceSectionView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    let service: GattServiceDefinition
    let isAppService: Bool
    let appCharacteristicSet: Set<String>
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .center)
                }
                .buttonStyle(.plain)
                Text(isAppService ? "\(service.name) \(appLanguage.string("gatt.app_uses"))" : service.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Spacer()
                BoldKeyUUIDView(uuid: service.uuid)
            }
            .padding(.vertical, 6)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(service.characteristics, id: \.uuid) { char in
                        CharacteristicRowView(
                            characteristic: char,
                            isAppCharacteristic: appCharacteristicSet.contains(char.uuid)
                        )
                    }
                }
                .padding(.leading, 24)
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 协议值说明解析结果（Read/Write 分节 + 编号项）
fileprivate struct ParsedValueSection: Identifiable {
    let id: String
    let title: String
    let items: [(key: String, value: String)]
}

// MARK: - 协议值说明：可解析 Read/Write 分节与 N: 描述，结构化展示
fileprivate struct ValueDescriptionView: View {
    let text: String
    private var parsedSections: [ParsedValueSection]? { parseStructuredValueDescription(text) }
    var body: some View {
        if let sections = parsedSections, !sections.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                Text("\(item.key)  \(item.value)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.leading, 8)
                    }
                }
            }
        } else {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// 解析 "Read:\n0: xxx\n1: xxx\n\nWrite:\n0: a" 或 "Read: 0: a, 1: b; Write: 0: x, 1: y"
fileprivate func parseStructuredValueDescription(_ raw: String) -> [ParsedValueSection]? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.contains("\n") {
        var sections: [ParsedValueSection] = []
        var currentTitle: String?
        var currentItems: [(key: String, value: String)] = []
        func flushSection() {
            if let title = currentTitle, !currentItems.isEmpty {
                sections.append(ParsedValueSection(id: title, title: title + ":", items: currentItems))
            }
            currentTitle = nil
            currentItems = []
        }
        for line in trimmed.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushSection(); continue }
            let lower = line.lowercased()
            if lower == "read:" || lower == "write:" {
                flushSection()
                currentTitle = lower == "read:" ? "Read" : "Write"
                continue
            }
            if let colonIdx = line.firstIndex(of: ":"), colonIdx != line.endIndex {
                let keyPart = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let valuePart = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                if !keyPart.isEmpty, !valuePart.isEmpty, keyPart.allSatisfy({ $0.isNumber || $0 == "-" }) {
                    if currentTitle != nil {
                        currentItems.append((key: keyPart, value: valuePart))
                    } else if currentTitle == nil, sections.isEmpty {
                        currentTitle = "Value"
                        currentItems.append((key: keyPart, value: valuePart))
                    }
                }
            }
        }
        flushSection()
        if !sections.isEmpty { return sections }
    }
    let semicolonParts = trimmed.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    if semicolonParts.count >= 2 {
        var sections: [ParsedValueSection] = []
        for part in semicolonParts {
            guard let idx = part.firstIndex(of: ":") else { continue }
            let possibleTitle = String(part[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
            let rest = String(part[part.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            let title: String? = possibleTitle == "read" ? "Read" : (possibleTitle == "write" ? "Write" : nil)
            guard let title = title else { continue }
            let items: [(key: String, value: String)] = rest.split(separator: ",").compactMap { seg in
                let s = seg.trimmingCharacters(in: .whitespaces)
                guard let c = s.firstIndex(of: ":") else { return nil }
                let k = String(s[..<c]).trimmingCharacters(in: .whitespaces)
                let v = String(s[s.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                return k.allSatisfy({ $0.isNumber || $0 == "-" }) ? (k, v) : nil
            }
            if !items.isEmpty {
                sections.append(ParsedValueSection(id: title, title: title + ":", items: items))
            }
        }
        if !sections.isEmpty { return sections }
    }
    return nil
}

// MARK: - 单条特征：描述、完整 UUID、属性标签、值类型与说明
private struct CharacteristicRowView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    let characteristic: GattCharacteristicDefinition
    let isAppCharacteristic: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(isAppCharacteristic ? "\(characteristic.description) \(appLanguage.string("gatt.app_badge"))" : characteristic.description)
                    .font(.subheadline.weight(.medium))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if let props = characteristic.properties, !props.isEmpty {
                    PropertiesBadges(properties: props)
                }
            }
            
            BoldKeyUUIDView(uuid: characteristic.uuid, font: .system(.caption2, design: .monospaced))
            
            if let valueDesc = characteristic.valueDescription, !valueDesc.isEmpty {
                ValueDescriptionView(text: valueDesc)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - UUID 显示：整段可连续选择（不再拆成多段，避免分段选择反人类）
private struct BoldKeyUUIDView: View {
    let uuid: String
    var font: Font = .system(.caption, design: .monospaced)
    var color: Color = .secondary
    
    var body: some View {
        Text(uuid)
            .font(font)
            .foregroundStyle(color)
            .textSelection(.enabled)
    }
}

// MARK: - 属性标签：整段可连续选择（Rd / Wr / Nfy / Rd Enc / Wr Enc 等）
private struct PropertiesBadges: View {
    let properties: String
    
    var body: some View {
        Text(properties)
            .font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
    }
}

#Preview {
    GattProtocolView()
        .environmentObject(AppLanguage())
        .frame(width: 560, height: 500)
}
