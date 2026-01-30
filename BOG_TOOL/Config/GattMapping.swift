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
    
    // MARK: - 常用 Key 常量（仅 key 名不硬编码 UUID）
    enum Key {
        static let valveControl = "valveControl"
        static let valveState = "valveState"
        static let pressureRead = "pressureRead"
        static let pressureOpen = "pressureOpen"
        static let gasSystemStatus = "gasSystemStatus"
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
         CBUUID(string: "00000002-AEF1-CA85-FB4D-3AAFEB7A605A"),
         CBUUID(string: "00000001-AEF1-CA85-FB4D-3AAFEB7A605A"),
         CBUUID(string: "00000002-6037-C6A0-264E-309A67CEB3D1"),
         CBUUID(string: "00000001-D1D0-4B64-AFCD-2F977AB4A11D"),
         CBUUID(string: "00000002-D1D0-4B64-AFCD-2F977AB4A11D"),
         CBUUID(string: "00000003-D1D0-4B64-AFCD-2F977AB4A11D")]
    }
    
    private static func fallbackCharacteristicUUID(forKey key: String) -> CBUUID? {
        let map: [String: String] = [
            Key.valveControl: "00000002-B018-FCAD-2244-C82E6B682734",
            Key.valveState: "00000001-B018-FCAD-2244-C82E6B682734",
            Key.pressureRead: "00000002-AEF1-CA85-FB4D-3AAFEB7A605A",
            Key.pressureOpen: "00000003-AEF1-CA85-FB4D-3AAFEB7A605A",
            Key.gasSystemStatus: "00000001-AEF1-CA85-FB4D-3AAFEB7A605A",
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
