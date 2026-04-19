import Foundation
import Combine

/// 全局产测规则状态：唯一 truth source，底层来自 JSON（优先 Application Support 持久化，否则 bundle 默认）
final class ProductionRulesStore: ObservableObject {
    @Published private(set) var rules: ProductionRules

    /// 与 `persistCurrentRulesToDisk` 使用相同路径：`Application Support/BOG Tool/Rules/current_production_rules.json`
    private static func persistedRulesFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport
            .appendingPathComponent("BOG Tool", isDirectory: true)
            .appendingPathComponent("Rules", isDirectory: true)
            .appendingPathComponent("current_production_rules.json", isDirectory: false)
    }

    /// 启动时：若磁盘上已有上次保存的规则则加载；否则使用内置默认。若持久化 JSON 缺步/旧版 id，则按内置模板合并并写回磁盘（与产测页 `loadTestRules` 一致）。
    init() {
        let template: ProductionRules
        do {
            template = try ProductionRulesLoader.loadBundledDefaultRules()
        } catch {
            preconditionFailure("[Rules] Failed to load bundled default_production_rules.json: \(error.localizedDescription)")
        }

        var initial = template
        var loadedFromDisk = false
        if let url = Self.persistedRulesFileURL(),
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ProductionRules.self, from: data) {
            initial = decoded
            loadedFromDisk = true
        }

        let templateIds = Set(template.steps.map(\.id))
        let declared = Set(initial.steps.map(\.id))
        let needsMerge = templateIds != declared
        if needsMerge {
            initial = initial.mergedWithTemplate(template)
        }

        self.rules = initial

        if loadedFromDisk {
            NSLog("[Rules] Loaded persisted current_production_rules.json (version=%@, steps=%d)", initial.rulesVersion, initial.steps.count)
            if needsMerge {
                persistCurrentRulesToDisk(initial)
                NSLog("[Rules] Merged persisted rules with bundled template (step ids); wrote updated JSON to disk.")
            }
        } else {
            NSLog("[Rules] No persisted rules file; using bundled default_production_rules.json (version=%@, steps=%d)", template.rulesVersion, template.steps.count)
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

