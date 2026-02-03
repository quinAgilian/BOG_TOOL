import Foundation
import CoreBluetooth

// MARK: - GATT 映射（从 GattServices.json 加载，不硬编码 UUID）

/// 从 Config/GattServices.json 加载的 GATT 协议映射，供 BLE 层按 key 获取 UUID。
enum GattMapping {
    
    private static let config: GattConfig? = loadConfig()
    
    /// 设备名称过滤前缀（与 JSON 中 deviceNamePrefix 一致）
    static var deviceNamePrefix: String {
        config?.deviceNamePrefix ?? "ESP32"
    }
    
    /// 协议规范版本（如 2026-02-03），用于 GATT 展示页
    static var specVersion: String? {
        config?.specVersion
    }
    
    /// 本 App 需要发现的服务 UUID 列表（用于 discoverServices）
    static var appServiceCBUUIDs: [CBUUID] {
        guard let uuids = config?.appServiceUuids else { return fallbackServiceUUIDs() }
        return uuids.map { CBUUID(string: $0) }
    }
    
    /// 本 App 需要发现的特征 UUID 列表（用于 discoverCharacteristics）
    static var appCharacteristicCBUUIDs: [CBUUID] {
        guard let keys = config?.appCharacteristicKeys else { return fallbackCharacteristicUUIDs() }
        return keys.values.map { CBUUID(string: $0) }
    }
    
    /// 按 key 获取特征的 CBUUID，用于在 didDiscoverCharacteristics 里匹配
    static func characteristicUUID(forKey key: String) -> CBUUID? {
        guard let uuidString = (config?.appCharacteristicKeys)?[key] else {
            return fallbackCharacteristicUUID(forKey: key)
        }
        return CBUUID(string: uuidString)
    }
    
    /// 按 CBUUID 返回对应的 key（ALIAS），用于日志 wr/rd 格式
    static func characteristicKey(for uuid: CBUUID) -> String? {
        guard let keys = config?.appCharacteristicKeys else { return nil }
        let uuidStr = uuid.uuidString.lowercased()
        return keys.first { $0.value.lowercased() == uuidStr }?.key
    }
    
    /// 所有服务与特征的完整定义（可用于调试或 UI 展示）
    static var services: [GattServiceDefinition] {
        config?.services ?? []
    }
    
    /// 本 App 使用的服务 UUID 集合（用于 UI 高亮）
    static var appServiceUUIDSet: Set<String> {
        Set(config?.appServiceUuids ?? [])
    }
    
    /// 本 App 使用的特征 UUID 集合（用于 UI 高亮）
    static var appCharacteristicUUIDSet: Set<String> {
        Set((config?.appCharacteristicKeys ?? [:]).values)
    }
    
    /// 是否成功从 JSON 加载（用于调试）
    static var isLoadedFromFile: Bool { config != nil }
    
    /// 按特征 UUID 返回协议中 Write 段的预设选项（单字节 0–255 → 标签），用于调试界面下拉 + 自定义 hex
    /// 解析 valueDescription 中 "Write:\n0: xxx\n1: yyy" 形式，仅保留 key 为 0–255 的项
    static func writePresets(forCharacteristicUUID uuidString: String) -> [(value: UInt8, label: String)] {
        let target = uuidString.lowercased()
        for service in (config?.services ?? []) {
            for char in service.characteristics {
                guard char.uuid.lowercased() == target,
                      let raw = char.valueDescription, !raw.isEmpty else { continue }
                return parseWritePresetsFromValueDescription(raw)
            }
        }
        return []
    }
    
