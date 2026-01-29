import Foundation
import CoreBluetooth
import Combine
import AppKit
import UniformTypeIdentifiers

/// BLE 连接管理，用于与 ESP32-C2 通信
@MainActor
final class BLEManager: NSObject, ObservableObject {
    // MARK: - Published State
    @Published var isPoweredOn = false
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var discoveredDevices: [BLEDevice] = []
    @Published var connectedDeviceName: String?
    @Published var lastPressureValue: String = "--"
    @Published var lastRTCValue: String = "--"
    /// OTA Status 读值：0–4（见 OTA_Flow.md）
    @Published var lastOtaStatusValue: UInt8?
    /// 当前选择的固件 URL（持久化到 UserDefaults）
    @Published var selectedFirmwareURL: URL?
    /// OTA 进度 0...1
    @Published var otaProgress: Double = 0
    /// OTA 是否进行中
    @Published var isOTAInProgress: Bool = false
    /// 当前设备固件版本（连接后读取，仅 UI 展示用）
    @Published var currentFirmwareVersion: String?
    @Published var logMessages: [String] = []
    @Published var errorMessage: String?
    
    /// 扫描过滤：各规则独立使能，无全局开关
    /// RSSI 规则使能
    @Published var scanFilterRSSIEnabled: Bool = false
    /// 最小 RSSI（仅显示 rssi >= 此值）
    @Published var scanFilterMinRSSI: Int = -100
    /// 名称前缀规则使能
    @Published var scanFilterNameEnabled: Bool = false
    /// 设备名称前缀
    @Published var scanFilterNamePrefix: String = ""
    /// 是否过滤无名设备（空名称 / 未知设备），默认勾选
    @Published var scanFilterExcludeUnnamed: Bool = true
    
    // MARK: - Internal
    private var centralManager: CBCentralManager!
    private var hasAutoStartedScan = false
    private var connectedPeripheral: CBPeripheral?
    private var valveCharacteristic: CBCharacteristic?
    private var pressureCharacteristic: CBCharacteristic?
    private var rtcCharacteristic: CBCharacteristic?
    private var otaStatusCharacteristic: CBCharacteristic?
    private var otaDataCharacteristic: CBCharacteristic?
    
