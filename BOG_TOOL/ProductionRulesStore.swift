import Foundation
import Combine

/// 全局产测规则状态：唯一 truth source，底层来自 JSON（默认 bundle + 之后可扩展为磁盘持久化）
final class ProductionRulesStore: ObservableObject {
    @Published private(set) var rules: ProductionRules

    /// 严格 JSON：必须成功加载 bundle 默认规则，否则直接失败，避免静默 fallback。
    init() {
        do {
            let loaded = try ProductionRulesLoader.loadBundledDefaultRules()
            self.rules = loaded
            NSLog("[Rules] Loaded bundled default_production_rules.json (version=%@, steps=%d)", loaded.rulesVersion, loaded.steps.count)
        } catch {
            preconditionFailure("[Rules] Failed to load bundled default_production_rules.json: \(error.localizedDescription)")
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

