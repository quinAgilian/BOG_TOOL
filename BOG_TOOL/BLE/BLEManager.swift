import Foundation
import CoreBluetooth
import Combine
import AppKit
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif

/// 无 actor 隔离的常量，供 CBCentralManager/CBPeripheral 回调（nonisolated）使用
private enum BLEManagerConstants {
    static let deviceInfoServiceUUIDString = "0000180a-0000-1000-8000-00805f9b34fb"
    static let deviceInfoServiceCBUUID = CBUUID(string: "180A")  // 使用短格式，CBUUID 会自动处理
    static var mainAppServiceCBUUIDs: [CBUUID] {
        // 使用 CBUUID 对象比较，可以正确处理短格式和完整格式
        GattMapping.appServiceCBUUIDs.filter { $0 != deviceInfoServiceCBUUID }
    }
}

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
    /// Gas system status（00000001-AEF1-...，读：0 initially closed, 1 ok, 2 leak, 8/9 low gas…）
    @Published var lastGasSystemStatusValue: String = "--"
    /// CO2 Pressure Limits（00000004-AEF1-...，6 个 mbar 值：empty_lo, empty_hi, leak, press_change, press_rise, lglo_leak）
    @Published var lastPressureLimitsValue: String = "--"
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
    /// 从当前选择的固件文件名解析出的版本号（如 1.0.5），供 OTA 区域显示
    var parsedFirmwareVersion: String? {
        guard let url = selectedFirmwareURL else { return nil }
        return BLEManager.parseFirmwareVersion(from: url)
    }
    
    /// 从固件 URL 解析出版本号（供固件管理等复用）；nonisolated 以便在非 MainActor 上下文同步调用
    nonisolated static func parseFirmwareVersion(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.components(separatedBy: "_").filter { Int($0) != nil }
        if parts.count >= 3 { return parts.suffix(3).joined(separator: ".") }
        let (_, fw) = BLEManager.extractFirmwareVersionsStatic(from: name)
        return fw.isEmpty ? nil : fw
    }
    
    /// 静态版本：从版本字符串提取固件号（供 parseFirmwareVersion 等复用）；nonisolated 供 parseFirmwareVersion 调用
    private nonisolated static func extractFirmwareVersionsStatic(from versionString: String) -> (bootloader: String, firmware: String) {
        let nsString = versionString as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let pattern1 = #"(\d+)_(\d+\.\d+\.\d+)"#
        if let regex1 = try? NSRegularExpression(pattern: pattern1, options: []),
           let match = regex1.firstMatch(in: versionString, options: [], range: range),
           match.numberOfRanges >= 3 {
            let bootloaderRange = match.range(at: 1)
            let firmwareRange = match.range(at: 2)
            if bootloaderRange.location != NSNotFound, firmwareRange.location != NSNotFound {
                return (nsString.substring(with: bootloaderRange), nsString.substring(with: firmwareRange))
            }
        }
        let pattern2 = #"(\d+)_(\d+)_(\d+)_(\d+)"#
        if let regex2 = try? NSRegularExpression(pattern: pattern2, options: []),
           let match = regex2.firstMatch(in: versionString, options: [], range: range),
           match.numberOfRanges >= 5 {
            let bootloader = match.range(at: 1).location != NSNotFound ? nsString.substring(with: match.range(at: 1)) : versionString
            let fw1 = nsString.substring(with: match.range(at: 2))
            let fw2 = nsString.substring(with: match.range(at: 3))
            let fw3 = nsString.substring(with: match.range(at: 4))
            return (bootloader, "\(fw1).\(fw2).\(fw3)")
        }
        return (versionString, versionString)
    }
    /// OTA 进度 0...1
    @Published var otaProgress: Double = 0
    /// OTA 是否进行中
    @Published var isOTAInProgress: Bool = false
    /// 当前 OTA 是否由产测触发（用于 Debug 区不随动、仅产测界面管理）
    @Published var otaInitiatedByProductionTest: Bool = false
    /// 产测 OTA 下是否已收到设备返回的 OTA Status 1（用于弹窗在「OTA Status: 1」后再显示）
    @Published var otaStatus1ReceivedFromDevice: Bool = false
    /// OTA 是否在等待设备校验（进度100%但等待Status=3/4）
    @Published var isOTAWaitingValidation: Bool = false
    /// OTA 是否已完成并等待用户确认重启（Status=3确认后，等待用户点击 Reboot 按钮）
    @Published var isOTACompletedWaitingReboot: Bool = false
    /// 是否期待因 reboot 导致的连接断开（发送 reboot 后设置为 true，断开后检查）
    private var isExpectingDisconnectFromReboot: Bool = false
    /// 发送 reboot 的时间戳（用于超时检测）
    private var rebootSentTime: Date?
    /// reboot 断开超时时间（秒），超过此时间未断开则提示异常
    private static let rebootDisconnectTimeoutSeconds: TimeInterval = 30.0
    /// OTA 完成后是否因 reboot 正常断开（用于 UI 显示友好提示）
    @Published var isOTARebootDisconnected: Bool = false
    /// 当前 OTA 目标固件总字节数（用于进度行显示传输速率与剩余时间），开始 OTA 时设置，结束/取消/断开时清空
    @Published var otaFirmwareTotalBytes: Int?
    /// 单次 OTA 开始时间（用于显示已用/剩余时间），结束时置 nil
    @Published var otaStartTime: Date?
    /// OTA 未启动原因（startOTA 提前返回时设置，产测可读取并写入产测日志；成功启动后清空）
    @Published var lastOTARejectReason: String?
    /// OTA 流程内部标记：进入发送固件前置位，用于状态机校验
    private var otaMarkerSet: Bool = false
    /// OTA 成功完成时的耗时（秒），用于完成后在状态/标题显示
    @Published var otaCompletedDuration: TimeInterval?
    /// 当前设备固件版本（连接后从 Device Information 读取）
    @Published var currentFirmwareVersion: String?
    /// 当前设备 Bootloader 版本（连接后从 Device Information 读取）
    @Published var bootloaderVersion: String?
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
    /// OTA 进度单行刷新（\r 式）：进行中只显示这一行并原地更新，内容与 OTA 弹窗关键信息一致（进度% 已用 速率 剩余）
    @Published var otaProgressLogLine: String?
    /// 是否在日志区域显示对应等级（勾选则显示）
    @Published var showLogLevelDebug = true
    @Published var showLogLevelInfo = true
    @Published var showLogLevelWarning = true
    @Published var showLogLevelError = true
    @Published var errorMessage: String?
    /// 若为配对已清除等已知错误，存 key（由 UI 按当前语言显示）；否则 errorMessage 为系统原始文案
    @Published var errorMessageKey: String?
    /// 蓝牙权限/配对提示结束时间（非 nil 时 UI 显示「请同意权限…」横幅并 30 秒倒计时）
    @Published var blePermissionPromptEndTime: Date?
    /// 是否正在等待用户同意加密/配对（连接后读加密特征失败，每 200ms 轮询直到成功或断开）
    @Published var bleEncryptionProbeWaiting: Bool = false
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
    /// 当前在设备列表中选中的设备 ID（与 DeviceListView / DebugModeView 同步）
    @Published var selectedDeviceId: UUID? = nil
    /// 是否已成功读取过 RTC（用于 Write RTC 按钮可用性）
    var hasRTCRetrievedSuccessfully: Bool { !lastRTCValue.isEmpty && lastRTCValue != "--" }
    
    /// 调试用：最近一次按 UUID 读取的结果（UUID、hex、原始 Data），用于 UUIDDebugView 显示 hex + 解码
    @Published var lastDebugReadUUID: String?
    @Published var lastDebugReadHex: String?
    @Published var lastDebugReadData: Data?
    
    // MARK: - Internal
    private var centralManager: CBCentralManager!
    private var hasAutoStartedScan = false
    private var connectedPeripheral: CBPeripheral?
    private var valveCharacteristic: CBCharacteristic?
    private var valveStateCharacteristic: CBCharacteristic?
    private var pressureCharacteristic: CBCharacteristic?
    private var pressureOpenCharacteristic: CBCharacteristic?
    private var gasSystemStatusCharacteristic: CBCharacteristic?
    private var pressureLimitsCharacteristic: CBCharacteristic?
    private var rtcCharacteristic: CBCharacteristic?
    private var testingCharacteristic: CBCharacteristic?
    private var otaStatusCharacteristic: CBCharacteristic?
    private var otaDataCharacteristic: CBCharacteristic?
    /// 调试用：当前等待读取回调的特征 UUID，用于将 didUpdateValueFor 结果交给 UUIDDebugView
    private var pendingDebugReadUUID: String?
    
    private var valveControlCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.valveControl) }
    private var valveStateCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.valveState) }
    private var pressureReadCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.pressureRead) }
    private var pressureOpenCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.pressureOpen) }
    private var rtcCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.rtc) }
    private var testingCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.testing) }
    private var gasSystemStatusCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.gasSystemStatus) }
    private var co2PressureLimitsCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.co2PressureLimits) }
    private var otaStatusCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.otaStatus) }
    private var otaDataCBUUID: CBUUID? { GattMapping.characteristicUUID(forKey: GattMapping.Key.otaData) }
    
    private static let otaFirmwarePathKey = "ota.selectedFirmwarePath"
    private static let otaFirmwareBookmarkKey = "ota.selectedFirmwareBookmark"
    /// 通过书签恢复的固件 URL，已调用 startAccessingSecurityScopedResource，更换选择时需 stop
    private var securityScopedFirmwareURL: URL?
    /// OTA 流程状态机：读状态确保为0（如不是0则发送abort并等待） → 写 start(1) → 等设备返回 1（Status=2时继续轮询）→ 发块（每包仅写+延时，不读 Status）→ 写 finished(2) → 轮询 3/4
    private enum OTAFlowState {
        case idle
        /// 启动前检查：读取设备状态，确保为 0（OTA not started）才能开始
        case checkingInitialState(chunks: [Data])
        /// 启动前发现状态不是0，已发送abort，等待设备状态恢复为0（最多等待5s）
        case abortingAndWaitingForIdle(chunks: [Data], abortStartTime: Date)
        /// 已写 start(1)，等待设备读回 Status=1 再发块（Status=2时继续轮询等待，最多重试3次，Status=2轮询最多1s超时）
        case waitingStartAck(chunks: [Data], retryCount: Int, status2PollStartTime: Date?)
        /// 正在写固件块，nextChunkIndex 为下一包下标（每包写成功后仅延时再发下一包，不读 OTA Status）
        case sendingChunks(chunks: [Data], nextChunkIndex: Int)
        /// 已写 finished(2)，轮询读 OTA Status 直到 3 或 4
        case sentFinishedPolling
        case done
        case failed(String)
        case cancelled // 用户手动取消
    }
    private var otaFlowState: OTAFlowState = .idle
    private static let otaChunkSize = 200
    /// 每包写成功后、发下一包前的延时（纳秒）；10ms 给设备留处理时间，确保设备有足够时间处理上一包
    /// 实际测量：平均 BLE 响应时间约 42.2ms，但测试发现 5ms 延时反而变慢（3分54秒 vs 3分21秒）
    /// 说明设备需要足够的缓冲时间来处理数据，10ms 是最优值
    /// 如果包间延时太小，可能导致设备处理不过来、重传或协议栈问题
    private static let otaChunkDelayNs: UInt64 = 10_000_000 // 10 ms（实际测试最优值，5ms 反而变慢）
    /// 启动前发送 abort 后等待设备状态恢复为 0 的超时时间（秒）
    private static let otaAbortWaitTimeoutSeconds: TimeInterval = 5.0
    /// OTA 专用高优先级队列：用于 OTA 数据传输的延时和状态检查，提高 CPU 调度优先级
    /// macOS 不能完全独占一个 CPU 核心，但可以通过设置高 QoS 和线程优先级来获得更多 CPU 时间
    private static let otaQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.bogtool.ota", qos: .userInteractive, attributes: [])
        // 在队列上设置线程优先级（首次使用时设置）
        queue.async {
            #if canImport(Darwin)
            // 设置线程 QoS 为最高优先级（userInteractive）
            // pthread_set_qos_class_self_np 直接接受 qos_class_t 常量
            let result = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            if result == 0 {
                // 可选：设置线程名称，便于调试
                pthread_setname_np("BOG-OTA-HighPriority")
            }
            #endif
        }
        return queue
    }()
    
    /// 在高优先级队列上执行延时，然后切换回主线程执行后续操作。
    /// 每次在「当前执行延时的线程」上设置 QoS 再 sleep；用 DispatchQueue.main.async 回主线程，避免 Task { @MainActor in } 与主线程上大量任务争抢导致 continuation 被推迟数秒、OTA 速率骤降。
    /// - Parameters:
    ///   - nanoseconds: 延时时间（纳秒）
    ///   - continuation: 延时后执行的闭包（在主线程上执行）
    private func performOtaDelayThenContinue(nanoseconds: UInt64, continuation: @escaping @MainActor () -> Void) {
        Self.otaQueue.async {
            #if canImport(Darwin)
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            pthread_setname_np("BOG-OTA-Delay")
            #endif
            Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000.0)
            DispatchQueue.main.async(qos: .userInteractive) {
                continuation()
            }
        }
    }
    /// 每包 OTA 写入开始时间（用于统计 BLE 响应耗时）
    private var otaChunkWriteStartTime: Date?
    /// 累计 BLE 写响应耗时（秒），用于日志统计
    private var otaChunkRttSum: TimeInterval = 0
    private var otaChunkRttCount: Int = 0
    /// 连接参数变化监控：记录连接后的响应时间变化，用于推断设备是否更新了连接间隔
    private var connectionStartTime: Date?
    private var initialRttSamples: [TimeInterval] = []
    private static let initialRttSampleCount = 10 // 记录前10个包的响应时间作为基准
    /// 轮询 OTA Status 间隔（纳秒）
    private static let otaPollIntervalSeconds: UInt64 = 400_000_000 // 0.4s
    /// 启动确认重试间隔（纳秒），每次读 Status 后等待此时间再重试
    private static let otaStartAckRetryIntervalNs: UInt64 = 1_000_000_000 // 1s
    /// 启动确认最大重试次数（必须确认成功才发送数据）
    private static let otaStartAckMaxRetries = 3
    /// 等待设备校验完成（Status=3/4）的超时时间（纳秒），超时后自动关闭弹窗
    private static let otaValidationTimeoutNs: UInt64 = 60_000_000_000 // 60s
    /// 开始等待设备校验的时间（写入 finished(2) 后）
    private var otaValidationStartTime: Date?
    /// 阀门状态读「认证不足」已打过一次日志，避免每轮询一次刷屏
    private var valveStateAuthErrorLogged = false
    /// 先读再设：读完后若已是目标状态则仅警告，否则写入。nil = 无待处理
    private var pendingValveSetOpen: Bool?
    /// OTA 数据包确认（读到 image valid）后是否自动发送 reboot 命令；由 UI 复选框控制
    @Published var autoSendRebootAfterOTA: Bool = true
    
    /// Device Information 服务与特征 UUID（标准 GATT）；连接且主 GATT 就绪后再单独发现并读取
    private static let deviceInfoServiceUUID = BLEManagerConstants.deviceInfoServiceCBUUID
    private static var deviceInfoServiceUUIDString: String { BLEManagerConstants.deviceInfoServiceUUIDString }
    /// 主业务服务（不含 180A），连接后先发现这些；Device Info 在主特征就绪后再发现
    private static var mainAppServiceCBUUIDs: [CBUUID] { BLEManagerConstants.mainAppServiceCBUUIDs }
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
        // 优先用安全作用域书签恢复（沙盒下重启后仍可访问）
        if let data = UserDefaults.standard.data(forKey: Self.otaFirmwareBookmarkKey) {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
                  url.startAccessingSecurityScopedResource() else {
                UserDefaults.standard.removeObject(forKey: Self.otaFirmwareBookmarkKey)
                return
            }
            selectedFirmwareURL = url
            securityScopedFirmwareURL = url
            if isStale, let newData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(newData, forKey: Self.otaFirmwareBookmarkKey)
            }
            return
        }
        // 兼容旧版：仅存了路径；重启后沙盒可能无法访问，仅当文件存在时恢复
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
        // 尝试请求更小的连接间隔以提升OTA速度（注意：macOS/iOS可能不会接受此请求，连接间隔主要由设备端决定）
        // Connection Interval: 7.5ms (0x0006), Latency: 0, Timeout: 5000ms
        let options: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            // 注意：以下参数可能不会生效，连接间隔主要由设备端（Peripheral）决定
            // 设备端可以通过 L2CAP Connection Parameter Update Request 请求更小的间隔
        ]
        centralManager.connect(device.peripheral, options: options)
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
    
    /// 是否为「加密或认证不足」类错误（需用户在系统弹窗中允许）
    private static func isEncryptionOrAuthInsufficientError(_ error: Error?) -> Bool {
        guard let msg = error?.localizedDescription else { return false }
        let lower = msg.lowercased()
        return lower.contains("encryption is insufficient") || lower.contains("encryption insufficient")
            || lower.contains("authentication is insufficient") || lower.contains("authentication insufficient")
    }
    
    /// 触发「请同意蓝牙权限/配对」提示并开始 30 秒倒计时（连接失败配对已清除、或读写 Encryption is insufficient 时调用）
    private func showBlePermissionPromptAndSchedule30s() {
        let endTime = Date().addingTimeInterval(30)
        blePermissionPromptEndTime = endTime
        appendLog(NSLocalizedString("ble.permission_prompt_wait_30s", value: "请同意蓝牙配对/权限（若已出现弹窗请点击允许）；若为「设备已清除配对」请在系统设置→蓝牙中移除该设备后重试。等待 30 秒…", comment: ""), level: .warning)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if blePermissionPromptEndTime == endTime {
                blePermissionPromptEndTime = nil
                appendLog(NSLocalizedString("ble.permission_prompt_ended", value: "等待 30 秒结束，请重试连接或当前操作。", comment: ""), level: .info)
            }
        }
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
    
    /// 读取 Gas system status（00000001-AEF1-...）；silent 为 true 时不打日志
    func readGasSystemStatus(silent: Bool = false) {
        readCharacteristic(gasSystemStatusCharacteristic)
        if !silent { appendLog("请求读取 Gas system status") }
    }
    
    /// 读取 CO2 Pressure Limits（00000004-AEF1-...，6×mbar）；silent 为 true 时不打日志
    func readPressureLimits(silent: Bool = false) {
        readCharacteristic(pressureLimitsCharacteristic)
        if !silent { appendLog("请求读取 CO2 Pressure Limits") }
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
    
    /// 向 Testing 特征写一次解锁魔数，之后可持续 readRTC() 读取，无需每次写。调用前需确保已连接且 GATT 特征已发现（产测/调试应先等 areCharacteristicsReady）。
    func writeTestingUnlock() {
        guard let peripheral = connectedPeripheral, let char = testingCharacteristic else {
            appendLog("RTC: 无法解锁 — 未连接或 Testing 特征未发现，请等待 GATT 就绪后再读 RTC", level: .error)
            return
        }
        writeToCharacteristic(char, data: Self.testingUnlockMagic)
        appendLog("RTC: 已写 Testing 解锁")
    }
    
    /// 清除 RTC 读取状态（产测/调试在发起新一次读取前调用，避免误用旧值或误判超时）
    func clearRTCReadState() {
        lastRTCValue = "--"
        lastSystemTimeAtRTCRead = "--"
        lastTimeDiffFromRTCRead = "--"
    }
    
    /// 读取 RTC：从 OTA Testing 特征读 7 字节（需先调用一次 writeTestingUnlock）
    func readRTC() {
        readCharacteristic(testingCharacteristic)
    }
    
    /// 与 Debug 模式一致的 RTC 读取流程：先解锁、短延时后再读，产测与 Debug 共用，避免产测超时
    func readRTCWithUnlock() {
        writeTestingUnlock()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s，给设备处理解锁的时间
            readRTC()
        }
    }
    
    /// 将当前系统时间写入设备 RTC（7 字节：秒、分、时、日、星期、月、年-2000），然后触发读取验证
    func writeRTCTime() {
        let cal = Calendar.current
        let now = Date()
        let sec = UInt8(cal.component(.second, from: now))
        let minute = UInt8(cal.component(.minute, from: now))
        let hour = UInt8(cal.component(.hour, from: now))
        let day = UInt8(cal.component(.day, from: now))
        let weekday = UInt8(cal.component(.weekday, from: now)) // 1=Sun ... 7=Sat
        let month = UInt8(cal.component(.month, from: now))
        let year = cal.component(.year, from: now)
        let yearByte = UInt8(Swift.max(0, Swift.min(255, year - 2000)))
        let data = Data([sec, minute, hour, day, weekday, month, yearByte])
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let rtcWriteFormatter = DateFormatter()
        rtcWriteFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        appendLog("RTC 写入: \(rtcWriteFormatter.string(from: now))", level: .info)
        writeRTCTrigger(hexString: hexString)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            readRTC()
        }
    }
    
    // MARK: - OTA（逻辑见 Config/OTA_Flow.md）
    
    /// 写 OTA Status：0=abort, 1=start, 2=finished, 3=reboot（所有状态都打印日志，writeToCharacteristic 也会打印）
    func writeOtaStatus(_ value: UInt8) {
        let data = Data([value])
        let statusNames: [UInt8: String] = [0: "abort", 1: "start", 2: "finished", 3: "reboot"]
        let statusName = statusNames[value] ?? "unknown"
        appendLog("[OTA] 已写 Status=\(value) (\(statusName))")
        writeToCharacteristic(otaStatusCharacteristic, data: data)
    }
    
    /// 发送 reboot 指令（写 OTA Status=3）；用户点击 Reboot 按钮时调用
    func sendReboot() {
        guard isOTACompletedWaitingReboot else { return }
        isOTACompletedWaitingReboot = false
        isOTAFailed = false
        isOTACancelled = false
        isOTARebootDisconnected = false
        
        // 设置期待断开标记和时间戳
        isExpectingDisconnectFromReboot = true
        rebootSentTime = Date()
        
        writeOtaStatus(3)
        appendLog("[OTA] 已发送 reboot，设备将重启并断开连接（正常现象）")
        
        // 启动超时检测任务
        scheduleRebootDisconnectTimeout()
        
        // 清除时间和进度（但保留状态标记，等待断开）
        otaStartTime = nil
        otaFirmwareTotalBytes = nil
    }
    
    /// 启动 reboot 断开超时检测：如果发送 reboot 后 30 秒内未断开，提示异常
    private func scheduleRebootDisconnectTimeout() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.rebootDisconnectTimeoutSeconds * 1_000_000_000))
            
            // 检查是否仍然期待断开但未断开
            if isExpectingDisconnectFromReboot && isConnected {
                appendLog("[OTA] 警告：发送 reboot 后 \(Int(Self.rebootDisconnectTimeoutSeconds)) 秒内设备未断开连接", level: .warning)
                appendLog("[OTA] 设备可能未响应重启命令，请检查设备状态", level: .warning)
                // 清除期待断开标记，允许用户手动处理
                isExpectingDisconnectFromReboot = false
                rebootSentTime = nil
            }
        }
    }
    
    /// 清除OTA失败/取消状态（用于关闭弹窗）
    func clearOTAStatus() {
        otaFlowState = .idle
        otaInitiatedByProductionTest = false
        otaStatus1ReceivedFromDevice = false
        isOTAFailed = false
        isOTACancelled = false
        isOTAWaitingValidation = false
        isOTACompletedWaitingReboot = false
        isOTAInProgress = false
        isOTARebootDisconnected = false
        isExpectingDisconnectFromReboot = false
        rebootSentTime = nil
        otaStartTime = nil
        otaFirmwareTotalBytes = nil
        otaProgress = 0
        otaCompletedDuration = nil
        otaValidationStartTime = nil
    }
    
    /// 播放声音提醒用户需要操作（OTA 完成等待重启时）
    private func playRebootCountdownSound() {
        // 使用系统默认提示音
        NSSound.beep()
    }
    
    /// 写一包 OTA 数据（每包 ≤ 200 字节）
    /// 使用 writeWithResponse 确保可靠性，等待设备确认后再发送下一包
    func writeOtaDataChunk(_ chunk: Data) {
        guard chunk.count <= 200 else {
            appendLog("OTA 单包超过 200 字节，已截断", level: .warning)
            writeToCharacteristic(otaDataCharacteristic, data: chunk.prefix(200))
            return
        }
        otaChunkWriteStartTime = Date()
        writeToCharacteristic(otaDataCharacteristic, data: chunk)
        // writeWithResponse 会在 didWriteValueFor 回调中继续发送下一包
    }
    
    /// 读 OTA Status（结果在 didUpdateValueFor 中，可扩展 lastOtaStatusValue）
    func readOtaStatus() {
        readCharacteristic(otaStatusCharacteristic)
    }
    
    /// OTA 特征是否就绪（用于 UI 判断是否显示 OTA 入口）
    var isOtaAvailable: Bool {
        otaStatusCharacteristic != nil && otaDataCharacteristic != nil
    }
    
    /// OTA 每包字节数（供产测 OTA 区域显示数据包大小）
    var otaChunkSizeBytes: Int { 200 }
    
    /// OTA 是否处于失败态（启动未确认、校验失败、写失败等），供 UI 显示红色背景
    @Published var isOTAFailed: Bool = false
    
    /// OTA 是否被用户取消，供 UI 显示取消状态
    @Published var isOTACancelled: Bool = false
    
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
            self.applySelectedFirmwareURL(url)
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
            applySelectedFirmwareURL(url)
        }
    }

    /// 设置当前目标固件（固件管理下拉选择或产测按版本解析后调用）；释放旧的安全作用域、保存书签、更新 selectedFirmwareURL
    func selectFirmware(url: URL) {
        applySelectedFirmwareURL(url)
    }
    
    /// 应用用户选择的固件 URL：释放旧的安全作用域、对新 URL 申请安全作用域（来自固件管理/书签的必须）、保存书签、更新 selectedFirmwareURL
    private func applySelectedFirmwareURL(_ url: URL) {
        let isNewSelection = (selectedFirmwareURL != url)
        if let old = securityScopedFirmwareURL {
            old.stopAccessingSecurityScopedResource()
            securityScopedFirmwareURL = nil
        }
        // 来自固件管理或 NSOpenPanel 的 URL 需申请安全作用域，否则 Data(contentsOf:) 会失败
        if url.startAccessingSecurityScopedResource() {
            securityScopedFirmwareURL = url
        }
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.otaFirmwareBookmarkKey)
        }
        UserDefaults.standard.removeObject(forKey: Self.otaFirmwarePathKey)
        selectedFirmwareURL = url
        // 仅当用户真正切换了固件时打日志，避免切 tab / onAppear 复选同一固件时刷屏
        if isNewSelection {
            appendLog("[OTA] 已选择固件: \(url.lastPathComponent)")
            appendLog("[OTA] 路径: \(url.path)")
            appendLog("[OTA] 大小: \(fileSizeString(for: url))")
        }
    }
    
    private func fileSizeString(for url: URL) -> String {
        guard let n = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "—" }
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(n / 1024) KB" }
        return String(format: "%.2f MB", Double(n) / (1024 * 1024))
    }
    
    /// 当前选择固件的大小字符串（供 OTA 区域显示目标固件大小）
    var selectedFirmwareSizeDisplay: String {
        guard let url = selectedFirmwareURL else { return "—" }
        return fileSizeString(for: url)
    }
    
    /// 启动 OTA：仅负责执行。调用方在调用前应确认固件存在，并直接传入升级包 URL；本方法内会先校验可读性，失败则立即返回。
    /// - Parameters:
    ///   - firmwareURL: 升级包文件 URL（产测从固件管理解析、Debug 为已选固件；书签/外部路径需安全作用域，本方法内会申请）
    ///   - initiatedByProductionTest: 是否由产测触发（产测传 true，Debug 传 false；用于谁调用谁管理，Debug 区不随动）
    /// - Returns: 若未启动则返回原因字符串；若已启动则返回 nil。产测/调用方请用返回值判断，避免依赖 lastOTARejectReason 时序。
    /// 执行中通过 isOTAInProgress / otaProgress / lastOTARejectReason 等实时上报状态；取消请调用 cancelOTA()。
    func startOTA(firmwareURL: URL, initiatedByProductionTest: Bool = false) -> String? {
        lastOTARejectReason = nil
        guard isConnected else {
            let reason = "请先连接设备"
            lastOTARejectReason = reason
            appendLog("[OTA] 请先连接设备", level: .warning)
            return reason
        }
        guard !isOTAInProgress else {
            let reason = "OTA 正在进行中"
            lastOTARejectReason = reason
            appendLog("[OTA] 正在进行中", level: .warning)
            return reason
        }
        guard isOtaAvailable else {
            let reason = "设备不支持 OTA 或特征未就绪"
            lastOTARejectReason = reason
            appendLog("[OTA] 设备不支持 OTA 或特征未就绪", level: .warning)
            return reason
        }
        // 先校验固件可读：申请安全作用域后读取，失败则立即返回
        if securityScopedFirmwareURL != firmwareURL {
            if firmwareURL.startAccessingSecurityScopedResource() {
                if let old = securityScopedFirmwareURL {
                    old.stopAccessingSecurityScopedResource()
                }
                securityScopedFirmwareURL = firmwareURL
            }
        }
        let data: Data
        do {
            data = try Data(contentsOf: firmwareURL)
        } catch {
            let reason = "无法读取固件文件: \(error.localizedDescription)"
            lastOTARejectReason = reason
            appendLog("[OTA] 无法读取固件文件: \(firmwareURL.path) — \(error.localizedDescription)", level: .error)
            return reason
        }
        selectedFirmwareURL = firmwareURL
        let chunks = stride(from: 0, to: data.count, by: Self.otaChunkSize).map { start in
            let end = min(start + Self.otaChunkSize, data.count)
            return Data(data[start..<end])
        }
        guard !chunks.isEmpty else {
            let reason = "固件为空"
            lastOTARejectReason = reason
            appendLog("[OTA] 固件为空", level: .error)
            return reason
        }
        lastOTARejectReason = nil
        otaMarkerSet = true
        otaInitiatedByProductionTest = initiatedByProductionTest
        isOTAInProgress = true
        isOTAFailed = false // 重置失败状态
        isOTACancelled = false // 重置取消状态
        isOTAWaitingValidation = false // 重置等待校验状态
        isOTACompletedWaitingReboot = false
        isOTARebootDisconnected = false
        isExpectingDisconnectFromReboot = false
        rebootSentTime = nil
        otaProgress = 0
        otaProgressLogLine = nil
        otaCompletedDuration = nil
        otaStartTime = nil  // 在收到设备 status=1 后再开始计时，启动数据包传输之前的时间不计入
        otaFirmwareTotalBytes = data.count
        otaChunkWriteStartTime = nil
        otaChunkRttSum = 0
        otaChunkRttCount = 0
        // 重置连接参数监控
        connectionStartTime = Date()
        initialRttSamples.removeAll()
        otaValidationStartTime = nil
        // 先检查设备初始状态，确保为 0（OTA not started）才能开始
        otaFlowState = .checkingInitialState(chunks: chunks)
        
        // 打印 OTA 启动参数（debug 级别）
        let firmwareSizeBytes = data.count
        let firmwareSizeKB = Double(firmwareSizeBytes) / 1024.0
        let totalChunks = chunks.count
        let chunkSizeBytes = Self.otaChunkSize
        let chunkDelayMs = Double(Self.otaChunkDelayNs) / 1_000_000.0
        var mtuInfo = "N/A"
        if let peripheral = connectedPeripheral, #available(macOS 10.13, *) {
            let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
            mtuInfo = "\(mtu) bytes"
        }
        // 理论时间估算：基于每包约 64ms（BLE响应42ms + 延时10ms + 其他12ms）
        let estimatedTimeSeconds = Double(totalChunks) * 0.064
        let estimatedMinutes = Int(estimatedTimeSeconds) / 60
        let estimatedSeconds = Int(estimatedTimeSeconds) % 60
        
        appendLog("[OTA] 启动: \(firmwareURL.lastPathComponent)，共 \(chunks.count) 包", level: .info)
        appendLog("[OTA] 参数详情:", level: .debug)
        appendLog("  - 固件文件: \(firmwareURL.lastPathComponent)", level: .debug)
        appendLog("  - 固件大小: \(firmwareSizeBytes) bytes (\(String(format: "%.2f", firmwareSizeKB)) KB)", level: .debug)
        appendLog("  - 总包数: \(totalChunks)", level: .debug)
        appendLog("  - 每包大小: \(chunkSizeBytes) bytes", level: .debug)
        appendLog("  - 包间延时: \(String(format: "%.1f", chunkDelayMs)) ms", level: .debug)
        appendLog("  - MTU (最大写入长度): \(mtuInfo)", level: .debug)
        appendLog("  - 预计时间: 约 \(estimatedMinutes)分\(estimatedSeconds)秒（理论估算）", level: .debug)
        appendLog("[OTA] 先检查设备状态，确保为 0（OTA not started）…")
        readOtaStatus()
        return nil
    }
    
    /// Debug 用：使用当前已选固件 URL 启动 OTA，等价于 startOTA(firmwareURL: selectedFirmwareURL!, initiatedByProductionTest: false)
    /// - Returns: 若未启动则返回原因，否则 nil。
    func startOTA() -> String? {
        guard let url = selectedFirmwareURL else {
            let reason = "请先选择固件"
            lastOTARejectReason = reason
            appendLog("[OTA] 请先选择固件", level: .warning)
            return reason
        }
        return startOTA(firmwareURL: url, initiatedByProductionTest: false)
    }
    
    /// 统一的 OTA 错误清理方法：发送 abort (Status=0) 并重置本地状态，确保设备下次可以正常进入 OTA
    /// - Parameter reason: 失败原因（如果为 nil，则标记为取消状态）
    private func abortOtaAndCleanup(reason: String?) {
        // 发送 abort 命令，确保设备状态被重置
        writeOtaStatus(0)
        
        if let reason = reason {
            // 失败状态
            otaFlowState = .failed(reason)
            isOTAFailed = true
            isOTACancelled = false
        } else {
            // 取消状态
            otaFlowState = .cancelled
            isOTAFailed = false
            isOTACancelled = true
        }
        
        // 重置所有 OTA 相关状态
        otaInitiatedByProductionTest = false
        isOTAWaitingValidation = false
        isOTACompletedWaitingReboot = false
        isOTAInProgress = false
        isOTARebootDisconnected = false
        isExpectingDisconnectFromReboot = false
        rebootSentTime = nil
        otaValidationStartTime = nil
        otaProgressLogLine = nil
        otaMarkerSet = false
        
        // 失败时清除时间和进度，取消时保留以便UI显示
        if reason != nil {
            otaStartTime = nil
            otaFirmwareTotalBytes = nil
        }
    }
    
    /// 取消 OTA：写 Status=0（abort）通知设备，并重置本地状态，可随时调用
    func cancelOTA() {
        guard isOTAInProgress else { return }
        appendLog("[OTA] 用户取消", level: .warning)
        abortOtaAndCleanup(reason: nil)
    }
    
    /// 启动确认重试：如果读到的 Status 不是 1，等待后重试（最多3次）
    private func retryStartAckIfNeeded() {
        guard case .waitingStartAck(let chunks, let retryCount, _) = otaFlowState else { return }
        guard retryCount < Self.otaStartAckMaxRetries else {
            // 已重试3次都失败，标记为失败
            appendLog("[OTA] 启动确认失败：已重试\(Self.otaStartAckMaxRetries)次，设备未确认 Status=1", level: .error)
            abortOtaAndCleanup(reason: "device did not ack start after \(Self.otaStartAckMaxRetries) retries")
            return
        }
        // 重试：等待后再次读取 Status
        appendLog("[OTA] 启动确认重试 \(retryCount + 1)/\(Self.otaStartAckMaxRetries)…", level: .debug)
        otaFlowState = .waitingStartAck(chunks: chunks, retryCount: retryCount + 1, status2PollStartTime: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.otaStartAckRetryIntervalNs)
            readOtaStatus()
        }
    }
    
    /// 校验超时：若设备在60秒内未返回 Status=3/4，自动关闭弹窗（设备可能已重启或校验时间较长）
    private func scheduleOtaValidationTimeout() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.otaValidationTimeoutNs)
            guard case .sentFinishedPolling = otaFlowState else { return }
            appendLog("[OTA] 校验超时（60秒），设备可能已重启或仍在校验中，自动关闭弹窗", level: .warning)
            // 超时后自动关闭弹窗，但保持状态为完成（假设成功）
            otaFlowState = .done
            isOTAFailed = false
            isOTACancelled = false
            otaInitiatedByProductionTest = false
            isOTAWaitingValidation = false // 清除等待校验状态
            isOTACompletedWaitingReboot = false
            isOTAInProgress = false
            otaValidationStartTime = nil
            if otaStartTime != nil {
                otaCompletedDuration = Date().timeIntervalSince(otaStartTime!)
            }
            otaStartTime = nil
            otaFirmwareTotalBytes = nil
        }
    }
    
    /// 进度条/日志刷新间隔（每 N 包更新一次），减轻主线程负载，避免每包都触发 @Published 导致 OTA 速率骤降
    private static let otaProgressUpdateInterval = 20
    
    /// 在 didWriteValueFor(OTA Data) 成功后调用：仅延时再发下一包或写 finished(2)，不读 OTA Status（提速约 15–30s）
    private func continueOtaAfterChunkWrite() {
        guard case .sendingChunks(let chunks, let idx) = otaFlowState else { return }
        let total = chunks.count
        let progress = Double(idx + 1) / Double(total)
        // 每 N 包更新一次进度，减少主线程与 UI 负载，避免拖慢包间调度；首包与最后一包必更新
        let shouldUpdateProgress = idx == 0 || (idx + 1) % Self.otaProgressUpdateInterval == 0 || idx + 1 == total
        if shouldUpdateProgress {
            otaProgress = progress
            let start = otaStartTime ?? Date()
            otaProgressLogLine = buildOtaProgressLogLine(progress: progress, startTime: start, totalBytes: otaFirmwareTotalBytes)
        }
        if idx + 1 < total {
            otaFlowState = .sendingChunks(chunks: chunks, nextChunkIndex: idx + 1)
            // 每包发送后仅延时，不读 OTA Status（提速，避免每包增加一次BLE读取）
            // 设备已确认 Status=1（等待数据包），可以持续发送
            // writeWithResponse 的回调已经确保设备收到数据，如果设备处理不过来会返回错误
            // 使用高优先级队列执行延时，提高 CPU 调度优先级
            performOtaDelayThenContinue(nanoseconds: Self.otaChunkDelayNs) {
                self.writeNextOtaChunkIfNeeded()
            }
        } else {
            otaProgress = 1
            // \r 式进度行清空前先写入主日志，保留「最后一条」进度
            if let lastProgress = otaProgressLogLine, !lastProgress.isEmpty {
                appendLogRaw(lastProgress)
            }
            otaProgressLogLine = nil
            appendLog("[OTA] 进度 100% 固件块已全部发送，写 Status=2 (finished)")
            if otaChunkRttCount > 0 {
                let avgMs = (otaChunkRttSum / Double(otaChunkRttCount)) * 1000
                appendLog("[OTA] 共 \(otaChunkRttCount) 包，平均 BLE 响应 \(String(format: "%.1f", avgMs)) ms（耗时主要在 BLE 往返）")
            }
            otaFlowState = .sentFinishedPolling
            isOTAWaitingValidation = true // 标记为等待校验状态
            otaValidationStartTime = Date() // 记录开始等待校验的时间
            writeOtaStatus(2)
            readOtaStatus()
            // 启动校验超时检测
            scheduleOtaValidationTimeout()
        }
    }
    
    /// 发送当前待发的一包 OTA 数据（仅在 state 为 sendingChunks 且 nextChunkIndex 未越界时写一包）
    private func writeNextOtaChunkIfNeeded() {
        guard case .sendingChunks(let chunks, let idx) = otaFlowState, idx < chunks.count else { return }
        writeOtaDataChunk(chunks[idx])
    }
    
    /// 读到 OTA Status 后调用：
    /// - checkingInitialState: 必须为 0 才能继续，否则失败
    /// - waitingStartAck: Status=1 开始发送数据，Status=2 继续轮询等待（最多1s超时），其他状态重试
    /// - sendingChunks: 正常情况下不会进入此分支（传输过程中不读Status），如果意外进入则失败
    /// - sentFinishedPolling: Status=3/4 完成，Status=2 继续轮询
    private func handleOtaStatusPollResult(_ value: UInt8) {
        switch otaFlowState {
        case .checkingInitialState(let chunks):
            if value == 0 {
                // 设备状态为 0（OTA not started），可以开始 OTA
                appendLog("[OTA] 设备状态为 0（OTA not started），写入 Status=1 启动 OTA")
                otaFlowState = .waitingStartAck(chunks: chunks, retryCount: 0, status2PollStartTime: nil)
                writeOtaStatus(1) // start OTA
                appendLog("[OTA] 已写 Status=1 (start)，等待设备确认（最多重试\(Self.otaStartAckMaxRetries)次）…")
                // 等待一段时间后开始第一次读取（给设备足够时间处理 start 命令）
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s（给设备足够时间准备）
                    readOtaStatus()
                }
            } else {
                // 设备状态不为 0，尝试发送 abort 清理之前未正常终止的 OTA 进程
                appendLog("[OTA] 设备状态为 \(value)，不是 0（OTA not started）", level: .warning)
                appendLog("[OTA] 设备可能正在进行其他 OTA 操作，发送 abort (Status=0) 清理状态…")
                otaFlowState = .abortingAndWaitingForIdle(chunks: chunks, abortStartTime: Date())
                writeOtaStatus(0) // abort
                // 等待一段时间后读取状态，检查是否恢复为 0
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s（给设备时间处理 abort）
                    readOtaStatus()
                }
            }
        case .abortingAndWaitingForIdle(let chunks, let abortStartTime):
            if value == 0 {
                // 设备状态已恢复为 0，可以开始 OTA
                let elapsed = Date().timeIntervalSince(abortStartTime)
                appendLog("[OTA] 设备状态已恢复为 0（耗时 \(String(format: "%.2f", elapsed))s），写入 Status=1 启动 OTA")
                otaFlowState = .waitingStartAck(chunks: chunks, retryCount: 0, status2PollStartTime: nil)
                writeOtaStatus(1) // start OTA
                appendLog("[OTA] 已写 Status=1 (start)，等待设备确认（最多重试\(Self.otaStartAckMaxRetries)次）…")
                // 等待一段时间后开始第一次读取（给设备足够时间处理 start 命令）
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s（给设备足够时间准备）
                    readOtaStatus()
                }
            } else {
                // 设备状态仍未恢复为 0，检查是否超时
                let elapsed = Date().timeIntervalSince(abortStartTime)
                if elapsed > Self.otaAbortWaitTimeoutSeconds {
                    // 超时，标记为失败
                    appendLog("[OTA] 等待设备状态恢复为 0 超时（\(String(format: "%.1f", elapsed))s），设备可能无法响应 abort 命令", level: .error)
                    abortOtaAndCleanup(reason: "device did not recover to Status=0 after abort (timeout after \(String(format: "%.1f", elapsed))s)")
                } else {
                    // 继续等待，轮询状态
                    appendLog("[OTA] 设备状态仍为 \(value)，继续等待恢复为 0（已等待 \(String(format: "%.2f", elapsed))s）…", level: .debug)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: Self.otaPollIntervalSeconds) // 0.4s
                        readOtaStatus()
                    }
                }
            }
        case .waitingStartAck(let chunks, let retryCount, let status2PollStartTime):
            if value == 1 {
                // 正式进入 OTA 执行：仅当标记位已置定才真正发送固件
                guard otaMarkerSet else {
                    appendLog("[OTA] OTA 标记未设置，不执行升级", level: .warning)
                    abortOtaAndCleanup(reason: "OTA 标记未设置")
                    return
                }
                // 设备已确认 Status=1，从此时开始计时（启动数据包传输之前的时间不计入）
                if otaStartTime == nil {
                    otaStartTime = Date()
                }
                otaProgressLogLine = buildOtaProgressLogLine(progress: 0, startTime: otaStartTime!, totalBytes: otaFirmwareTotalBytes)
                otaFlowState = .sendingChunks(chunks: chunks, nextChunkIndex: 0)
                writeNextOtaChunkIfNeeded()
            } else if value == 2 {
                // 设备状态为 2（正在写入），不能发数据，继续轮询等待（最多1s超时）
                let pollStart = status2PollStartTime ?? Date()
                let elapsed = Date().timeIntervalSince(pollStart)
                if elapsed > 1.0 {
                    // Status=2 轮询超过1s，超时失败
                    appendLog("[OTA] Status=2 轮询超时（1s），设备可能无法继续，OTA 失败", level: .error)
                    abortOtaAndCleanup(reason: "device stuck in Status=2 for more than 1s")
                } else {
                    appendLog("[OTA] 设备状态为 2（正在写入），等待设备完成写入后继续…（已等待 \(String(format: "%.1f", elapsed))s）", level: .debug)
                    // 继续轮询，等待设备状态变为 1
                    otaFlowState = .waitingStartAck(chunks: chunks, retryCount: retryCount, status2PollStartTime: pollStart)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: Self.otaPollIntervalSeconds) // 0.4s
                        readOtaStatus()
                    }
                }
            } else if value == 0 {
                // 设备状态为 0，可能设备重置了，重试
                appendLog("[OTA] 设备状态为 0（idle），等待确认 Status=1，重试中…", level: .debug)
                retryStartAckIfNeeded()
            } else {
                // 其他状态（如 4=fail），重试
                appendLog("[OTA] 设备状态异常 (Status=\(value))，等待确认 Status=1，重试中…", level: .warning)
                retryStartAckIfNeeded()
            }
        case .sendingChunks:
            // 正常情况下，传输过程中不读取 OTA Status，所以不应该进入此分支
            // 如果意外进入（比如其他地方调用了 readOtaStatus），记录警告但不影响传输
            appendLog("[OTA] 警告：传输过程中意外读取到 OTA Status=\(value)，忽略（传输过程中不检查状态）", level: .warning)
        case .sentFinishedPolling:
            switch value {
            case 3:
                appendLog("[OTA] 设备校验通过 (image valid)")
                otaFlowState = .done
                isOTAWaitingValidation = false // 清除等待校验状态
                otaValidationStartTime = nil // 清除校验超时
                if let start = otaStartTime {
                    otaCompletedDuration = Date().timeIntervalSince(start)
                }
                isOTAInProgress = false
                isOTACompletedWaitingReboot = true
                if otaInitiatedByProductionTest {
                    appendLog("[OTA] 校验完成")
                } else {
                    appendLog("[OTA] 校验完成，等待用户确认重启")
                    playRebootCountdownSound()
                }
            case 4:
                appendLog("[OTA] 设备校验失败 (image fail)", level: .error)
                // 输出诊断信息帮助排查问题
                if let totalBytes = otaFirmwareTotalBytes {
                    appendLog("[OTA] 诊断信息：已发送 \(totalBytes) 字节 (\(totalBytes / 1024) KB)", level: .error)
                }
                if otaChunkRttCount > 0 {
                    let avgMs = (otaChunkRttSum / Double(otaChunkRttCount)) * 1000
                    appendLog("[OTA] 诊断信息：平均 BLE 响应 \(String(format: "%.1f", avgMs)) ms，共 \(otaChunkRttCount) 包", level: .error)
                }
                appendLog("[OTA] 可能原因：1) 固件文件损坏 2) 设备端存储空间不足 3) 设备端校验逻辑问题 4) 传输过程中数据损坏", level: .error)
                abortOtaAndCleanup(reason: "image fail")
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
    
    /// 按当前等级过滤后的日志（供 UI 显示）；仅保留最后若干条，避免条目过多时主线程重算/重绘整块日志导致卡顿、点击延迟
    private static let displayedLogMaxCount = 250
    var displayedLogEntries: [LogEntry] {
        let filtered = logEntries.filter { entry in
            guard !entry.line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            switch entry.level {
            case .debug: return showLogLevelDebug
            case .info: return showLogLevelInfo
            case .warning: return showLogLevelWarning
            case .error: return showLogLevelError
            }
        }
        if filtered.count <= Self.displayedLogMaxCount { return filtered }
        return Array(filtered.suffix(Self.displayedLogMaxCount))
    }
    
    /// 清空日志
    func clearLog() {
        logEntries.removeAll()
        otaProgressLogLine = nil
    }
    
    // MARK: - Private Helpers
    
    /// 向主日志区追加一条日志（含时间戳）。产测传入 [FQC]/[FQC][OTA]: 时原样保留；本模块日志加 [DBG]/[DBG][OTA]:，遵循日志等级过滤
    func appendLog(_ msg: String, level: LogLevel = .info) {
        let line: String
        if msg.hasPrefix("[FQC]") {
            // 产测同步来的日志，已带 [FQC] 或 [FQC][OTA]:，只加时间戳
            line = "\(formattedTime()) \(msg)"
        } else {
            // 调试/本模块日志：加 [DBG] 或 [DBG][OTA]:
            let tag: String
            let body: String
            if msg.hasPrefix("[OTA] ") {
                tag = "[DBG][OTA]:"
                body = String(msg.dropFirst(6))  // "[OTA] " 为 6 个字符，用 7 会多删掉正文首字（如「进」）
            } else if msg.hasPrefix("[OTA]") {
                tag = "[DBG][OTA]:"
                body = String(msg.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else {
                tag = "[DBG]"
                body = msg
            }
            line = "\(formattedTime()) \(tag) \(body)"
        }
        logEntries.append(LogEntry(level: level, line: line))
        trimLogEntriesIfNeeded()
    }
    
    /// 追加一条已格式化行（不加重算时间戳），用于保留 \r 式刷新的「最后一条」进度行到主日志
    private func appendLogRaw(_ line: String, level: LogLevel = .info) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        logEntries.append(LogEntry(level: level, line: line))
        trimLogEntriesIfNeeded()
    }
    
    /// 日志条数超过上限时一次性裁剪，减少频繁 removeFirst 带来的 UI 更新（缓解连续产测时日志卡顿）
    private static let logEntriesTrimLimit = 300
    private func trimLogEntriesIfNeeded() {
        let limit = Self.logEntriesTrimLimit
        if logEntries.count > limit {
            let dropCount = min(100, logEntries.count - limit + 20)
            logEntries.removeFirst(dropCount)
        }
    }
    
    private func formattedTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
    
    /// OTA 时间格式 MM:SS（与 OTASectionView 一致）
    private static func formatOTATime(_ sec: TimeInterval) -> String {
        let total = max(0, Int(sec))
        let m = min(99, total / 60)
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    /// OTA 速率格式 XXX kbps（与 OTASectionView 一致）
    private static func formatOTARate(bytesPerSecond: Double) -> String {
        let kbps = Int(bytesPerSecond * 8 / 1000)
        return String(format: "%3d kbps", min(999, max(0, kbps)))
    }
    
    /// 生成与 OTA 弹窗一致的单行进度文案：进度% 已用 速率 剩余
    private func buildOtaProgressLogLine(progress: Double, startTime: Date, totalBytes: Int?) -> String {
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)
        var rateStr = "  — kbps"
        var remainingStr = "00:00"
        if let total = totalBytes, total > 0, elapsed > 0 {
            let bytesSent = Int(progress * Double(total))
            let rate = Double(bytesSent) / elapsed
            rateStr = Self.formatOTARate(bytesPerSecond: rate)
            if progress > 0, progress < 1, rate > 0 {
                let remainingBytes = Int((1 - progress) * Double(total))
                let remaining = TimeInterval(remainingBytes) / rate
                remainingStr = Self.formatOTATime(remaining)
            }
        } else if progress > 0, progress < 1, elapsed > 0 {
            let remaining = elapsed / progress * (1 - progress)
            remainingStr = Self.formatOTATime(remaining)
        }
        let percentStr = String(format: "%.2f", min(100, progress * 100))
        return "\(formattedTime()) [OTA] 进度 \(percentStr)% 已用 \(Self.formatOTATime(elapsed)) 速率 \(rateStr) 剩余 \(remainingStr)"
    }
    
    private func writeToCharacteristic(_ char: CBCharacteristic?, data: Data) {
        guard let peripheral = connectedPeripheral, let char = char else {
            appendLog("[GATT] 未连接或特征不可用，跳过写入", level: .error)
            return
        }
        let isOtaDataWrite = (GattMapping.characteristicKey(for: char.uuid) == GattMapping.Key.otaData)
        // 除了 OTA 数据包之外，其他所有 GATT 操作都打印日志（包括 OTA Status）
        // OTA Status 会有专用日志（[OTA] 已写 Status=X）和通用日志（wr:...: otaStatus : XX）
        if !(isOtaDataWrite && isOTAInProgress) {
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            let alias = GattMapping.characteristicKey(for: char.uuid) ?? String(char.uuid.uuidString.suffix(8))
            let uuidTag = "0x" + char.uuid.uuidString.lowercased()
            appendLog("wr:\(uuidTag): \(alias) : \(hex)", level: .debug)
        }
        // OTA 数据写入：始终使用 writeWithResponse 确保可靠性（等待设备确认后再继续）
        // 不使用 writeWithoutResponse，因为可能导致数据包丢失导致校验失败
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
    
    /// 调试用：按 UUID 从已发现的服务/特征中查找 CBCharacteristic
    private func characteristic(for uuidString: String) -> CBCharacteristic? {
        guard let peripheral = connectedPeripheral else { return nil }
        let target = uuidString.lowercased()
        for service in peripheral.services ?? [] {
            for char in service.characteristics ?? [] {
                if char.uuid.uuidString.lowercased() == target { return char }
            }
        }
        return nil
    }
    
    /// 调试用：向指定 UUID 特征写入 hex 字符串（空格可选）
    func writeToCharacteristic(uuidString: String, hex: String) {
        guard let data = dataFromHexString(hex), !data.isEmpty else {
            appendLog("[GATT] 无效 hex，跳过写入", level: .error)
            return
        }
        guard let char = characteristic(for: uuidString) else {
            appendLog("[GATT] 未找到特征 \(uuidString)，跳过写入", level: .error)
            return
        }
        writeToCharacteristic(char, data: data)
    }
    
    /// 调试用：读取指定 UUID 特征；结果在 didUpdateValueFor 中写入 lastDebugRead* 供 UI 显示
    func readCharacteristic(uuidString: String) {
        guard let char = characteristic(for: uuidString) else {
            appendLog("[GATT] 未找到特征 \(uuidString)，跳过读取", level: .error)
            return
        }
        pendingDebugReadUUID = uuidString
        readCharacteristic(char)
    }
    
    /// 调试用：按 GATT 协议将特征值 Data 解码为可读字符串（压力/ RTC/阀门/OTA/Device Info 等）
    func decodedString(forCharacteristicUUID uuidString: String, data: Data) -> String {
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        guard let key = GattMapping.characteristicKey(for: CBUUID(string: uuidString)) else {
            if let str = stringFromDeviceInfoData(data), !str.isEmpty { return str }
            return hex
        }
        switch key {
        case GattMapping.Key.pressureRead, GattMapping.Key.pressureOpen:
            return formatPressureData(data)
        case GattMapping.Key.rtc, GattMapping.Key.testing:
            return formatRTCData(data)
        case GattMapping.Key.gasSystemStatus:
            return formatGasStatusData(data)
        case GattMapping.Key.co2PressureLimits:
            return formatPressureLimitsData(data)
        case GattMapping.Key.otaStatus:
            if let b = data.first { return "\(b)" }
            return hex
        case GattMapping.Key.valveControl:
            if let b = data.first { return formatValveModeData(b) }
            return hex
        case GattMapping.Key.valveState:
            if let b = data.first { return formatValveStateData(b) }
            return hex
        default:
            return hex
        }
    }
    
    private func discoverServicesAndCharacteristics(for peripheral: CBPeripheral) {
        peripheral.delegate = self
        // 连接后先只发现主业务服务；Device Information (180A) 在主特征就绪后再发现并读取
        peripheral.discoverServices(Self.mainAppServiceCBUUIDs)
    }
    
    private func updateCharacteristics(from service: CBService) {
        for char in service.characteristics ?? [] {
            if let u = valveControlCBUUID, char.uuid == u { valveCharacteristic = char }
            else if let u = valveStateCBUUID, char.uuid == u { valveStateCharacteristic = char }
            else if let u = pressureReadCBUUID, char.uuid == u { pressureCharacteristic = char }
            else if let u = pressureOpenCBUUID, char.uuid == u { pressureOpenCharacteristic = char }
            else if let u = gasSystemStatusCBUUID, char.uuid == u { gasSystemStatusCharacteristic = char }
            else if let u = co2PressureLimitsCBUUID, char.uuid == u { pressureLimitsCharacteristic = char }
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
        // 先尝试读取一个加密 GATT（valveState），成功则认为连接就绪并继续初始读，失败则提示用户（重置/忘记设备/允许连接）
        if !areCharacteristicsReady && (pressureCharacteristic != nil || pressureOpenCharacteristic != nil) && (testingCharacteristic != nil || rtcCharacteristic != nil) && valveStateCharacteristic != nil {
            readValveState()
        }
    }
    
    /// 加密探测读成功（valveState 可读）后：设 areCharacteristicsReady = true，并执行首次阀门/压力读与 Device Information 发现
    private func markEncryptionVerifiedAndContinueInitialReads() {
        guard !areCharacteristicsReady else { return }
        areCharacteristicsReady = true
        readValveMode()
        readValveState()
        readPressure(silent: true)
        readPressureOpen(silent: true)
        if let deviceInfoService = connectedPeripheral?.services?.first(where: {
            $0.uuid == BLEManagerConstants.deviceInfoServiceCBUUID
        }) {
            connectedPeripheral?.discoverCharacteristics(nil, for: deviceInfoService)
        } else {
            connectedPeripheral?.discoverServices([BLEManagerConstants.deviceInfoServiceCBUUID])
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
            // 连接新设备时清除 OTA 覆盖层状态，避免「在 OTA 器件还有弹窗」：上次 reboot 断开/失败/取消后未点关闭就重连时，弹窗应自动消失
            clearOTAStatus()
            
            connectedPeripheral = peripheral
            isConnected = true
            connectedDeviceName = peripheral.name ?? "已连接"
            appendLog("已连接: \(connectedDeviceName ?? "")")
            
            // 打印连接信息（MTU等）
            // 注意：CoreBluetooth 在 macOS/iOS 上没有公开API直接获取连接间隔
            // 连接间隔主要由设备端（Peripheral）通过 L2CAP Connection Parameter Update Request 决定
            // 可以通过观察 BLE 响应时间（如 OTA 时的平均响应时间）来推断连接间隔
            // 典型值：30ms 连接间隔 → 约 60ms BLE RTT；7.5-15ms 连接间隔 → 约 15-30ms BLE RTT
            if #available(macOS 10.13, *) {
                // macOS 10.13+ 可以通过 maximumWriteValueLength 获取 MTU 相关信息
                let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
                appendLog("[连接信息] MTU (最大写入长度): \(mtu) bytes", level: .debug)
            }
            
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
                appendLog(NSLocalizedString("error.pairing_removed_hint", value: "请在系统「蓝牙」设置中删除该设备（忘记设备）后重试连接。", comment: ""), level: .error)
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
            let wasExpectingReboot = isExpectingDisconnectFromReboot
            if let err = error {
                if wasExpectingReboot {
                    appendLog("已断开（设备重启导致，属正常现象）")
                } else {
                    appendLog("已断开: \(err.localizedDescription)")
                    if BLEManager.isPairingRemovedError(err) {
                        errorMessageKey = "error.pairing_removed_hint"
                        BLEManager.openBluetoothSettings()
                    }
                    errorMessage = err.localizedDescription
                }
            } else {
                appendLog("已断开")
                // 若为加密不足主动断开，保留错误提示供用户看到「必须同意后手动再次连接」
                if errorMessageKey != "error.encryption_insufficient_hint" {
                    errorMessage = nil
                    errorMessageKey = nil
                }
            }
            if wasOTAInProgress && !wasExpectingReboot {
                appendLog("[OTA] 连接断开，OTA 已中断", level: .warning)
            }
            connectedPeripheral = nil
            valveCharacteristic = nil
            valveStateCharacteristic = nil
            pressureCharacteristic = nil
            pressureOpenCharacteristic = nil
            gasSystemStatusCharacteristic = nil
            pressureLimitsCharacteristic = nil
            rtcCharacteristic = nil
            testingCharacteristic = nil
            otaStatusCharacteristic = nil
            otaDataCharacteristic = nil
            isConnected = false
            connectedDeviceName = nil
            areCharacteristicsReady = false
            lastPressureValue = "--"
            lastPressureOpenValue = "--"
            lastGasSystemStatusValue = "--"
            lastPressureLimitsValue = "--"
            lastRTCValue = "--"
            lastSystemTimeAtRTCRead = "--"
            lastTimeDiffFromRTCRead = "--"
            lastValveStateValue = "--"
            lastValveModeValue = "--"
            valveOperationWarning = nil
            pendingValveSetOpen = nil
            valveStateAuthErrorLogged = false
            currentFirmwareVersion = nil
            bootloaderVersion = nil
            deviceSerialNumber = nil
            deviceManufacturer = nil
            deviceModelNumber = nil
            deviceHardwareRevision = nil
            // 断开连接时，检查是否是因为 reboot 导致的正常断开
            if isExpectingDisconnectFromReboot {
                let wasProductionTest = otaInitiatedByProductionTest
                if !wasProductionTest {
                    let elapsed = rebootSentTime.map { Date().timeIntervalSince($0) } ?? 0
                    appendLog("[OTA] 设备已重启并断开连接（正常现象，耗时 \(String(format: "%.1f", elapsed))s）")
                }
                // 标记为 reboot 断开，用于 UI 显示友好提示
                isOTARebootDisconnected = true
                isOTAFailed = false
                isOTACancelled = false
                
                // 清理 OTA 状态（但保留 isOTARebootDisconnected 标记）
                otaFlowState = .idle
                otaInitiatedByProductionTest = false
                isOTAWaitingValidation = false
                isOTACompletedWaitingReboot = false
                isOTAInProgress = false
                otaStartTime = nil
                otaFirmwareTotalBytes = nil
                otaProgress = 0
                otaProgressLogLine = nil
                otaValidationStartTime = nil
                
                // 清除期待断开标记
                isExpectingDisconnectFromReboot = false
                rebootSentTime = nil
            } else if isOTAInProgress && !isOTACancelled {
                // 异常断开：OTA 进行中但未发送 reboot
                if case .done = otaFlowState {
                    // 已完成，保持done状态
                    isOTAFailed = false
                    isOTARebootDisconnected = false
                } else {
                    // 尝试发送 abort（即使设备已断开，也尝试发送以确保状态一致）
                    writeOtaStatus(0)
                    abortOtaAndCleanup(reason: "连接异常断开，OTA 可能未完成")
                    isOTARebootDisconnected = false
                }
            } else if !isOTACancelled {
                // 非 OTA 状态下的断开，正常清理
                otaFlowState = .idle
                isOTAFailed = false
                isOTARebootDisconnected = false
            }
            // 断开连接时不清除取消状态，让用户看到取消信息
            // isOTACancelled = false
            if !isExpectingDisconnectFromReboot {
                // 只有在非 reboot 断开时才清除这些状态（reboot 断开时已在上面的分支中清除）
                otaInitiatedByProductionTest = false
                isOTAWaitingValidation = false
                isOTACompletedWaitingReboot = false
                isOTAInProgress = false
                otaStartTime = nil
            }
            otaFirmwareTotalBytes = nil
            otaValidationStartTime = nil
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
        let mainServiceSet = Set(BLEManagerConstants.mainAppServiceCBUUIDs.map { $0.uuidString.lowercased() })
        let deviceInfoServiceUUID = BLEManagerConstants.deviceInfoServiceCBUUID  // 使用 nonisolated 常量，避免 Main actor 隔离问题
        let services = peripheral.services ?? []
        for service in services {
            let uuidLower = service.uuid.uuidString.lowercased()
            let isMain = mainServiceSet.contains(uuidLower)
            // 使用 CBUUID 对象比较，可以正确处理短格式（180A）和完整格式（0000180A-...）
            let isDeviceInfo = (service.uuid == deviceInfoServiceUUID)
            if isMain || isDeviceInfo {
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
            // 使用 CBUUID 对象比较，可以正确处理短格式和完整格式
            let isDeviceInfo = (service.uuid == BLEManagerConstants.deviceInfoServiceCBUUID)
            
            updateCharacteristics(from: service)
            // Device Information 服务：连接成功后自动读 SN、固件版本等
            if isDeviceInfo {
                let chars = service.characteristics ?? []
                if chars.isEmpty {
                    appendLog("[Device Info] 警告：Device Information 服务没有发现任何特征", level: .warning)
                } else {
                    for char in chars {
                        peripheral.readValue(for: char)
                    }
                }
            }
        }
    }
    
    /// 获取 Device Information 特征的可读名称（用于调试日志）
    @MainActor private func deviceInfoCharacteristicName(for uuid: CBUUID) -> String {
        if uuid == Self.charManufacturerUUID { return "制造商 (2A29)" }
        if uuid == Self.charModelUUID { return "型号 (2A24)" }
        if uuid == Self.charSerialUUID { return "序列号 (2A25)" }
        if uuid == Self.charFirmwareUUID { return "固件版本 (2A26)" }
        if uuid == Self.charHardwareUUID { return "硬件版本 (2A27)" }
        return "未知"
    }
    
    /// 从固件版本字符串中提取 Bootloader 和固件版本号
    /// 支持两种格式：
    /// 1. bootloader_fw1.fw2.fw3，例如 "2_1.0.5" -> bootloader="2", firmware="1.0.5"
    /// 2. bootloader_fw1_fw2_fw3，例如 "0_0_4_0" -> bootloader="0", firmware="0.4.0"
    /// 返回：(bootloader, firmware)
    @MainActor private func extractFirmwareVersions(from versionString: String) -> (bootloader: String, firmware: String) {
        let nsString = versionString as NSString
        let range = NSRange(location: 0, length: nsString.length)
        
        // 先尝试匹配格式1：bootloader_fw1.fw2.fw3，例如 "2_1.0.5"
        let pattern1 = #"(\d+)_(\d+\.\d+\.\d+)"#
        if let regex1 = try? NSRegularExpression(pattern: pattern1, options: []),
           let match = regex1.firstMatch(in: versionString, options: [], range: range),
           match.numberOfRanges >= 3 {
            let bootloaderRange = match.range(at: 1)
            let firmwareRange = match.range(at: 2)
            if bootloaderRange.location != NSNotFound && firmwareRange.location != NSNotFound {
                let bootloader = nsString.substring(with: bootloaderRange)
                let firmware = nsString.substring(with: firmwareRange)
                return (bootloader: bootloader, firmware: firmware)
            }
        }
        
        // 再尝试匹配格式2：bootloader_fw1_fw2_fw3，例如 "0_0_4_0"
        let pattern2 = #"(\d+)_(\d+)_(\d+)_(\d+)"#
        if let regex2 = try? NSRegularExpression(pattern: pattern2, options: []),
           let match = regex2.firstMatch(in: versionString, options: [], range: range),
           match.numberOfRanges >= 5 {
            // 提取 bootloader（第一个数字）
            let bootloaderRange = match.range(at: 1)
            let bootloader = bootloaderRange.location != NSNotFound ? nsString.substring(with: bootloaderRange) : versionString
            
            // 提取固件版本（后面三个数字用点连接）
            let fw1Range = match.range(at: 2)
            let fw2Range = match.range(at: 3)
            let fw3Range = match.range(at: 4)
            
            if fw1Range.location != NSNotFound && fw2Range.location != NSNotFound && fw3Range.location != NSNotFound {
                let fw1 = nsString.substring(with: fw1Range)
                let fw2 = nsString.substring(with: fw2Range)
                let fw3 = nsString.substring(with: fw3Range)
                let firmware = "\(fw1).\(fw2).\(fw3)"
                return (bootloader: bootloader, firmware: firmware)
            }
        }
        
        // 如果没有匹配到，返回原始字符串
        return (bootloader: versionString, firmware: versionString)
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
                        appendLog("rd:\(uuidTag): \(alias) error: \(err.localizedDescription)（阀门状态需加密/配对，仅首次打印）", level: .error)
                    }
                    // 加密/认证不足：提醒用户必须同意系统弹窗，放弃当前操作，等待用户手动再次连接
                    if BLEManager.isEncryptionOrAuthInsufficientError(err) {
                        errorMessageKey = "error.encryption_insufficient_hint"
                        errorMessage = err.localizedDescription
                        appendLog(NSLocalizedString("error.encryption_insufficient_hint", value: "请在系统弹窗中点击「允许」完成配对，然后手动再次连接。", comment: ""), level: .error)
                    }
                    // 成功读到 GATT 之前的任何错误均视为连接失败：释放该次连接（加密未建立）
                    if let peripheral = connectedPeripheral {
                        centralManager.cancelPeripheralConnection(peripheral)
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
            // 加密探测通过（valveState 读成功）：认为连接就绪，执行后续首次读
            if let u = valveStateCBUUID, characteristic.uuid == u, !areCharacteristicsReady {
                markEncryptionVerifiedAndContinueInitialReads()
            }
            if let pending = pendingDebugReadUUID, characteristic.uuid.uuidString.lowercased() == pending.lowercased() {
                lastDebugReadUUID = characteristic.uuid.uuidString
                lastDebugReadHex = hex
                lastDebugReadData = data
                pendingDebugReadUUID = nil
            }
            // 除了 OTA 数据包之外，其他所有读写操作都打印日志
            // OTA Status 读取使用 info 级别，确保总是显示（即使 OTA 进行中）
            let logLevel: LogLevel = isOtaStatusRead ? .info : .debug
            appendLog("rd:\(uuidTag): \(alias) : \(hex)", level: logLevel)
            if let u = pressureReadCBUUID, characteristic.uuid == u {
                lastPressureValue = formatPressureData(data)
                appendLog("关阀压力: \(lastPressureValue)", level: .info)
            } else if let u = pressureOpenCBUUID, characteristic.uuid == u {
                lastPressureOpenValue = formatPressureData(data)
                appendLog("开阀压力: \(lastPressureOpenValue)", level: .info)
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
                lastGasSystemStatusValue = formatGasStatusData(data)
                appendLog("Gas system status: \(lastGasSystemStatusValue)")
            } else if let u = co2PressureLimitsCBUUID, characteristic.uuid == u {
                lastPressureLimitsValue = formatPressureLimitsData(data)
                appendLog("CO2 Pressure Limits: \(lastPressureLimitsValue.replacingOccurrences(of: "\n", with: ", "))")
            } else if let u = otaStatusCBUUID, characteristic.uuid == u, let b = data.first {
                lastOtaStatusValue = b
                // 即使 OTA 进行中也打印日志，方便调试
                appendLog("OTA Status: \(b)")
                if b == 1 && otaInitiatedByProductionTest {
                    otaStatus1ReceivedFromDevice = true
                }
                handleOtaStatusPollResult(b)
            } else if let u = valveControlCBUUID, characteristic.uuid == u, let b = data.first {
                lastValveModeValue = formatValveModeData(b)
                appendLog("阀门模式: \(lastValveModeValue) (0x\(String(format: "%02X", b)))")
            } else if let u = valveStateCBUUID, characteristic.uuid == u, let b = data.first {
                lastValveStateValue = formatValveStateData(b)
                appendLog("阀门状态: \(lastValveStateValue) (0x\(String(format: "%02X", b)))", level: .info)
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
            } else if characteristic.uuid == BLEManager.charManufacturerUUID || characteristic.uuid == BLEManager.charModelUUID || characteristic.uuid == BLEManager.charSerialUUID || characteristic.uuid == BLEManager.charFirmwareUUID || characteristic.uuid == BLEManager.charHardwareUUID || BLEManager.isHardwareRevisionCharacteristic(characteristic.uuid) {
                // Device Information 特征：静默读取，不打印日志
                if let str = stringFromDeviceInfoData(data), !str.isEmpty {
                    // 成功解析为字符串
                    if characteristic.uuid == BLEManager.charManufacturerUUID {
                        deviceManufacturer = str
                    } else if characteristic.uuid == BLEManager.charModelUUID {
                        deviceModelNumber = str
                    } else if characteristic.uuid == BLEManager.charSerialUUID {
                        deviceSerialNumber = str
                    } else if characteristic.uuid == BLEManager.charFirmwareUUID {
                        // 使用正则表达式提取 Bootloader 和固件版本号（例如：从 "0_0_4_0" 中提取 bootloader="0", firmware="0.4.0"）
                        let versions = extractFirmwareVersions(from: str)
                        bootloaderVersion = versions.bootloader
                        currentFirmwareVersion = versions.firmware
                    } else if characteristic.uuid == BLEManager.charHardwareUUID || BLEManager.isHardwareRevisionCharacteristic(characteristic.uuid) {
                        deviceHardwareRevision = str
                    }
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
                    abortOtaAndCleanup(reason: error.localizedDescription)
                }
            }
        } else {
            // 使用高优先级 Task，避免 OTA 写回调被主线程其它任务推迟导致速率骤降（如 18kbps -> 8kbps）
            Task(priority: .high) { @MainActor in
                if isOtaData && isOTAInProgress {
                    // writeWithResponse 模式：记录响应时间并继续发送下一包
                    if let start = otaChunkWriteStartTime {
                        let elapsed = Date().timeIntervalSince(start)
                        otaChunkRttSum += elapsed
                        otaChunkRttCount += 1
                        
                        // 监控连接参数变化：记录前N个包的响应时间
                        if initialRttSamples.count < Self.initialRttSampleCount {
                            initialRttSamples.append(elapsed)
                        }
                    }
                    continueOtaAfterChunkWrite()
                } else {
                    // 除了 OTA 数据包之外，其他所有 GATT 操作都打印成功日志（包括 OTA Status）
                    if !isOtaData {
                        appendLog("wr:\(uuidTag): \(alias) ok", level: .debug)
                    }
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
            _ = Int(bytes[4]) // weekday, 解码用
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
    
    /// 判断是否为 GATT 硬件版本特征 2A27（兼容短格式与完整格式 UUID）
    @MainActor private static func isHardwareRevisionCharacteristic(_ uuid: CBUUID) -> Bool {
        let normalized = uuid.uuidString.uppercased().replacingOccurrences(of: "-", with: "")
        return normalized.hasSuffix("2A27") || normalized == "2A27"
    }
    
    /// Device Information 特征值为 UTF-8 字符串
    @MainActor private func stringFromDeviceInfoData(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// CO2 Pressure Limits: 6 × UInt16 (mbar)，顺序 gas_empty_low, gas_empty_high, leak, press_change, press_rise, lglo_leak
    @MainActor private func formatPressureLimitsData(_ data: Data) -> String {
        let labels = ["gas_empty_low", "gas_empty_high", "leak", "press_change", "press_rise", "lglo_leak"]
        guard data.count >= 12 else {
            return data.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        var lines: [String] = []
        for i in 0..<6 {
            let offset = i * 2
            let mbar = data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> UInt16 in
                p.load(fromByteOffset: offset, as: UInt16.self)
            }
            lines.append("\(labels[i]): \(mbar) mbar")
        }
        return lines.joined(separator: "\n")
    }
    
    /// Gas system status: 0 initially closed, 1 ok, 2 leak, 3–7 reserved, 8 low gas low output (ok), 9 low gas low output leak check
    @MainActor private func formatGasStatusData(_ data: Data) -> String {
        let statusNames = ["initially closed", "ok", "leak", "reserved", "reserved", "reserved", "reserved", "reserved", "low gas (ok)", "low gas leak check"]
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