    private var valveControlCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.valveControl) }
    private var pressureReadCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.pressureRead) }
    private var rtcCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.rtc) }
    private var gasSystemStatusCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.gasSystemStatus) }
    private var otaStatusCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.otaStatus) }
    private var otaDataCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.otaData) }
    
    private static let otaFirmwarePathKey = "ota.selectedFirmwarePath"
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: nil, queue: nil)
        centralManager.delegate = self
        loadSavedFirmwareURL()
    }
    
    private func loadSavedFirmwareURL() {
        guard let path = UserDefaults.standard.string(forKey: Self.otaFirmwarePathKey),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }
        selectedFirmwareURL = URL(fileURLWithPath: path)
    }
    
    // MARK: - Public Actions
    
    func startScan() {
        guard centralManager.state == .poweredOn else {
            appendLog("蓝牙未就绪，请稍后再试")
            return
        }
        discoveredDevices.removeAll()
        centralManager.scanForPeripherals(withServices: nil, options: nil)
        isScanning = true
        appendLog("开始扫描 BLE 设备...")
    }
    
    func stopScan() {
        centralManager.stopScan()
        isScanning = false
        appendLog("停止扫描")
    }
    
    /// 名称过滤关键词（逗号分隔，满足其一即可，如 "BOG,CO2"）
    private var nameFilterKeywords: [String] {
        scanFilterNamePrefix
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    /// 设备名是否匹配名称过滤（含任一关键词即可）
    private func deviceMatchesNameFilter(_ name: String) -> Bool {
        let keywords = nameFilterKeywords
        if keywords.isEmpty { return true }
        let lower = name.lowercased()
        return keywords.contains { lower.contains($0.lowercased()) }
    }
    
    /// 任一过滤规则变更时，对当前已扫描列表立即生效一次
    func reapplyScanFilter() {
        let before = discoveredDevices.count
        discoveredDevices = discoveredDevices.filter { device in
            if scanFilterRSSIEnabled && device.rssi < scanFilterMinRSSI { return false }
            if scanFilterNameEnabled && !deviceMatchesNameFilter(device.name) { return false }
            if scanFilterExcludeUnnamed && (device.name.isEmpty || device.name == "未知设备" || device.name.lowercased() == "unknown") {
                return false
            }
            return true
        }
        let after = discoveredDevices.count
        if before != after { appendLog("过滤规则已生效: \(before) → \(after) 条") }
    }
    
    func connect(to device: BLEDevice) {
        stopScan()
        centralManager.connect(device.peripheral, options: nil)
        appendLog("正在连接: \(device.name)")
    }
    
    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
        appendLog("断开连接")
    }
    
    /// 电磁阀控制：open = true 开，false 关
    func setValve(open: Bool) {
        let data = Data([open ? 0x01 : 0x00])
        writeToCharacteristic(valveCharacteristic, data: data)
        appendLog("电磁阀: \(open ? "开" : "关")")
    }
    
    /// 读取压力
    func readPressure() {
        readCharacteristic(pressureCharacteristic)
        appendLog("请求读取压力")
    }
    
    /// RTC 测试：写入十六进制字符串触发设备返回 RTC，再读取
    func writeRTCTrigger(hexString: String) {
        guard let data = dataFromHexString(hexString) else {
            appendLog("无效的十六进制: \(hexString)")
            errorMessage = "无效的十六进制字符串"
            return
        }
        writeToCharacteristic(rtcCharacteristic, data: data)
        appendLog("已写入 RTC 触发: \(hexString)")
        // 写入后延迟读取 RTC 返回值
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            readCharacteristic(rtcCharacteristic)
        }
    }
    
    /// 读取 RTC 特征值（不先写入时也可直接读）
    func readRTC() {
        readCharacteristic(rtcCharacteristic)
    }
    
    // MARK: - OTA（逻辑见 Config/OTA_Flow.md）
    
    /// 写 OTA Status：0=abort, 1=start, 2=finished, 3=reboot
    func writeOtaStatus(_ value: UInt8) {
        let data = Data([value])
        writeToCharacteristic(otaStatusCharacteristic, data: data)
        appendLog("OTA Status 写入: \(value)")
    }
    
    /// 写一包 OTA 数据（每包 ≤ 200 字节）
    func writeOtaDataChunk(_ chunk: Data) {
        guard chunk.count <= 200 else {
            appendLog("OTA 单包超过 200 字节，已截断")
            writeToCharacteristic(otaDataCharacteristic, data: chunk.prefix(200))
            return
        }
        writeToCharacteristic(otaDataCharacteristic, data: chunk)
    }
    
    /// 读 OTA Status（结果在 didUpdateValueFor 中，可扩展 lastOtaStatusValue）
    func readOtaStatus() {
        readCharacteristic(otaStatusCharacteristic)
    }
    
    /// OTA 特征是否就绪（用于 UI 判断是否显示 OTA 入口）
    var isOtaAvailable: Bool {
        otaStatusCharacteristic != nil && otaDataCharacteristic != nil
    }
    
    /// 选择固件文件并保存路径（产测与 Debug 共用，仅此一处调用）
    func browseAndSaveFirmware() {
        let panel = NSOpenPanel()
        panel.title = "选择固件"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data]
        panel.allowedContentTypes.append(UTType(filenameExtension: "bin") ?? .data)
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            UserDefaults.standard.set(path, forKey: Self.otaFirmwarePathKey)
            selectedFirmwareURL = url
            appendLog("[OTA] 已选择固件: \(url.lastPathComponent)")
        }
    }
    
    /// 启动 OTA（产测与 Debug 共用，仅此一处实现逻辑）
    func startOTA() {
        guard let url = selectedFirmwareURL else {
            appendLog("[OTA] 请先选择固件")
            return
        }
        guard isConnected else {
            appendLog("[OTA] 请先连接设备")
            return
        }
        guard !isOTAInProgress else {
            appendLog("[OTA] 正在进行中")
            return
        }
        guard isOtaAvailable else {
            appendLog("[OTA] 设备不支持 OTA 或特征未就绪")
            return
        }
        isOTAInProgress = true
        otaProgress = 0
        appendLog("[OTA] 启动: \(url.lastPathComponent)")
        // TODO: 实际 OTA 流程在此实现，产测与 Debug 均调用本方法
        Task { @MainActor in
            defer { isOTAInProgress = false }
            // 占位：模拟进度与日志，后续替换为真实 OTA
            for p in stride(from: 0.0, through: 1.0, by: 0.05) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                otaProgress = p
                appendLog("[OTA] 进度 \(Int(p * 100))%")
            }
            otaProgress = 1
            appendLog("[OTA] 完成（当前为占位逻辑）")
        }
    }
    
    // MARK: - Private Helpers
    
    private func appendLog(_ msg: String) {
        let line = "\(formattedTime()) \(msg)"
        logMessages.append(line)
        if logMessages.count > 500 { logMessages.removeFirst() }
    }
    
    private func formattedTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
    
    private func writeToCharacteristic(_ char: CBCharacteristic?, data: Data) {
        guard let peripheral = connectedPeripheral, let char = char else {
            appendLog("未连接或特征不可用")
            return
        }
        peripheral.writeValue(data, for: char, type: .withResponse)
    }
    
    private func readCharacteristic(_ char: CBCharacteristic?) {
        guard let peripheral = connectedPeripheral, let char = char else {
            appendLog("未连接或特征不可用")
            return
        }
        peripheral.readValue(for: char)
    }
    
    private func dataFromHexString(_ hex: String) -> Data? {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard cleaned.count % 2 == 0,
              let data = Data(hexString: cleaned) else { return nil }
        return data
    }
    
    private func discoverServicesAndCharacteristics(for peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(GattMapping.appServiceCBUUIDs)
    }
    
    private func updateCharacteristics(from service: CBService) {
        for char in service.characteristics ?? [] {
            if let u = valveControlCBUUID, char.uuid == u { valveCharacteristic = char }
            else if let u = pressureReadCBUUID, char.uuid == u { pressureCharacteristic = char }
            else if let u = rtcCBUUID, char.uuid == u { rtcCharacteristic = char }
            else if let u = otaStatusCBUUID, char.uuid == u { otaStatusCharacteristic = char }
            else if let u = otaDataCBUUID, char.uuid == u { otaDataCharacteristic = char }
        }
        if pressureCharacteristic?.properties.contains(.notify) == true {
            connectedPeripheral?.setNotifyValue(true, for: pressureCharacteristic!)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            isPoweredOn = (central.state == .poweredOn)
            if central.state != .poweredOn {
                appendLog("蓝牙状态: \(central.state.description)")
            } else if !hasAutoStartedScan && !isConnected {
                hasAutoStartedScan = true
                startScan()
            }
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
            let displayName = name.isEmpty ? "未知设备" : name
            let rssiValue = RSSI.intValue
            
            // 按各规则使能分别过滤
            if scanFilterRSSIEnabled && rssiValue < scanFilterMinRSSI { return }
            if scanFilterExcludeUnnamed && (name.isEmpty || displayName == "未知设备" || name.lowercased() == "unknown") {
                return
            }
            if scanFilterNameEnabled && !deviceMatchesNameFilter(displayName) { return }
            
            if discoveredDevices.contains(where: { $0.peripheral.identifier == peripheral.identifier }) {
                return
            }
            let device = BLEDevice(peripheral: peripheral, name: displayName, rssi: rssiValue)
            discoveredDevices.append(device)
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectedPeripheral = peripheral
            isConnected = true
            connectedDeviceName = peripheral.name ?? "已连接"
            appendLog("已连接: \(connectedDeviceName ?? "")")
            discoverServicesAndCharacteristics(for: peripheral)
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            appendLog("连接失败: \(error?.localizedDescription ?? "")")
            errorMessage = error?.localizedDescription
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectedPeripheral = nil
            valveCharacteristic = nil
            pressureCharacteristic = nil
            rtcCharacteristic = nil
            otaStatusCharacteristic = nil
            otaDataCharacteristic = nil
            isConnected = false
            connectedDeviceName = nil
            lastPressureValue = "--"
            lastRTCValue = "--"
            appendLog("已断开" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            Task { @MainActor in appendLog("发现服务失败: \(error!.localizedDescription)") }
            return
        }
        let appServiceSet = Set(GattMapping.appServiceCBUUIDs.map { $0.uuidString })
        for service in peripheral.services ?? [] {
            if appServiceSet.contains(service.uuid.uuidString) {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            Task { @MainActor in appendLog("发现特征失败: \(error!.localizedDescription)") }
            return
        }
        Task { @MainActor in
            updateCharacteristics(from: service)
            appendLog("服务与特征就绪")
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        Task { @MainActor in
            if let u = pressureReadCBUUID, characteristic.uuid == u {
                lastPressureValue = formatPressureData(data)
                appendLog("压力: \(lastPressureValue)")
            } else if let u = rtcCBUUID, characteristic.uuid == u {
                lastRTCValue = formatRTCData(data)
                appendLog("RTC: \(lastRTCValue)")
            } else if let u = gasSystemStatusCBUUID, characteristic.uuid == u {
                appendLog("Gas status: \(formatGasStatusData(data))")
            } else if let u = otaStatusCBUUID, characteristic.uuid == u, let b = data.first {
                lastOtaStatusValue = b
                appendLog("OTA Status: \(b)")
            }
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            Task { @MainActor in appendLog("写入失败: \(error.localizedDescription)") }
        }
    }
    
    @MainActor private func formatPressureData(_ data: Data) -> String {
        if data.count >= 4 {
            let raw = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            return String(format: "%.2f", Float(bitPattern: raw))
        }
        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    /// 解码设备 RTC 时间戳：支持 6 字节 [年低, 月, 日, 时, 分, 秒] 或 7 字节 [年高, 年低, 月, 日, 时, 分, 秒]
    @MainActor private func formatRTCData(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if data.count >= 7 {
            return String(format: "20%02x%02x-%02x-%02x %02x:%02x:%02x",
                          bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6])
        }
        if data.count >= 6 {
            return String(format: "20%02x-%02x-%02x %02x:%02x:%02x",
                          bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5])
        }
        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    /// Gas system status: 0 initially closed, 1 ok, 2 leak, 3–7 见 GattServices.json
    @MainActor private func formatGasStatusData(_ data: Data) -> String {
        let statusNames = ["initially closed", "ok", "leak", "check long closed", "leak check open", "leak confirm closed", "empty", "empty resolve"]
        guard let b = data.first, Int(b) < statusNames.count else {
            return data.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        return "\(b) (\(statusNames[Int(b)]))"
    }
}

// MARK: - CBManagerState Description
extension CBManagerState {
    var description: String {
        switch self {
        case .unknown: return "未知"
        case .resetting: return "重置中"
        case .unsupported: return "不支持"
        case .unauthorized: return "未授权"
        case .poweredOff: return "已关闭"
        case .poweredOn: return "已开启"
        @unknown default: return "未知"
        }
    }
}

// MARK: - Data Hex
extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let j = hexString.index(i, offsetBy: 2)
            guard let byte = UInt8(hexString[i..<j], radix: 16) else { return nil }
            data.append(byte)
            i = j
        }
        self = data
    }
}
