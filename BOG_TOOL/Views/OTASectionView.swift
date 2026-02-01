import SwiftUI

/// OTA 区域：产测与 Debug 共用，逻辑统一在 BLEManager 中
struct OTASectionView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    /// 是否为模态模式（用于OTA进行中的独占窗口）
    var isModal: Bool = false
    
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
        VStack(alignment: .leading, spacing: isModal ? 10 : 6) {
            Text(otaTitleText)
                .font(isModal ? .system(.title2, design: .monospaced) : .system(.subheadline, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            // 状态行（进行中时每秒刷新已用/剩余时间，等待重启时每秒刷新倒计时）
            Group {
                if ble.isOTAInProgress || ble.isOTACompletedWaitingReboot {
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        Text(statusText(now: context.date))
                            .font(isModal ? .system(.body, design: .monospaced) : .system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(statusText())
                        .font(isModal ? .system(.body, design: .monospaced) : .system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            
            // 模态模式下隐藏固件选择和浏览按钮，只显示关键信息
            if !isModal {
                // 当前固件版本
                HStack(alignment: .center, spacing: 6) {
                    Text(appLanguage.string("ota.firmware_version"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ble.currentFirmwareVersion ?? appLanguage.string("ota.unknown"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ble.currentFirmwareVersion != nil ? .primary : .secondary)
                }
                
                // 目标固件大小（当前选择的 .bin 文件）
                HStack(alignment: .center, spacing: 6) {
                    Text(appLanguage.string("ota.firmware_size"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(ble.selectedFirmwareSizeDisplay)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                // 固件选择
                HStack(alignment: .center, spacing: 8) {
                    Text(appLanguage.string("ota.browse"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(firmwareDisplayName)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(6)
                    Spacer(minLength: 8)
                    Button {
                        ble.browseAndSaveFirmware()
                    } label: {
                        Text(appLanguage.string("ota.browse"))
                            .frame(minWidth: actionButtonWidth, maxWidth: actionButtonWidth)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // 模态模式下显示更详细的信息
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appLanguage.string("ota.firmware_version"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(ble.currentFirmwareVersion ?? appLanguage.string("ota.unknown"))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(ble.currentFirmwareVersion != nil ? .primary : .secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(appLanguage.string("ota.firmware_size"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(ble.selectedFirmwareSizeDisplay)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // 显示固件文件名
                    HStack(alignment: .center, spacing: 8) {
                        Text(appLanguage.string("ota.browse"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(firmwareDisplayName)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(8)
                    }
                }
            }
            
            // 进度条（靠左）+ Start/Cancel OTA 按键（靠右）同一行
            HStack(alignment: .center, spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: isModal ? 4 : 3, style: .continuous)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: isModal ? 12 : 6)
                        RoundedRectangle(cornerRadius: isModal ? 4 : 3, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: max(0, geo.size.width * ble.otaProgress), height: isModal ? 12 : 6)
                    }
                }
                .frame(height: isModal ? 12 : 6)
                Spacer(minLength: 12)
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
                            .frame(minWidth: isModal ? 120 : actionButtonWidth, maxWidth: isModal ? 120 : actionButtonWidth)
                    } else if ble.isOTACancelled {
                        Text(appLanguage.string("ota.close"))
                            .frame(minWidth: isModal ? 120 : actionButtonWidth, maxWidth: isModal ? 120 : actionButtonWidth)
                    } else if ble.isOTACompletedWaitingReboot {
                        // 显示重启按钮（等待用户确认）
                        Text(appLanguage.string("ota.reboot"))
                            .frame(minWidth: isModal ? 120 : actionButtonWidth, maxWidth: isModal ? 120 : actionButtonWidth)
                    } else {
                        Text(ble.isOTAInProgress ? appLanguage.string("ota.cancel") : appLanguage.string("ota.start"))
                            .frame(minWidth: isModal ? 120 : actionButtonWidth, maxWidth: isModal ? 120 : actionButtonWidth)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .disabled(true)
            }
        }
        .padding(isModal ? 20 : 6)
        .background(otaSectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: isModal ? 16 : 8, style: .continuous))
        .frame(maxWidth: isModal ? 600 : nil)
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
