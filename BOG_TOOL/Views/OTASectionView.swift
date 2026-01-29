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
        VStack(alignment: .leading, spacing: 6) {
            Text(appLanguage.string("ota.title"))
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            // 当前固件版本
            HStack(alignment: .center, spacing: 6) {
                Text(appLanguage.string("ota.firmware_version"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ble.currentFirmwareVersion ?? appLanguage.string("ota.unknown"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ble.currentFirmwareVersion != nil ? .primary : .secondary)
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
                    ble.startOTA()
                } label: {
                    Text(appLanguage.string("ota.start"))
                        .frame(minWidth: actionButtonWidth, maxWidth: actionButtonWidth)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ble.isConnected || ble.selectedFirmwareURL == nil || ble.isOTAInProgress || !ble.isOtaAvailable)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }
}
