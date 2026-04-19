import Foundation
import Combine

/// 全局产测规则状态：唯一 truth source，底层来自 JSON（优先 Application Support 持久化，否则 bundle 默认）
final class ProductionRulesStore: ObservableObject {
    @Published private(set) var rules: ProductionRules

    /// 外部 JSON 导入成功后追加一份时间戳快照，便于回溯；超出数量删最旧（与 `current_production_rules.json` 并行保留）
    private static let importBackupSubdirectory = "import_backups"
    private static let importBackupRetention = 30

    /// 与 `persistCurrentRulesToDisk` 使用相同路径：`Application Support/BOG Tool/Rules/current_production_rules.json`
    private static func persistedRulesFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport
            .appendingPathComponent("BOG Tool", isDirectory: true)
            .appendingPathComponent("Rules", isDirectory: true)
            .appendingPathComponent("current_production_rules.json", isDirectory: false)
    }

    private static func rulesRootDirectoryURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appendingPathComponent("BOG Tool", isDirectory: true).appendingPathComponent("Rules", isDirectory: true)
    }

    private static func importBackupsDirectoryURL() -> URL? {
        guard let rules = rulesRootDirectoryURL() else { return nil }
        return rules.appendingPathComponent(Self.importBackupSubdirectory, isDirectory: true)
    }

    /// 用户从外部文件导入规则成功后调用：写入一份带时间戳的副本，并裁剪旧备份。
    /// - Returns: 写入的备份文件 URL，失败时返回 nil（不影响导入主流程）。
    func saveImportBackupCopy(of rules: ProductionRules, importedFromFileName: String) -> URL? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rules)

            guard let backupDir = Self.importBackupsDirectoryURL() else { return nil }
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

            let stamp = Self.importBackupTimestampString()
            let base = Self.sanitizedImportBasename(importedFromFileName)
            let safeVer = Self.sanitizedFilenameComponent(rules.rulesVersion).replacingOccurrences(of: ".", with: "_")
            let uniq = UUID().uuidString.prefix(8)
            let fileName = "\(stamp)__\(base)__\(safeVer)__\(uniq).json"
            let fileURL = backupDir.appendingPathComponent(fileName, isDirectory: false)
            try data.write(to: fileURL, options: .atomic)

            Self.pruneImportBackups(keepingNewest: Self.importBackupRetention)
            NSLog("[Rules] Import backup saved: %@", fileURL.lastPathComponent)
            return fileURL
        } catch {
            NSLog("[Rules] Import backup failed: %@", error.localizedDescription)
            return nil
        }
    }

    private static func importBackupTimestampString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }

    private static func sanitizedFilenameComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "unnamed" }
        let invalid = CharacterSet(charactersIn: "/:\\?*<>|\"\n\r")
        return trimmed.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
    }

    private static func sanitizedImportBasename(_ importedFromFileName: String) -> String {
        let name = (importedFromFileName as NSString).lastPathComponent
        let withoutExt = (name as NSString).deletingPathExtension
        let s = sanitizedFilenameComponent(withoutExt)
        let clipped = String(s.prefix(80))
        return clipped.isEmpty ? "import" : clipped
    }

    private static func pruneImportBackups(keepingNewest: Int) {
        guard let dir = importBackupsDirectoryURL(),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let jsonFiles = urls.filter { $0.pathExtension.lowercased() == "json" }
        let sorted = jsonFiles.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return da > db
        }
        guard sorted.count > keepingNewest else { return }
        for url in sorted.dropFirst(keepingNewest) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 按修改时间最新的 `import_backups/*.json`（与裁剪逻辑一致）。
    static func newestImportBackupURL() -> URL? {
        guard let dir = importBackupsDirectoryURL(),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        let jsonFiles = urls.filter { $0.pathExtension.lowercased() == "json" }
        guard !jsonFiles.isEmpty else { return nil }
        return jsonFiles.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// 是否存在至少一份导入备份（用于 UI 按钮是否可选）。
    func hasImportBackupAvailable() -> Bool {
        Self.newestImportBackupURL() != nil
    }

    /// 将「最近一次导入备份」解码并 `apply`，写回 `current_production_rules.json`。失败返回 false。
    @discardableResult
    func restoreFromLatestImportBackup() -> Bool {
        guard let url = Self.newestImportBackupURL(),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode(ProductionRules.self, from: data) else {
            return false
        }
        apply(rules)
        NSLog("[Rules] Restored from latest import backup: %@", url.lastPathComponent)
        return true
    }

    /// 启动时：优先 `current_production_rules.json`；缺文件、解码失败则尝试 `import_backups` 中最新一份；再无则 bundle 默认。缺步 id 时按内置模板合并并写回磁盘。
    init() {
        let template: ProductionRules
        do {
            template = try ProductionRulesLoader.loadBundledDefaultRules()
        } catch {
            preconditionFailure("[Rules] Failed to load bundled default_production_rules.json: \(error.localizedDescription)")
        }

        var initial = template
        var loadedFromCurrentFile = false
        var recoveredFromImportBackup = false

        if let url = Self.persistedRulesFileURL(),
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(ProductionRules.self, from: data) {
                initial = decoded
                loadedFromCurrentFile = true
            } else {
                NSLog("[Rules] current_production_rules.json exists but failed to decode; trying latest import_backups JSON.")
            }
        }

        if !loadedFromCurrentFile,
           let backupURL = Self.newestImportBackupURL(),
           let data = try? Data(contentsOf: backupURL),
           let decoded = try? JSONDecoder().decode(ProductionRules.self, from: data) {
            initial = decoded
            recoveredFromImportBackup = true
            NSLog("[Rules] Loaded rules from latest import backup: %@", backupURL.lastPathComponent)
        }

        let templateIds = Set(template.steps.map(\.id))
        let declared = Set(initial.steps.map(\.id))
        let needsMerge = templateIds != declared
        if needsMerge {
            initial = initial.mergedWithTemplate(template)
        }

        self.rules = initial

        if needsMerge || recoveredFromImportBackup {
            persistCurrentRulesToDisk(initial)
        }

        if loadedFromCurrentFile {
            NSLog("[Rules] Loaded persisted current_production_rules.json (version=%@, steps=%d)", initial.rulesVersion, initial.steps.count)
            if needsMerge {
                NSLog("[Rules] Merged persisted rules with bundled template (step ids); wrote updated JSON to disk.")
            }
        } else if recoveredFromImportBackup {
            NSLog("[Rules] Recovered current_production_rules.json from latest import backup (version=%@, steps=%d).", initial.rulesVersion, initial.steps.count)
        } else {
            NSLog("[Rules] No persisted rules file or valid import backup; using bundled default_production_rules.json (version=%@, steps=%d)", template.rulesVersion, template.steps.count)
        }
    }

    /// 用新的规则整体替换当前规则（例如从规则页应用、从磁盘导入等）
    func apply(_ newRules: ProductionRules) {
        self.rules = newRules
        persistCurrentRulesToDisk(newRules)
    }

    /// 将当前规则快照写入应用支持目录，便于持久化当前产线配置
    private func persistCurrentRulesToDisk(_ rules: ProductionRules) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rules)

            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let rootDir = appSupport
                .appendingPathComponent("BOG Tool", isDirectory: true)
                .appendingPathComponent("Rules", isDirectory: true)
            try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
            let fileURL = rootDir.appendingPathComponent("current_production_rules.json", isDirectory: false)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 持久化失败不应影响运行时逻辑，这里静默忽略
        }
    }
}