    private static func parseWritePresetsFromValueDescription(_ raw: String) -> [(value: UInt8, label: String)] {
        var result: [(value: UInt8, label: String)] = []
        let lines = raw.components(separatedBy: .newlines)
        var inWrite = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased() == "write:" {
                inWrite = true
                continue
            }
            if inWrite && !t.isEmpty {
                if t.lowercased() == "read:" { break }
                guard let colonIdx = t.firstIndex(of: ":"), colonIdx != t.endIndex else { continue }
                let keyPart = String(t[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let valuePart = String(t[t.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                guard !keyPart.isEmpty, !valuePart.isEmpty,
                      let num = UInt8(keyPart),
                      keyPart.allSatisfy({ $0.isNumber }) else { continue }
                result.append((num, valuePart))
            }
        }
        return result
    }
    
    // MARK: - 常用 Key 常量（仅 key 名不硬编码 UUID）
    enum Key {
        static let valveControl = "valveControl"
        static let valveState = "valveState"
        static let valveInterval = "valveInterval"
        static let pressureRead = "pressureRead"
        static let pressureOpen = "pressureOpen"
        static let gasSystemStatus = "gasSystemStatus"
        static let co2PressureLimits = "co2PressureLimits"
        static let co2Bottle = "co2Bottle"
        static let scheduleReadWrite = "scheduleReadWrite"
        static let rtc = "rtc"
        static let testing = "testing"
        static let otaStatus = "otaStatus"
        static let otaData = "otaData"
    }
    
    // MARK: - Private Load
    
    private static func loadConfig() -> GattConfig? {
        guard let url = Bundle.main.url(forResource: "GattServices", withExtension: "json", subdirectory: nil),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GattConfig.self, from: data)
    }
    
    /// JSON 缺失时的后备 UUID（与旧版 UUIDConfig 或固件兼容时可在此维护）
    private static func fallbackServiceUUIDs() -> [CBUUID] {
        [CBUUID(string: "00000000-AEF1-CA85-FB4D-3AAFEB7A605A")]
    }
    
    private static func fallbackCharacteristicUUIDs() -> [CBUUID] {
        [CBUUID(string: "00000002-B018-FCAD-2244-C82E6B682734"),
         CBUUID(string: "00000001-B018-FCAD-2244-C82E6B682734"),
         CBUUID(string: "00000003-B018-FCAD-2244-C82E6B682734"),
         CBUUID(string: "00000002-AEF1-CA85-FB4D-3AAFEB7A605A"),
         CBUUID(string: "00000003-AEF1-CA85-FB4D-3AAFEB7A605A"),
         CBUUID(string: "00000001-AEF1-CA85-FB4D-3AAFEB7A605A"),
         CBUUID(string: "00000004-AEF1-CA85-FB4D-3AAFEB7A605A"),
         CBUUID(string: "00000005-AEF1-CA85-FB4D-3AAFEB7A605A"),
         CBUUID(string: "00000001-6037-C6A0-264E-309A67CEB3D1"),
         CBUUID(string: "00000002-6037-C6A0-264E-309A67CEB3D1"),
         CBUUID(string: "00000001-D1D0-4B64-AFCD-2F977AB4A11D"),
         CBUUID(string: "00000002-D1D0-4B64-AFCD-2F977AB4A11D"),
         CBUUID(string: "00000003-D1D0-4B64-AFCD-2F977AB4A11D")]
    }
    
    private static func fallbackCharacteristicUUID(forKey key: String) -> CBUUID? {
        let map: [String: String] = [
            Key.valveControl: "00000002-B018-FCAD-2244-C82E6B682734",
            Key.valveState: "00000001-B018-FCAD-2244-C82E6B682734",
            Key.valveInterval: "00000003-B018-FCAD-2244-C82E6B682734",
            Key.pressureRead: "00000002-AEF1-CA85-FB4D-3AAFEB7A605A",
            Key.pressureOpen: "00000003-AEF1-CA85-FB4D-3AAFEB7A605A",
            Key.gasSystemStatus: "00000001-AEF1-CA85-FB4D-3AAFEB7A605A",
            Key.co2PressureLimits: "00000004-AEF1-CA85-FB4D-3AAFEB7A605A",
            Key.co2Bottle: "00000005-AEF1-CA85-FB4D-3AAFEB7A605A",
            Key.scheduleReadWrite: "00000001-6037-C6A0-264E-309A67CEB3D1",
            Key.rtc: "00000002-6037-C6A0-264E-309A67CEB3D1",
            Key.testing: "00000003-D1D0-4B64-AFCD-2F977AB4A11D",
            Key.otaStatus: "00000001-D1D0-4B64-AFCD-2F977AB4A11D",
            Key.otaData: "00000002-D1D0-4B64-AFCD-2F977AB4A11D"
        ]
        guard let s = map[key] else { return nil }
        return CBUUID(string: s)
    }
}

// MARK: - JSON 模型

struct GattConfig: Codable {
    let deviceNamePrefix: String
    /// Optional spec version (e.g. "2026-02-03") for display on GATT protocol page
    let specVersion: String?
    /// All GATT payloads are little-endian (e.g. 0x00000001 → 01 00 00 00)
    let byteOrder: String?
    let services: [GattServiceDefinition]
    let appServiceUuids: [String]
    let appCharacteristicKeys: [String: String]
}

struct GattServiceDefinition: Codable {
    let uuid: String
    let name: String
    let characteristics: [GattCharacteristicDefinition]
}

struct GattCharacteristicDefinition: Codable {
    let uuid: String
    let description: String
    let valueType: String?
    let valueDescription: String?
    let properties: String?
}
