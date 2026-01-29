import SwiftUI

/// OTA 区域：产测与 Debug 共用，逻辑统一在 BLEManager 中
struct OTASectionView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var ble: BLEManager
    
    private var firmwareDisplayName: String {
        ble.selectedFirmwareURL?.lastPathComponent ?? appLanguage.string("ota.not_selected")
    }
    
    private var statusText: String {
        if ble.isOTAInProgress {
            return "\(appLanguage.string("ota.progress")) \(Int(ble.otaProgress * 100))%"
        }
        if ble.otaProgress >= 1 && !ble.isOTAInProgress {
            return appLanguage.string("ota.completed")
        }
        return appLanguage.string("ota.ready")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appLanguage.string("ota.title"))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            // 当前固件版本
            HStack(alignment: .center, spacing: 8) {
                Text(appLanguage.string("ota.firmware_version"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ble.currentFirmwareVersion ?? appLanguage.string("ota.unknown"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ble.currentFirmwareVersion != nil ? .primary : .secondary)
            }
            
            // 固件选择
            HStack(alignment: .center, spacing: 10) {
                Text(appLanguage.string("ota.browse"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(firmwareDisplayName)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(8)
                Button(appLanguage.string("ota.browse")) {
                    ble.browseAndSaveFirmware()
                }
                .buttonStyle(.borderedProminent)
            }
            
            // 启动 OTA + 进度
            HStack(alignment: .center, spacing: 12) {
                Button(appLanguage.string("ota.start")) {
                    ble.startOTA()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || ble.selectedFirmwareURL == nil || ble.isOTAInProgress || !ble.isOtaAvailable)
                
                if ble.isOTAInProgress {
                    ProgressView()
                        .scaleEffect(0.8)
                }
                
                Spacer(minLength: 8)
                
                Text(statusText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ble.isOTAInProgress ? Color.accentColor : .secondary)
            }
            
            // 进度条
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(width: max(0, geo.size.width * ble.otaProgress), height: 8)
                    }
                }
                .frame(height: 8)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }
}
