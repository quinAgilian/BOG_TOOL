import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 固件管理视图：列表（版本、路径）、新增、删除
struct FirmwareManagerView: View {
    @EnvironmentObject private var appLanguage: AppLanguage
    @ObservedObject var manager: FirmwareManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(appLanguage.string("firmware_manager.title"))
                    .font(UIDesignSystem.Typography.sectionTitle)
                Spacer()
                Button(appLanguage.string("firmware_manager.add")) {
                    addFirmware()
                }
                .buttonStyle(.borderedProminent)
                Button(appLanguage.string("firmware_manager.close")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(UIDesignSystem.Padding.lg)
            
            Divider()
            
            if manager.entries.isEmpty {
                Text(appLanguage.string("firmware_manager.empty"))
                    .font(UIDesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(manager.entries) { e in
                    HStack(spacing: 12) {
                        Text(e.parsedVersion)
                            .font(UIDesignSystem.Typography.monospacedCaption)
                            .frame(minWidth: 80, alignment: .leading)
                        Text((e.pathDisplay as NSString).lastPathComponent)
                            .font(UIDesignSystem.Typography.monospacedCaption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            manager.remove(id: e.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.bordered)
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }
    
    private func addFirmware() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = appLanguage.string("firmware_manager.select_file")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        let response = panel.runModal()
        guard response == .OK else { return }
        for url in panel.urls {
            _ = manager.add(url: url)
        }
    }
}
