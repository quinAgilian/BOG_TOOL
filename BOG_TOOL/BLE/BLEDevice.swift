import Foundation
import CoreBluetooth

struct BLEDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    
    init(peripheral: CBPeripheral, name: String, rssi: Int) {
        self.id = peripheral.identifier
        self.peripheral = peripheral
        self.name = name
        self.rssi = rssi
    }
    
    /// 短标识（UUID 后 8 位），用于表格列区分设备
    var shortId: String {
        let s = peripheral.identifier.uuidString
        let suffix = s.suffix(8)
        return String(suffix).uppercased()
    }
    
    /// 用于表格按 RSSI 数值排序的字符串（数值越大字符串越大）
    var sortKeyForRssi: String {
        String(1000 + rssi)
    }
}
