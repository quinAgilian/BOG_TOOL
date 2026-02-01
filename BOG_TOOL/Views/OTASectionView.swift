import SwiftUI

/// 下拉选项：未选择或某条固件 id（用于 Picker）
private enum FirmwarePickerChoice: Hashable {
    case none
    case managed(UUID)
}

/// OTA 区域：产测与 Debug 共用，逻辑统一在 BLEManager 中；Debug 时下拉选择目标固件，产测按 SOP 版本解析
struct OTASectionView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    @ObservedObject var firmwareManager: FirmwareManager
    /// 是否为模态模式（用于OTA进行中的独占窗口）
    var isModal: Bool = false
    /// 是否为产测触发的 OTA（模态下不显示“目标固件 Debug OTA”选择，只显示由产测规则指定的版本）
    var isProductionTestOTA: Bool = false
    /// 下拉当前选中的管理固件 id（仅 Debug 下拉用）
    @State private var pickerChoice: FirmwarePickerChoice = .none
    /// Debug 下记住的固件选择（UserDefaults key）
    private static let debugSelectedFirmwareIdKey = "debug_ota_selected_firmware_id"
    /// 等待用户确认重启时的倒计时剩余秒数（30s 后自动执行 reboot）
    @State private var rebootCountdownRemaining: Int = 0
    
    private static let rebootCountdownSeconds = 30
    
    private var firmwareDisplayName: String {
        ble.selectedFirmwareURL?.lastPathComponent ?? appLanguage.string("ota.not_selected")
    }
    
    /// 将秒数格式化为 "00:00"（两位分、两位秒，整体长度固定）
    private static func formatOTATime(_ sec: TimeInterval) -> String {
        let total = max(0, Int(sec))
        let m = min(99, total / 60)
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    /// 将字节/秒格式化为 "XXX kbps"（千比特/秒，整数，整体长度固定）
    private static func formatTransferRate(bytesPerSecond: Double) -> String {
        let kbps = Int(bytesPerSecond * 8 / 1000)
        return String(format: "%3d kbps", min(999, max(0, kbps)))
    }
    
    /// 状态行：进行中显示进度+已用+当前速率+剩余；失败显示失败信息；取消显示取消信息；等待校验/重启显示相应提示；完成后显示完成；新会话显示就绪
    private func statusText(now: Date = Date()) -> String {
        // 优先检查 reboot 断开状态（正常重启断开）
        if ble.isOTARebootDisconnected {
            return appLanguage.string("ota.reboot_disconnected_hint")
        }
        
        // 优先检查失败状态
        if ble.isOTAFailed {
            return appLanguage.string("ota.failed")
        }
        
        // 检查取消状态
        if ble.isOTACancelled {
            return appLanguage.string("ota.cancelled")
        }
        
        // 如果OTA完成等待重启
        if ble.isOTACompletedWaitingReboot {
            if let dur = ble.otaCompletedDuration {
                return String(format: appLanguage.string("ota.completed_waiting_reboot"), Self.formatOTATime(dur))
            }
            return appLanguage.string("ota.waiting_reboot")
        }
        
        if ble.isOTAInProgress {
            // 如果进度100%且正在等待设备校验
            if ble.otaProgress >= 1 && ble.isOTAWaitingValidation {
                let start = ble.otaStartTime ?? now
                let elapsed = now.timeIntervalSince(start)
                return String(format: appLanguage.string("ota.waiting_validation"), Self.formatOTATime(elapsed))
            }
            // 正常传输中
            let start = ble.otaStartTime ?? now
            let elapsed = now.timeIntervalSince(start)
            let progress = ble.otaProgress
            var rateStr = "  — kbps"
            var remainingStr = "00:00"
            if let total = ble.otaFirmwareTotalBytes, total > 0, elapsed > 0 {
                let bytesSent = Int(progress * Double(total))
                let rate = Double(bytesSent) / elapsed
                rateStr = Self.formatTransferRate(bytesPerSecond: rate)
                if progress > 0, progress < 1, rate > 0 {
                    let remainingBytes = Int((1 - progress) * Double(total))
                    let remaining = TimeInterval(remainingBytes) / rate
                    remainingStr = Self.formatOTATime(remaining)
                }
            } else if progress > 0, progress < 1 {
                let remaining = elapsed / progress * (1 - progress)
                remainingStr = Self.formatOTATime(remaining)
            } else {
                remainingStr = "00:00"
            }
            return String(format: appLanguage.string("ota.progress_elapsed_rate_remaining"), progress * 100, Self.formatOTATime(elapsed), rateStr, remainingStr)
        }
        
        // 已完成（成功）
        if ble.otaProgress >= 1 && !ble.isOTAFailed && !ble.isOTACancelled {
            if let dur = ble.otaCompletedDuration {
                return String(format: appLanguage.string("ota.completed_with_duration"), Self.formatOTATime(dur))
            }
            return appLanguage.string("ota.completed")
        }
        
        return appLanguage.string("ota.ready")
    }
    
    /// 标题：失败 → 失败；取消 → 取消；进行中 → 百分比；等待重启 → 等待重启；完成 → 完成；新会话 → 未开始
    private var otaTitleText: String {
        // 优先检查 reboot 断开状态（正常重启断开）
        if ble.isOTARebootDisconnected {
            return appLanguage.string("ota.title_reboot_disconnected")
        }
        
        // 优先检查失败状态
        if ble.isOTAFailed {
            return appLanguage.string("ota.title_failed")
        }
        
        // 检查取消状态
        if ble.isOTACancelled {
            return appLanguage.string("ota.title_cancelled")
        }
        
        if ble.isOTACompletedWaitingReboot {
            return appLanguage.string("ota.title_waiting_reboot")
        }
        if ble.isOTAInProgress {
            return String(format: appLanguage.string("ota.title_in_progress_format"), ble.otaProgress * 100)
        }
        if ble.otaProgress >= 1 && !ble.isOTAFailed && !ble.isOTACancelled {
            if let dur = ble.otaCompletedDuration {
                return String(format: appLanguage.string("ota.title_completed_with_duration"), Self.formatOTATime(dur))
            }
            return appLanguage.string("ota.title_completed")
        }
        return appLanguage.string("ota.title_not_started")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: isModal ? UIDesignSystem.Spacing.lg : UIDesignSystem.Spacing.sm) {
            Text(otaTitleText)
                .font(isModal ? UIDesignSystem.Typography.pageTitle : UIDesignSystem.Typography.subsectionTitle)
                .foregroundStyle(UIDesignSystem.Foreground.secondary)
            
            // 状态行（进行中时每秒刷新已用/剩余时间，等待重启时每秒刷新倒计时）
            Group {
                if ble.isOTAInProgress || ble.isOTACompletedWaitingReboot {
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        Text(statusText(now: context.date))
                            .font(isModal ? UIDesignSystem.Typography.body : UIDesignSystem.Typography.caption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    }
                } else {
                    Text(statusText())
                        .font(isModal ? UIDesignSystem.Typography.body : UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
            }
            
            // 模态模式下隐藏固件选择和浏览按钮，只显示关键信息
            if !isModal {
                // 固件版本：current 和 goal（goal 后面显示固件大小）
                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.sm) {
                    Text("fw:")
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text("current:")
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text(ble.currentFirmwareVersion ?? appLanguage.string("ota.unknown"))
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .foregroundStyle(ble.currentFirmwareVersion != nil ? UIDesignSystem.Foreground.primary : UIDesignSystem.Foreground.secondary)
                    Text("goal:")
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Text(ble.parsedFirmwareVersion ?? appLanguage.string("ota.not_selected"))
                        .font(UIDesignSystem.Typography.monospacedCaption)
                        .foregroundStyle(ble.parsedFirmwareVersion != nil ? UIDesignSystem.Foreground.primary : UIDesignSystem.Foreground.secondary)
                    if ble.selectedFirmwareURL != nil {
                        Text("(\(ble.selectedFirmwareSizeDisplay))")
                            .font(UIDesignSystem.Typography.monospacedCaption)
                            .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    }
                }
                
                // 目标固件：下拉从管理列表选择（Debug OTA）+ 浏览添加
                HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                    Text(appLanguage.string("firmware_manager.debug_target"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                    Picker("", selection: $pickerChoice) {
                        Text(appLanguage.string("ota.not_selected")).tag(FirmwarePickerChoice.none)
                        ForEach(firmwareManager.entries) { e in
                            Text("\(e.parsedVersion) – \((e.pathDisplay as NSString).lastPathComponent)")
                                .tag(FirmwarePickerChoice.managed(e.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: pickerChoice) { new in
                        switch new {
                        case .none: break
                        case .managed(let id):
                            if let url = firmwareManager.url(forId: id) {
                                ble.selectFirmware(url: url)
                                UserDefaults.standard.set(id.uuidString, forKey: Self.debugSelectedFirmwareIdKey)
                            }
                        }
                    }
                    Button {
                        ble.browseAndSaveFirmware()
                    } label: {
                        Text(appLanguage.string("ota.browse"))
                            .frame(minWidth: UIDesignSystem.Component.actionButtonWidth, maxWidth: UIDesignSystem.Component.actionButtonWidth)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // 模态模式下：产测 OTA 不显示“选固件”，只显示由产测规则指定的版本；Debug OTA 显示下拉 + 浏览
                VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.md) {
                    HStack(alignment: .center, spacing: UIDesignSystem.Spacing.lg) {
                        VStack(alignment: .leading, spacing: UIDesignSystem.Spacing.xs) {
                            HStack(spacing: UIDesignSystem.Spacing.sm) {
                                Text("fw:")
                                    .font(UIDesignSystem.Typography.caption)
                                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                                Text("current:")
                                    .font(UIDesignSystem.Typography.caption)
                                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                                Text(ble.currentFirmwareVersion ?? appLanguage.string("ota.unknown"))
                                    .font(UIDesignSystem.Typography.monospaced)
                                    .foregroundStyle(ble.currentFirmwareVersion != nil ? UIDesignSystem.Foreground.primary : UIDesignSystem.Foreground.secondary)
                                Text("goal:")
                                    .font(UIDesignSystem.Typography.caption)
                                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                                Text(ble.parsedFirmwareVersion ?? appLanguage.string("ota.not_selected"))
                                    .font(UIDesignSystem.Typography.monospaced)
                                    .foregroundStyle(ble.parsedFirmwareVersion != nil ? UIDesignSystem.Foreground.primary : UIDesignSystem.Foreground.secondary)
                                if ble.selectedFirmwareURL != nil {
                                    Text("(\(ble.selectedFirmwareSizeDisplay))")
                                        .font(UIDesignSystem.Typography.monospaced)
                                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                                }
                            }
                            if isProductionTestOTA {
                                Text(String(format: appLanguage.string("ota.target_from_production_rules"), ble.parsedFirmwareVersion ?? "—"))
                                    .font(UIDesignSystem.Typography.caption)
                                    .foregroundStyle(UIDesignSystem.Foreground.secondary)
                            }
                        }
                        Spacer()
                    }
                    
                    if !isProductionTestOTA {
                        // Debug OTA：目标固件下拉 + 浏览
                        HStack(alignment: .center, spacing: UIDesignSystem.Spacing.md) {
                            Text(appLanguage.string("firmware_manager.debug_target"))
                                .font(UIDesignSystem.Typography.caption)
                                .foregroundStyle(UIDesignSystem.Foreground.secondary)
                            Picker("", selection: $pickerChoice) {
                                Text(appLanguage.string("ota.not_selected")).tag(FirmwarePickerChoice.none)
                                ForEach(firmwareManager.entries) { e in
                                    Text("\(e.parsedVersion) – \((e.pathDisplay as NSString).lastPathComponent)")
                                        .tag(FirmwarePickerChoice.managed(e.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onChange(of: pickerChoice) { new in
                                switch new {
                                case .none: break
                                case .managed(let id):
                                    if let url = firmwareManager.url(forId: id) {
                                        ble.selectFirmware(url: url)
                                        UserDefaults.standard.set(id.uuidString, forKey: Self.debugSelectedFirmwareIdKey)
                                    }
                                }
                            }
                            Button(appLanguage.string("ota.browse")) { ble.browseAndSaveFirmware() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            
            // 进度条（靠左）+ Start/Cancel OTA 按键（靠右）同一行
            HStack(alignment: .center, spacing: UIDesignSystem.Spacing.lg) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: isModal ? UIDesignSystem.CornerRadius.xs : UIDesignSystem.CornerRadius.xs, style: .continuous)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: isModal ? UIDesignSystem.Component.modalProgressBarHeight : UIDesignSystem.Component.progressBarHeight)
                        RoundedRectangle(cornerRadius: isModal ? UIDesignSystem.CornerRadius.xs : UIDesignSystem.CornerRadius.xs, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: max(0, geo.size.width * ble.otaProgress), height: isModal ? UIDesignSystem.Component.modalProgressBarHeight : UIDesignSystem.Component.progressBarHeight)
                    }
                }
                .frame(height: isModal ? UIDesignSystem.Component.modalProgressBarHeight : UIDesignSystem.Component.progressBarHeight)
                Spacer(minLength: UIDesignSystem.Spacing.lg)
                Button {
                    if ble.isOTAFailed || ble.isOTACancelled || ble.isOTARebootDisconnected {
                        // 失败、取消或 reboot 断开：关闭弹窗（清除状态）
                        ble.clearOTAStatus()
                    } else if ble.isOTACompletedWaitingReboot {
                        // OTA完成等待重启：立即发送reboot
                        ble.sendReboot()
                    } else if ble.isOTAInProgress {
                        // OTA进行中：取消OTA
                        ble.cancelOTA()
                    } else {
                        // 未开始：启动OTA
                        ble.startOTA()
                    }
                } label: {
                    if ble.isOTAFailed || ble.isOTARebootDisconnected {
                        Text(appLanguage.string("ota.close"))
                            .frame(minWidth: isModal ? UIDesignSystem.Component.largeButtonWidth : UIDesignSystem.Component.actionButtonWidth, maxWidth: isModal ? UIDesignSystem.Component.largeButtonWidth : UIDesignSystem.Component.actionButtonWidth)
                    } else if ble.isOTACancelled {
                        Text(appLanguage.string("ota.close"))
                            .frame(minWidth: isModal ? UIDesignSystem.Component.largeButtonWidth : UIDesignSystem.Component.actionButtonWidth, maxWidth: isModal ? UIDesignSystem.Component.largeButtonWidth : UIDesignSystem.Component.actionButtonWidth)
                    } else if ble.isOTACompletedWaitingReboot {
                        // 显示重启按钮与倒计时（超时后自动执行）
                        Text(String(format: appLanguage.string("ota.reboot_countdown"), rebootCountdownRemaining))
                            .frame(minWidth: isModal ? UIDesignSystem.Component.largeButtonWidth : UIDesignSystem.Component.actionButtonWidth, maxWidth: isModal ? UIDesignSystem.Component.largeButtonWidth : UIDesignSystem.Component.actionButtonWidth)
                    } else {
                        Text(ble.isOTAInProgress ? appLanguage.string("ota.cancel") : appLanguage.string("ota.start"))
                            .frame(minWidth: isModal ? UIDesignSystem.Component.largeButtonWidth : UIDesignSystem.Component.actionButtonWidth, maxWidth: isModal ? UIDesignSystem.Component.largeButtonWidth : UIDesignSystem.Component.actionButtonWidth)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(isModal ? .large : .regular)
                .disabled(
                    // reboot 断开、失败或取消时允许点击 Close 按钮（即使设备已断开）
                    // 其他情况：需要连接且满足 OTA 条件
                    (ble.isOTARebootDisconnected || ble.isOTAFailed || ble.isOTACancelled) 
                        ? false 
                        : (!ble.isConnected || (!ble.isOTAInProgress && !ble.isOTACompletedWaitingReboot && (ble.selectedFirmwareURL == nil || !ble.isOtaAvailable)))
                )
            }
            
            // OTA 完成后是否自动发送 reboot（当前固定为选中，复选框禁用）
            if !isModal {
                Toggle(isOn: .constant(true)) {
                    Text(appLanguage.string("ota.auto_reboot_after_ota"))
                        .font(UIDesignSystem.Typography.caption)
                        .foregroundStyle(UIDesignSystem.Foreground.secondary)
                }
                .toggleStyle(.checkbox)
                .disabled(true)
            }
        }
        .padding(isModal ? UIDesignSystem.Padding.xl : UIDesignSystem.Padding.sm)
        .background(otaSectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: isModal ? UIDesignSystem.CornerRadius.xl : UIDesignSystem.CornerRadius.md, style: .continuous))
        .frame(maxWidth: isModal ? 600 : nil)
        .onChange(of: ble.isOTACompletedWaitingReboot) { newValue in
            if newValue {
                rebootCountdownRemaining = Self.rebootCountdownSeconds
            } else {
                rebootCountdownRemaining = 0
            }
        }
        .task(id: ble.isOTACompletedWaitingReboot) {
            guard ble.isOTACompletedWaitingReboot else { return }
            for i in (1...Self.rebootCountdownSeconds).reversed() {
                guard ble.isOTACompletedWaitingReboot else { return }
                rebootCountdownRemaining = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if ble.isOTACompletedWaitingReboot {
                ble.sendReboot()
            }
        }
        .onAppear { syncDebugFirmwareSelection() }
        .onChange(of: firmwareManager.entries.count) { _ in syncDebugFirmwareSelection() }
    }
    
    /// Debug 模式：固件默认选第一个；若曾选择过则从 UserDefaults 恢复并维持
    private func syncDebugFirmwareSelection() {
        guard !isProductionTestOTA else { return }
        let entries = firmwareManager.entries
        if entries.isEmpty {
            pickerChoice = .none
            return
        }
        if let savedIdStr = UserDefaults.standard.string(forKey: Self.debugSelectedFirmwareIdKey),
           let savedId = UUID(uuidString: savedIdStr),
           entries.contains(where: { $0.id == savedId }) {
            pickerChoice = .managed(savedId)
            if let url = firmwareManager.url(forId: savedId) {
                ble.selectFirmware(url: url)
            }
            return
        }
        let firstId = entries[0].id
        pickerChoice = .managed(firstId)
        if let url = firmwareManager.url(forId: firstId) {
            ble.selectFirmware(url: url)
        }
        UserDefaults.standard.set(firstId.uuidString, forKey: Self.debugSelectedFirmwareIdKey)
    }
    
    /// 未启动：正常；失败：红；取消：橙；进行中：蓝色呼吸灯；完成：绿
    /// 模态模式下，背景需要不透明以确保圆角完美
    /// 背景色：失败→红色，取消→橙色，reboot断开→绿色（成功），其他→默认
    private var otaSectionBackground: some View {
        Group {
            if ble.isOTAInProgress {
                ZStack {
                    // 模态模式下先添加不透明背景，确保圆角完美
                    if isModal {
                        Color(nsColor: .windowBackgroundColor)
                    }
                    // 然后添加呼吸灯效果
                    TimelineView(.periodic(from: .now, by: 0.03)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = t.truncatingRemainder(dividingBy: 1.5) / 1.5 * (2 * .pi)
                        let opacity = 0.14 + 0.18 * (0.5 + 0.5 * cos(phase))
                        Color.blue.opacity(opacity)
                    }
                }
            } else if ble.isOTAFailed {
                ZStack {
                    if isModal {
                        Color(nsColor: .windowBackgroundColor)
                    }
                    Color.red.opacity(0.18)
                }
            } else if ble.isOTACancelled {
                ZStack {
                    if isModal {
                        Color(nsColor: .windowBackgroundColor)
                    }
                    Color.orange.opacity(0.15)
                }
            } else if ble.isOTARebootDisconnected {
                // reboot 断开：显示绿色背景（成功状态）
                ZStack {
                    if isModal {
                        Color(nsColor: .windowBackgroundColor)
                    }
                    Color.green.opacity(0.15)
                }
            } else if ble.otaProgress >= 1 && !ble.isOTAFailed && !ble.isOTACancelled {
                ZStack {
                    if isModal {
                        Color(nsColor: .windowBackgroundColor)
                    }
                    Color.green.opacity(0.15)
                }
            } else {
                if isModal {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    Color.primary.opacity(0.04)
                }
            }
        }
    }
}
