import SwiftUI

/// OTA 区域：产测与 Debug 共用，逻辑统一在 BLEManager 中
struct OTASectionView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    
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
    
    /// 状态行：进行中显示进度+已用+当前速率+剩余（按当前传输速率估算）；完成后显示完成；新会话显示就绪
    private func statusText(now: Date = Date()) -> String {
        if ble.isOTAInProgress {
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
        if ble.otaProgress >= 1 {
            if let dur = ble.otaCompletedDuration {
                return String(format: appLanguage.string("ota.completed_with_duration"), Self.formatOTATime(dur))
            }
            return appLanguage.string("ota.completed")
        }
        return appLanguage.string("ota.ready")
    }
    
    /// 标题：进行中 → 百分比；完成 → 完成；新会话 → 未开始
    private var otaTitleText: String {
        if ble.isOTAInProgress {
            return String(format: appLanguage.string("ota.title_in_progress_format"), ble.otaProgress * 100)
        }
        if ble.otaProgress >= 1 {
            if let dur = ble.otaCompletedDuration {
                return String(format: appLanguage.string("ota.title_completed_with_duration"), Self.formatOTATime(dur))
            }
            return appLanguage.string("ota.title_completed")
        }
        return appLanguage.string("ota.title_not_started")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(otaTitleText)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            // 状态行（进行中时每秒刷新已用/剩余时间）
            Group {
                if ble.isOTAInProgress {
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        Text(statusText(now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(statusText())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
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
            
            // 进度条（靠左）+ Start OTA 按键（靠右）同一行
            HStack(alignment: .center, spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: max(0, geo.size.width * ble.otaProgress), height: 6)
                    }
                }
                .frame(height: 6)
                Spacer(minLength: 8)
                Button {
                    if ble.isOTAInProgress {
                        ble.cancelOTA()
                    } else {
                        ble.startOTA()
                    }
                } label: {
                    Text(ble.isOTAInProgress ? appLanguage.string("ota.cancel") : appLanguage.string("ota.start"))
                        .frame(minWidth: actionButtonWidth, maxWidth: actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || (!ble.isOTAInProgress && (ble.selectedFirmwareURL == nil || !ble.isOtaAvailable)))
            }
            
            // OTA 完成后是否自动发送 reboot（当前固定为选中，复选框禁用）
            Toggle(isOn: .constant(true)) {
                Text(appLanguage.string("ota.auto_reboot_after_ota"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .disabled(true)
        }
        .padding(6)
        .background(otaSectionBackground)
        .cornerRadius(8)
    }
    
    /// 未启动：正常；失败：红；进行中：蓝色呼吸灯；完成：绿
    private var otaSectionBackground: some View {
        Group {
            if ble.isOTAInProgress {
                TimelineView(.periodic(from: .now, by: 0.03)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = t.truncatingRemainder(dividingBy: 1.5) / 1.5 * (2 * .pi)
                    let opacity = 0.14 + 0.18 * (0.5 + 0.5 * cos(phase))
                    Color.blue.opacity(opacity)
                }
            } else if ble.isOTAFailed {
                Color.red.opacity(0.18)
            } else if ble.otaProgress >= 1 {
                Color.green.opacity(0.15)
            } else {
                Color.primary.opacity(0.04)
            }
        }
    }
}
