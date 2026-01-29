import Foundation

/// BLE UUID 配置 - 请根据 ESP32-C2 固件实际使用的 UUID 修改
enum UUIDConfig {
    /// 主服务 UUID（设备主服务）
    static let mainServiceUUID = "0000FF00-0000-1000-8000-00805F9B34FB"
    
    /// 电磁阀控制 Characteristic - 写入 0x01 开 / 0x00 关
    static let valveControlUUID = "0000FF01-0000-1000-8000-00805F9B34FB"
    
    /// 压力读取 Characteristic - 读取或订阅通知
    static let pressureReadUUID = "0000FF02-0000-1000-8000-00805F9B34FB"
    
    /// RTC Characteristic - 写入十六进制触发读取，再读取返回的 RTC 时间
    static let rtcUUID = "0000FF03-0000-1000-8000-00805F9B34FB"
    
    /// 设备名称过滤（可选，为空则显示所有 BLE 设备）
    static let deviceNamePrefix = "ESP32"  // 例如 "BOG_" 或 "" 表示不过滤
}
