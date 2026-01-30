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
    /// 关阀压力（00000002-AEF1-...，CO2 Pressure when valve is closed）
    @Published var lastPressureValue: String = "--"
    /// 开阀压力（00000003-AEF1-...，CO2 Pressure when valve is open）
    @Published var lastPressureOpenValue: String = "--"
    @Published var lastRTCValue: String = "--"
    /// 最近一次 RTC 读取成功时的系统时间（仅在该次读取时更新）
    @Published var lastSystemTimeAtRTCRead: String = "--"
    /// 最近一次 RTC 读取时设备时间与系统时间的差值（仅在该次读取时更新），正数表示设备快
    @Published var lastTimeDiffFromRTCRead: String = "--"
    /// 阀门状态：0 undefined, 1 open, 2 closed（来自 Valve State Read，实际状态）
    @Published var lastValveStateValue: String = "--"
    /// 阀门模式：0 auto, 1 open, 2 closed（来自 Valve Mode Read，请求/已接受模式）
    @Published var lastValveModeValue: String = "--"
    /// 操作电磁阀时若当前已是目标状态则提示一次（如「当前已是开启状态」）
    @Published var valveOperationWarning: String?
    /// OTA Status 读值：0–4（见 OTA_Flow.md）
    @Published var lastOtaStatusValue: UInt8?
    /// 当前选择的固件 URL（持久化到 UserDefaults）
    @Published var selectedFirmwareURL: URL?
    /// OTA 进度 0...1
    @Published var otaProgress: Double = 0
    /// OTA 是否进行中
    @Published var isOTAInProgress: Bool = false
    /// 单次 OTA 开始时间（用于显示已用/剩余时间），结束时置 nil
    @Published var otaStartTime: Date?
    /// OTA 成功完成时的耗时（秒），用于完成后在状态/标题显示
    @Published var otaCompletedDuration: TimeInterval?
    /// 当前设备固件版本（连接后从 Device Information 读取）
    @Published var currentFirmwareVersion: String?
    /// 设备序列号 SN（连接后从 Device Information 读取）
    @Published var deviceSerialNumber: String?
    /// 设备制造商（连接后从 Device Information 读取）
    @Published var deviceManufacturer: String?
    /// 设备型号（连接后从 Device Information 读取）
    @Published var deviceModelNumber: String?
    /// 设备硬件版本（连接后从 Device Information 读取）
    @Published var deviceHardwareRevision: String?
    /// 日志等级：debug / info / warning / error，用于展示与过滤
    enum LogLevel: String, CaseIterable {
        case debug
        case info
        case warning
        case error
    }
    /// 单条日志：等级 + 整行文案（含时间戳）
    struct LogEntry: Identifiable {
        let id = UUID()
        let level: LogLevel
        let line: String
    }
    @Published var logEntries: [LogEntry] = []
    /// 是否在日志区域显示对应等级（勾选则显示）
    @Published var showLogLevelDebug = true
    @Published var showLogLevelInfo = true
    @Published var showLogLevelWarning = true
    @Published var showLogLevelError = true
    @Published var errorMessage: String?
    /// 若为配对已清除等已知错误，存 key（由 UI 按当前语言显示）；否则 errorMessage 为系统原始文案
    @Published var errorMessageKey: String?
    
    /// 扫描过滤：各规则独立使能，无全局开关
    /// RSSI 规则使能
    @Published var scanFilterRSSIEnabled: Bool = false
    /// 最小 RSSI（仅显示 rssi >= 此值）
    @Published var scanFilterMinRSSI: Int = -100
    /// 名称前缀规则使能（默认开启，按名称关键词过滤）
    @Published var scanFilterNameEnabled: Bool = true
    /// 设备名称关键词，逗号分隔，满足其一即可（默认 CO2,BOG）
    @Published var scanFilterNamePrefix: String = "CO2,BOG"
    /// 是否过滤无名设备（空名称 / 未知设备），默认勾选
    @Published var scanFilterExcludeUnnamed: Bool = true
    /// 连接后是否已发现并缓存了 GATT 特征（压力/RTC 等），为 true 后才应发起读/写，避免「未连接或特征不可用」和连接超时
    @Published var areCharacteristicsReady: Bool = false
    
    // MARK: - Internal
    private var centralManager: CBCentralManager!
    private var hasAutoStartedScan = false
    private var connectedPeripheral: CBPeripheral?
    private var valveCharacteristic: CBCharacteristic?
    private var valveStateCharacteristic: CBCharacteristic?
    private var pressureCharacteristic: CBCharacteristic?
    private var pressureOpenCharacteristic: CBCharacteristic?
    private var rtcCharacteristic: CBCharacteristic?
    private var testingCharacteristic: CBCharacteristic?
    private var otaStatusCharacteristic: CBCharacteristic?
    private var otaDataCharacteristic: CBCharacteristic?
    
    private var valveControlCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.valveControl) }
    private var valveStateCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.valveState) }
    private var pressureReadCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.pressureRead) }
    private var pressureOpenCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.pressureOpen) }
    private var rtcCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.rtc) }
    private var testingCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.testing) }
    private var gasSystemStatusCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.gasSystemStatus) }
    private var otaStatusCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.otaStatus) }
    private var otaDataCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.otaData) }
    
    private static let otaFirmwarePathKey = "ota.selectedFirmwarePath"
    /// OTA 流程状态机：写 start(1) → 等设备返回 1（或超时）→ 发块（每包仅写+延时，不读 Status）→ 写 finished(2) → 轮询 3/4
    private enum OTAFlowState {
        case idle
        /// 已写 start(1)，等待设备读回 Status=1 再发块（超时则直接发块，确保能进入 OTA 进度）
        case waitingStartAck(chunks: [Data])
        /// 正在写固件块，nextChunkIndex 为下一包下标（每包写成功后仅延时再发下一包，不读 OTA Status）
        case sendingChunks(chunks: [Data], nextChunkIndex: Int)
        /// 已写 finished(2)，轮询读 OTA Status 直到 3 或 4
        case sentFinishedPolling
        case done
        case failed(String)
    }
    private var otaFlowState: OTAFlowState = .idle
    /// OTA 进度日志节流：只打 0%、5%、…、100%，避免刷屏
    private var lastLoggedOtaProgressStep: Int = -1
    /// OTA 进度 UI 节流：仅当整数百分比变化时更新 @Published otaProgress，避免每包触发重绘导致 OTA 变慢
    private var lastPublishedOtaProgressPercent: Int = -1
    private static let otaChunkSize = 200
    /// 每包写成功后、发下一包前的延时（纳秒）；5ms 给设备留处理时间，0ms 易导致 image fail
    private static let otaChunkDelayNs: UInt64 = 5_000_000 // 5 ms
    /// 每包 OTA 写入开始时间（用于统计 BLE 响应耗时）
    private var otaChunkWriteStartTime: Date?
    /// 累计 BLE 写响应耗时（秒），用于日志统计
    private var otaChunkRttSum: TimeInterval = 0
    private var otaChunkRttCount: Int = 0
    /// 轮询 OTA Status 间隔（纳秒）
    private static let otaPollIntervalSeconds: UInt64 = 400_000_000 // 0.4s
    /// 等待设备返回 Status=1（启动确认）超时（纳秒），超时后直接发块，确保能进入 OTA 进度
    private static let otaStartAckTimeoutNs: UInt64 = 2_500_000_000 // 2.5s
    /// 阀门状态读「认证不足」已打过一次日志，避免每轮询一次刷屏
    private var valveStateAuthErrorLogged = false
    /// 先读再设：读完后若已是目标状态则仅警告，否则写入。nil = 无待处理
    private var pendingValveSetOpen: Bool?
    
    /// Device Information 服务与特征 UUID（标准 GATT）
    private static let deviceInfoServiceUUID = CBUUID(string: "180A")
    private static let charManufacturerUUID = CBUUID(string: "2A29")
    private static let charModelUUID = CBUUID(string: "2A24")
    private static let charSerialUUID = CBUUID(string: "2A25")
    private static let charFirmwareUUID = CBUUID(string: "2A26")
    private static let charHardwareUUID = CBUUID(string: "2A27")
    
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
            appendLog("蓝牙未就绪，请稍后再试", level: .warning)
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
        clearError()
        stopScan()
        centralManager.connect(device.peripheral, options: nil)
        appendLog("正在连接: \(device.name)")
    }
    
    /// 清除连接/配对等错误提示（重试连接或用户点击「知道了」时调用）
    func clearError() {
        errorMessage = nil
        errorMessageKey = nil
    }
    
    /// 是否为「设备端已清除配对信息」类错误（连接失败或断开时系统可能返回）
    private static func isPairingRemovedError(_ error: Error?) -> Bool {
        guard let msg = error?.localizedDescription else { return false }
        let lower = msg.lowercased()
        return lower.contains("peer removed") || lower.contains("pairing") || msg.contains("配对")
    }
    
    /// 打开系统「蓝牙」设置（配对已清除时便于用户移除设备）
    static func openBluetoothSettings() {
        // macOS 13+ System Settings 使用 extension URL；旧版为 com.apple.preferences.Bluetooth
        let urls = [
            "x-apple.systempreferences:com.apple.Bluetooth-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.Bluetooth"
        ]
        for urlString in urls {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) { return }
        }
    }
    
    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
        appendLog("断开连接")
    }
    
    /// 阀门模式设为自动（固件自行决定开/关），写 Valve Mode = 0
    func setValveModeAuto() {
        let data = Data([0])
        writeToCharacteristic(valveCharacteristic, data: data)
        appendLog("阀门模式: 自动 (Valve Mode 写 0)")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            readValveMode()
            readValveState()
        }
    }
    
    /// 电磁阀手动控制：open = true 开，false 关（写 Valve Mode：1=open, 2=closed；GATT 为 1 字节）
    func setValve(open: Bool) {
        let byte: UInt8 = open ? 1 : 2
        let data = Data([byte])
        writeToCharacteristic(valveCharacteristic, data: data)
        appendLog("电磁阀: \(open ? "开" : "关") (Valve Mode 写 \(byte))")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s 后读模式与状态（物理阀可能有延迟）
            readValveMode()
            readValveState()
        }
    }
    
    /// 操作电磁阀前先读取当前状态：若已是目标状态则仅警告一次，否则写入
    func setValveAfterReadingState(open: Bool) {
        valveOperationWarning = nil
        pendingValveSetOpen = open
        readValveState()
    }
    
    /// 读取阀门模式（Valve Mode Read：0=auto, 1=open, 2=closed，与写入同一特征）
    func readValveMode() {
        readCharacteristic(valveCharacteristic)
    }
    
    /// 读取阀门状态（Valve State Read：0 undefined, 1 open, 2 closed，实际状态）
    func readValveState() {
        readCharacteristic(valveStateCharacteristic)
    }
    
    /// 读取关阀压力（00000002，CO2 Pressure when valve is closed）；silent 为 true 时不打日志
    func readPressure(silent: Bool = false) {
        readCharacteristic(pressureCharacteristic)
        if !silent { appendLog("请求读取关阀压力") }
    }
    
    /// 读取开阀压力（00000003，CO2 Pressure when valve is open）；silent 为 true 时不打日志
    func readPressureOpen(silent: Bool = false) {
        readCharacteristic(pressureOpenCharacteristic)
        if !silent { appendLog("请求读取开阀压力") }
    }
    
    /// RTC 测试：向 Schedule Time Write 写入十六进制触发，再从 OTA Testing 特征读取 RTC（7 字节）
    func writeRTCTrigger(hexString: String) {
        guard let data = dataFromHexString(hexString) else {
            appendLog("无效的十六进制: \(hexString)", level: .error)
            errorMessage = "无效的十六进制字符串"
            return
        }
        writeToCharacteristic(rtcCharacteristic, data: data)
        appendLog("已写入 RTC 触发: \(hexString)")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            readCharacteristic(testingCharacteristic)
        }
    }
    
    /// Testing 特征解锁魔数（GattServices.json：Write 一次后可持续 Read 7 字节 RTC）
    private static let testingUnlockMagic: Data = {
        var d = Data(capacity: 4)
        d.append(contentsOf: [0x16, 0xE9, 0x75, 0xD0] as [UInt8]) // 0x16E975D0
        return d
    }()
    
    /// 向 Testing 特征写一次解锁魔数，之后可持续 readRTC() 读取，无需每次写
    func writeTestingUnlock() {
        writeToCharacteristic(testingCharacteristic, data: Self.testingUnlockMagic)
        appendLog("RTC: 已写 Testing 解锁（一次即可）")
    }
    
    /// 读取 RTC：从 OTA Testing 特征读 7 字节（需先调用一次 writeTestingUnlock）
    func readRTC() {
        readCharacteristic(testingCharacteristic)
    }
    
    // MARK: - OTA（逻辑见 Config/OTA_Flow.md）
    
    /// 写 OTA Status：0=abort, 1=start, 2=finished, 3=reboot（仅 abort/reboot 时打日志，避免刷屏）
    func writeOtaStatus(_ value: UInt8) {
        let data = Data([value])
        writeToCharacteristic(otaStatusCharacteristic, data: data)
        if value == 0 {
            appendLog("[OTA] 已写 Status=0 (abort)")
        } else if value == 3 {
            appendLog("[OTA] 已写 Status=3 (reboot)")
        }
    }
    
    /// 写一包 OTA 数据（每包 ≤ 200 字节）
    func writeOtaDataChunk(_ chunk: Data) {
        guard chunk.count <= 200 else {
            appendLog("OTA 单包超过 200 字节，已截断", level: .warning)
            writeToCharacteristic(otaDataCharacteristic, data: chunk.prefix(200))
            return
        }
        otaChunkWriteStartTime = Date()
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
    
    /// OTA 是否处于失败态（启动未确认、校验失败、写失败等），供 UI 显示红色背景
    var isOTAFailed: Bool {
        if case .failed = otaFlowState { return true }
        return false
    }
    
    /// 选择固件文件并保存路径（产测与 Debug 共用，仅此一处调用）；下次打开程序会自动恢复上次选择的固件
    func browseAndSaveFirmware() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            // 无窗口时用 runModal，确保至少能弹出
            runFirmwareOpenPanel(panel: makeFirmwareOpenPanel())
            return
        }

        let panel = makeFirmwareOpenPanel()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            let path = url.path
            UserDefaults.standard.set(path, forKey: Self.otaFirmwarePathKey)
            self.selectedFirmwareURL = url
            self.appendLog("[OTA] 已选择固件: \(url.lastPathComponent)")
            self.appendLog("[OTA] 路径: \(path)")
            self.appendLog("[OTA] 大小: \(self.fileSizeString(for: url))")
        }
    }

    private func makeFirmwareOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "选择固件"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // 按尾缀筛选，默认只显示 .bin 固件
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        if let last = selectedFirmwareURL, last.isFileURL {
            panel.directoryURL = last.deletingLastPathComponent()
        } else if let path = UserDefaults.standard.string(forKey: Self.otaFirmwarePathKey), !path.isEmpty {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty { panel.directoryURL = URL(fileURLWithPath: dir) }
        }
        return panel
    }

    private func runFirmwareOpenPanel(panel: NSOpenPanel) {
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            UserDefaults.standard.set(path, forKey: Self.otaFirmwarePathKey)
            selectedFirmwareURL = url
            appendLog("[OTA] 已选择固件: \(url.lastPathComponent)")
            appendLog("[OTA] 路径: \(path)")
            appendLog("[OTA] 大小: \(fileSizeString(for: url))")
        }
    }
    
    private func fileSizeString(for url: URL) -> String {
        guard let n = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "—" }
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(n / 1024) KB" }
        return String(format: "%.2f MB", Double(n) / (1024 * 1024))
    }
    
    /// 启动 OTA（产测与 Debug 共用，按 GATT 协议：start(1) → 写块 → finished(2) → 轮询 Status → reboot(3) 或 abort(0)）
    func startOTA() {
        guard let url = selectedFirmwareURL else {
            appendLog("[OTA] 请先选择固件", level: .warning)
            return
        }
        guard isConnected else {
            appendLog("[OTA] 请先连接设备", level: .warning)
            return
        }
        guard !isOTAInProgress else {
            appendLog("[OTA] 正在进行中", level: .warning)
            return
        }
        guard isOtaAvailable else {
            appendLog("[OTA] 设备不支持 OTA 或特征未就绪", level: .warning)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            appendLog("[OTA] 无法读取固件文件", level: .error)
            return
        }
        let chunks = stride(from: 0, to: data.count, by: Self.otaChunkSize).map { start in
            let end = min(start + Self.otaChunkSize, data.count)
            return Data(data[start..<end])
        }
        guard !chunks.isEmpty else {
            appendLog("[OTA] 固件为空", level: .error)
            return
        }
        isOTAInProgress = true
        otaProgress = 0
        otaCompletedDuration = nil
        otaStartTime = Date()
        lastLoggedOtaProgressStep = -1
        lastPublishedOtaProgressPercent = -1
        otaChunkWriteStartTime = nil
        otaChunkRttSum = 0
        otaChunkRttCount = 0
        otaFlowState = .waitingStartAck(chunks: chunks)
        appendLog("[OTA] 启动: \(url.lastPathComponent)，共 \(chunks.count) 包")
        writeOtaStatus(1) // start OTA
        appendLog("[OTA] 已写 Status=1 (start)，等待设备确认…")
        readOtaStatus()
        scheduleOtaStartAckTimeout()
    }
    
    /// 取消 OTA：写 Status=0（abort）通知设备，并重置本地状态，可随时调用
    func cancelOTA() {
        guard isOTAInProgress else { return }
        appendLog("[OTA] 用户取消")
        writeOtaStatus(0)
        otaFlowState = .idle
        isOTAInProgress = false
        otaStartTime = nil
    }
    
    /// 启动确认超时：若设备未在时间内返回 Status=1，直接开始发块，确保能进入 OTA 进度
    private func scheduleOtaStartAckTimeout() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.otaStartAckTimeoutNs)
            guard case .waitingStartAck(let chunks) = otaFlowState else { return }
            appendLog("[OTA] 启动确认超时，直接开始发送固件块", level: .warning)
            otaFlowState = .sendingChunks(chunks: chunks, nextChunkIndex: 0)
            writeNextOtaChunkIfNeeded()
        }
    }
    
    /// 在 didWriteValueFor(OTA Data) 成功后调用：仅延时再发下一包或写 finished(2)，不读 OTA Status（提速约 15–30s）
    private func continueOtaAfterChunkWrite() {
        guard case .sendingChunks(let chunks, let idx) = otaFlowState else { return }
        let total = chunks.count
        let progress = Double(idx + 1) / Double(total)
        let percent = min(100, Int(progress * 100))
        // 仅当整数百分比变化时更新 @Published，避免每包触发 SwiftUI 重绘导致 OTA 变慢（约 3000 次 → 约 100 次）
        if percent != lastPublishedOtaProgressPercent {
            lastPublishedOtaProgressPercent = percent
            otaProgress = progress
        }
        let step = Int(progress * 20)
        if step > lastLoggedOtaProgressStep {
            lastLoggedOtaProgressStep = step
            appendLog("[OTA] 进度 \(min(step * 5, 100))%")
        }
        if idx + 1 < total {
            otaFlowState = .sendingChunks(chunks: chunks, nextChunkIndex: idx + 1)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.otaChunkDelayNs)
                writeNextOtaChunkIfNeeded()
            }
        } else {
            lastPublishedOtaProgressPercent = 100
            otaProgress = 1
            if lastLoggedOtaProgressStep < 20 {
                lastLoggedOtaProgressStep = 20
                appendLog("[OTA] 进度 100%")
            }
            if otaChunkRttCount > 0 {
                let avgMs = (otaChunkRttSum / Double(otaChunkRttCount)) * 1000
                appendLog("[OTA] 共 \(otaChunkRttCount) 包，平均 BLE 响应 \(String(format: "%.1f", avgMs)) ms（耗时主要在 BLE 往返）")
            }
            appendLog("[OTA] 固件块已全部发送，写 Status=2 (finished)")
            otaFlowState = .sentFinishedPolling
            writeOtaStatus(2)
            readOtaStatus()
        }
    }
    
    /// 发送当前待发的一包 OTA 数据（仅在 state 为 sendingChunks 且 nextChunkIndex 未越界时写一包）
    private func writeNextOtaChunkIfNeeded() {
        guard case .sendingChunks(let chunks, let idx) = otaFlowState, idx < chunks.count else { return }
        writeOtaDataChunk(chunks[idx])
    }
    
    /// 读到 OTA Status 后调用：waitingStartAck 时仅当 1 才继续；sentFinishedPolling 时 3=reboot、4=abort、2=继续轮询
    private func handleOtaStatusPollResult(_ value: UInt8) {
        switch otaFlowState {
        case .waitingStartAck(let chunks):
            if value == 1 {
                appendLog("[OTA] 设备已确认 Status=1，开始发送固件块")
                otaFlowState = .sendingChunks(chunks: chunks, nextChunkIndex: 0)
                writeNextOtaChunkIfNeeded()
            } else if value == 0 || value == 2 {
                // 设备可能尚未把状态从 0 更新为 1，或处于 2(working)，延时后再读，避免首次读得过早误判为未确认
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.otaChunkDelayNs)
                    readOtaStatus()
                }
            } else {
                appendLog("[OTA] 设备未确认 OTA 启动 (读回 Status=\(value)，期望 1)", level: .error)
                otaFlowState = .failed("device did not ack start (status=\(value))")
                isOTAInProgress = false
                otaStartTime = nil
                writeOtaStatus(0)
            }
        case .sentFinishedPolling:
            switch value {
            case 3:
                appendLog("[OTA] 设备校验通过 (image valid)，写 Status=3 (reboot)")
                otaFlowState = .done
                if let start = otaStartTime {
                    otaCompletedDuration = Date().timeIntervalSince(start)
                }
                isOTAInProgress = false
                otaStartTime = nil
                writeOtaStatus(3)
                appendLog("[OTA] 已发 reboot，设备将重启并断开连接")
            case 4:
                appendLog("[OTA] 设备校验失败 (image fail)", level: .error)
                otaFlowState = .failed("image fail")
                isOTAInProgress = false
                otaStartTime = nil
                writeOtaStatus(0)
            default:
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.otaPollIntervalSeconds)
                    readOtaStatus()
                }
            }
        default:
            break
        }
    }
    
    /// 按当前等级过滤后的日志（供 UI 显示）；过滤掉空行避免勾选 Debug 后出现大块空白
    var displayedLogEntries: [LogEntry] {
        logEntries.filter { entry in
            guard !entry.line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            switch entry.level {
            case .debug: return showLogLevelDebug
            case .info: return showLogLevelInfo
            case .warning: return showLogLevelWarning
            case .error: return showLogLevelError
            }
        }
    }
    
    /// 清空日志
    func clearLog() {
        logEntries.removeAll()
    }
    
    // MARK: - Private Helpers
    
    private func appendLog(_ msg: String, level: LogLevel = .info) {
        let line = "\(formattedTime()) \(msg)"
        logEntries.append(LogEntry(level: level, line: line))
        if logEntries.count > 500 { logEntries.removeFirst() }
    }
    
    private func formattedTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
    
    private func writeToCharacteristic(_ char: CBCharacteristic?, data: Data) {
        guard let peripheral = connectedPeripheral, let char = char else {
            appendLog("[GATT] 未连接或特征不可用，跳过写入", level: .error)
            return
        }
        let isOtaDataWrite = (GattMapping.characteristicKey(for: char.uuid) == GattMapping.Key.otaData)
        if !(isOtaDataWrite && isOTAInProgress) {
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            let alias = GattMapping.characteristicKey(for: char.uuid) ?? String(char.uuid.uuidString.suffix(8))
            let uuidTag = "0x" + char.uuid.uuidString.lowercased()
            appendLog("wr:\(uuidTag): \(alias) : \(hex)", level: .debug)
        }
        peripheral.writeValue(data, for: char, type: .withResponse)
    }
    
    private func readCharacteristic(_ char: CBCharacteristic?) {
        guard let peripheral = connectedPeripheral, let char = char else {
            appendLog("[GATT] 未连接或特征不可用，跳过读取", level: .error)
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
            else if let u = valveStateCBUUID, char.uuid == u { valveStateCharacteristic = char }
            else if let u = pressureReadCBUUID, char.uuid == u { pressureCharacteristic = char }
            else if let u = pressureOpenCBUUID, char.uuid == u { pressureOpenCharacteristic = char }
            else if let u = rtcCBUUID, char.uuid == u { rtcCharacteristic = char }
            else if let u = testingCBUUID, char.uuid == u { testingCharacteristic = char }
            else if let u = otaStatusCBUUID, char.uuid == u { otaStatusCharacteristic = char }
            else if let u = otaDataCBUUID, char.uuid == u { otaDataCharacteristic = char }
        }
        if pressureCharacteristic?.properties.contains(.notify) == true {
            connectedPeripheral?.setNotifyValue(true, for: pressureCharacteristic!)
        }
        if pressureOpenCharacteristic?.properties.contains(.notify) == true {
            connectedPeripheral?.setNotifyValue(true, for: pressureOpenCharacteristic!)
        }
        if !areCharacteristicsReady && (pressureCharacteristic != nil || pressureOpenCharacteristic != nil) && (testingCharacteristic != nil || rtcCharacteristic != nil) {
            areCharacteristicsReady = true
            appendLog("特征就绪，可进行读/写")
            // 连接成功后自动读一次阀门状态与压力
            readValveMode()
            readValveState()
            readPressure(silent: true)
            readPressureOpen(silent: true)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            isPoweredOn = (central.state == .poweredOn)
            if central.state != .poweredOn {
                appendLog("蓝牙状态: \(central.state.description)", level: .warning)
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
            let raw = error?.localizedDescription ?? ""
            appendLog("连接失败: \(raw)", level: .error)
            if BLEManager.isPairingRemovedError(error) {
                errorMessageKey = "error.pairing_removed_hint"
                errorMessage = raw
                appendLog(NSLocalizedString("error.pairing_removed_hint", value: "设备已清除配对信息。请在「系统设置 → 蓝牙」中移除该设备后重试连接。", comment: ""), level: .warning)
                BLEManager.openBluetoothSettings()
            } else {
                errorMessageKey = nil
                errorMessage = raw.isEmpty ? nil : raw
            }
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let wasOTAInProgress = isOTAInProgress
            if let err = error {
                appendLog("已断开: \(err.localizedDescription)")
                if BLEManager.isPairingRemovedError(err) {
                    errorMessageKey = "error.pairing_removed_hint"
                    BLEManager.openBluetoothSettings()
                }
                errorMessage = err.localizedDescription
            } else {
                appendLog("已断开")
                errorMessage = nil
                errorMessageKey = nil
            }
            if wasOTAInProgress {
                appendLog("[OTA] 连接断开，OTA 已中断", level: .warning)
            }
            connectedPeripheral = nil
            valveCharacteristic = nil
            valveStateCharacteristic = nil
            pressureCharacteristic = nil
            pressureOpenCharacteristic = nil
            rtcCharacteristic = nil
            testingCharacteristic = nil
            otaStatusCharacteristic = nil
            otaDataCharacteristic = nil
            isConnected = false
            connectedDeviceName = nil
            areCharacteristicsReady = false
            lastPressureValue = "--"
            lastPressureOpenValue = "--"
            lastRTCValue = "--"
            lastSystemTimeAtRTCRead = "--"
            lastTimeDiffFromRTCRead = "--"
            lastValveStateValue = "--"
            lastValveModeValue = "--"
            valveOperationWarning = nil
            pendingValveSetOpen = nil
            valveStateAuthErrorLogged = false
            currentFirmwareVersion = nil
            deviceSerialNumber = nil
            deviceManufacturer = nil
            deviceModelNumber = nil
            deviceHardwareRevision = nil
            otaFlowState = .idle
            isOTAInProgress = false
            otaStartTime = nil
        }
    }
    
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            Task { @MainActor in appendLog("发现服务失败: \(error!.localizedDescription)", level: .error) }
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
            Task { @MainActor in appendLog("发现特征失败: \(error!.localizedDescription)", level: .error) }
            return
        }
        Task { @MainActor in
            updateCharacteristics(from: service)
            // Device Information 服务：连接成功后自动读 SN、固件版本等
            if service.uuid.uuidString.lowercased() == "0000180a-0000-1000-8000-00805f9b34fb" {
                for char in service.characteristics ?? [] {
                    peripheral.readValue(for: char)
                }
            }
            appendLog("服务与特征就绪")
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let charUuid = characteristic.uuid
        let alias = GattMapping.characteristicKey(for: charUuid) ?? String(charUuid.uuidString.suffix(8))
        let uuidTag = "0x" + charUuid.uuidString.lowercased()
        if let err = error {
            Task { @MainActor in
                if let u = valveStateCBUUID, charUuid == u {
                    lastValveStateValue = "需配对"
                    pendingValveSetOpen = nil
                    if !valveStateAuthErrorLogged {
                        valveStateAuthErrorLogged = true
                        appendLog("rd:\(uuidTag): \(alias) error: \(err.localizedDescription)（阀门状态需加密/配对，仅首次打印）", level: .warning)
                    }
                } else {
                    appendLog("rd:\(uuidTag): \(alias) error: \(err.localizedDescription)", level: .error)
                }
            }
            return
        }
        guard let data = characteristic.value else {
            Task { @MainActor in appendLog("rd:\(uuidTag): \(alias) : value=nil", level: .error) }
            return
        }
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let isOtaStatusRead = (GattMapping.characteristicKey(for: characteristic.uuid) == GattMapping.Key.otaStatus)
        Task { @MainActor in
            if !(isOtaStatusRead && isOTAInProgress) { appendLog("rd:\(uuidTag): \(alias) : \(hex)", level: .debug) }
            if let u = pressureReadCBUUID, characteristic.uuid == u {
                lastPressureValue = formatPressureData(data)
                appendLog("关阀压力: \(lastPressureValue)", level: .debug)
            } else if let u = pressureOpenCBUUID, characteristic.uuid == u {
                lastPressureOpenValue = formatPressureData(data)
                appendLog("开阀压力: \(lastPressureOpenValue)", level: .debug)
            } else if let u = rtcCBUUID, characteristic.uuid == u {
                lastRTCValue = formatRTCData(data)
                updateRTCReadSnapshot(deviceTimeString: lastRTCValue)
                appendLog("RTC: \(lastRTCValue)")
            } else if let u = testingCBUUID, characteristic.uuid == u {
                lastRTCValue = formatRTCData(data)
                updateRTCReadSnapshot(deviceTimeString: lastRTCValue)
                appendLog("RTC raw: \(hex)")
                appendLog("RTC: \(lastRTCValue)")
            } else if let u = gasSystemStatusCBUUID, characteristic.uuid == u {
                appendLog("Gas status: \(formatGasStatusData(data))")
            } else if let u = otaStatusCBUUID, characteristic.uuid == u, let b = data.first {
                lastOtaStatusValue = b
                if !isOTAInProgress { appendLog("OTA Status: \(b)") }
                handleOtaStatusPollResult(b)
            } else if let u = valveControlCBUUID, characteristic.uuid == u, let b = data.first {
                lastValveModeValue = formatValveModeData(b)
                appendLog("阀门模式: \(lastValveModeValue) (0x\(String(format: "%02X", b)))")
            } else if let u = valveStateCBUUID, characteristic.uuid == u, let b = data.first {
                lastValveStateValue = formatValveStateData(b)
                appendLog("阀门状态: \(lastValveStateValue) (0x\(String(format: "%02X", b)))", level: .debug)
                if let wantOpen = pendingValveSetOpen {
                    if wantOpen && lastValveStateValue == "open" {
                        valveOperationWarning = "valve.warning_already_open"
                        appendLog(NSLocalizedString("valve.warning_already_open", value: "当前已是开启状态", comment: ""), level: .warning)
                    } else if !wantOpen && lastValveStateValue == "closed" {
                        valveOperationWarning = "valve.warning_already_closed"
                        appendLog(NSLocalizedString("valve.warning_already_closed", value: "当前已是关闭状态", comment: ""), level: .warning)
                    } else {
                        setValve(open: wantOpen)
                    }
                    pendingValveSetOpen = nil
                }
            } else if characteristic.uuid == BLEManager.charManufacturerUUID || characteristic.uuid == BLEManager.charModelUUID || characteristic.uuid == BLEManager.charSerialUUID || characteristic.uuid == BLEManager.charFirmwareUUID || characteristic.uuid == BLEManager.charHardwareUUID,
                      let str = stringFromDeviceInfoData(data) {
                if characteristic.uuid == BLEManager.charManufacturerUUID {
                    deviceManufacturer = str
                    appendLog("制造商: \(str)")
                } else if characteristic.uuid == BLEManager.charModelUUID {
                    deviceModelNumber = str
                    appendLog("型号: \(str)")
                } else if characteristic.uuid == BLEManager.charSerialUUID {
                    deviceSerialNumber = str
                    appendLog("SN: \(str)")
                } else if characteristic.uuid == BLEManager.charFirmwareUUID {
                    currentFirmwareVersion = str
                    appendLog("FW: \(str)")
                } else {
                    deviceHardwareRevision = str
                    appendLog("硬件版本: \(str)")
                }
            } else {
                appendLog("[GATT] 未识别特征 \(alias)", level: .warning)
            }
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let alias = GattMapping.characteristicKey(for: characteristic.uuid) ?? String(characteristic.uuid.uuidString.suffix(8))
        let uuidTag = "0x" + characteristic.uuid.uuidString.lowercased()
        let isOtaData = (GattMapping.characteristicKey(for: characteristic.uuid) == GattMapping.Key.otaData)
        if let error = error {
            Task { @MainActor in
                appendLog("wr:\(uuidTag): \(alias) 失败: \(error.localizedDescription)", level: .error)
                if isOtaData, case .sendingChunks = otaFlowState {
                    otaFlowState = .failed(error.localizedDescription)
                    isOTAInProgress = false
                    otaStartTime = nil
                }
            }
        } else {
            Task { @MainActor in
                if isOtaData && isOTAInProgress {
                    if let start = otaChunkWriteStartTime {
                        let elapsed = Date().timeIntervalSince(start)
                        otaChunkRttSum += elapsed
                        otaChunkRttCount += 1
                        if otaChunkRttCount % 200 == 0 {
                            let avgMs = (otaChunkRttSum / Double(otaChunkRttCount)) * 1000
                            appendLog("[OTA] 已发 \(otaChunkRttCount) 包，平均 BLE 响应 \(String(format: "%.1f", avgMs)) ms")
                        }
                    }
                    continueOtaAfterChunkWrite()
                } else {
                    if !isOtaData { appendLog("wr:\(uuidTag): \(alias) ok", level: .debug) }
                    if isOtaData { continueOtaAfterChunkWrite() }
                }
            }
        }
    }
    
    /// 解码压力：设备上报为 mbar（2 字节有符号或 4 字节无符号），转换为 bar 显示，保留 3 位小数
    /// 1 bar = 1000 mbar，故 bar = mbar / 1000
    @MainActor private func formatPressureData(_ data: Data) -> String {
        if data.count >= 2 {
            let mbar = Double(data.withUnsafeBytes { $0.load(as: Int16.self) })
            let bar = mbar / 1000.0
            return String(format: "%.3f bar", bar)
        }
        if data.count >= 4 {
            let mbar = Double(data.withUnsafeBytes { $0.load(as: UInt32.self) })
            let bar = mbar / 1000.0
            return String(format: "%.3f bar", bar)
        }
        return "Error: expected 2 or 4 bytes, got \(data.count)"
    }
    
    /// RTC 读取成功时更新「读取时刻系统时间」与「时间差」
    @MainActor private func updateRTCReadSnapshot(deviceTimeString: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_POSIX")
        let now = Date()
        lastSystemTimeAtRTCRead = formatter.string(from: now)
        guard let deviceDate = formatter.date(from: deviceTimeString), deviceTimeString != "--" else {
            lastTimeDiffFromRTCRead = "--"
            return
        }
        let diff = deviceDate.timeIntervalSince(now)
        if abs(diff) < 60 {
            lastTimeDiffFromRTCRead = String(format: "%+.1fs", diff)
        } else if abs(diff) < 3600 {
            lastTimeDiffFromRTCRead = String(format: "%+.1fmin", diff / 60)
        } else {
            lastTimeDiffFromRTCRead = String(format: "%+.1fh", diff / 3600)
        }
    }
    
    /// 解码设备 RTC 时间戳。7 字节顺序为 [秒, 分, 时, 日, 星期, 月, 年]，均为十六进制数值；年=2000+byte6
    @MainActor private func formatRTCData(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if data.count >= 7 {
            let sec = Int(bytes[0])
            let min = Int(bytes[1])
            let hour = Int(bytes[2])
            let day = Int(bytes[3])
            let weekday = Int(bytes[4])
            let month = Int(bytes[5])
            let year = 2000 + Int(bytes[6])
            return String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, min, sec)
        }
        if data.count >= 6 {
            return String(format: "20%02x-%02d-%02d %02d:%02d:%02d",
                          bytes[0], Int(bytes[1]), Int(bytes[2]), Int(bytes[3]), Int(bytes[4]), Int(bytes[5]))
        }
        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    /// Valve State Read: 0 undefined, 1 open, 2 closed
    /// Valve Mode Read：0=auto, 1=open, 2=closed
    @MainActor private func formatValveModeData(_ byte: UInt8) -> String {
        switch byte {
        case 0: return "auto"
        case 1: return "open"
        case 2: return "closed"
        default: return "\(byte)"
        }
    }
    
    /// Valve State Read：0 undefined, 1 open, 2 closed
    @MainActor private func formatValveStateData(_ byte: UInt8) -> String {
        switch byte {
        case 1: return "open"
        case 2: return "closed"
        default: return "undefined"
        }
    }
    
    /// Device Information 特征值为 UTF-8 字符串
    @MainActor private func stringFromDeviceInfoData(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
