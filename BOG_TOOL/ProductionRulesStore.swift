import Foundation
import Combine

/// 全局产测规则状态：唯一 truth source，底层来自 JSON（默认 bundle + 之后可扩展为磁盘持久化）
final class ProductionRulesStore: ObservableObject {
    @Published private(set) var rules: ProductionRules

    /// 简单的内存初始化：优先使用 bundle 默认规则；若失败则使用一个最小兜底配置
    init() {
        if let loaded = try? ProductionRulesLoader.loadBundledDefaultRules() {
            self.rules = loaded
            NSLog("[Rules] Loaded bundled default_production_rules.json (version=%@, steps=%d)", loaded.rulesVersion, loaded.steps.count)
        } else {
            // 兜底：不会在正常发布中使用，只为防止文件缺失导致崩溃
            self.rules = ProductionRules(
                schemaVersion: 1,
                rulesVersion: "FALLBACK",
                meta: .init(projectName: "UNKNOWN", author: "", createdAt: "", updatedAt: "", notes: ""),
                global: .init(
                    stepIntervalMs: 100,
                    skipFactoryResetAndDisconnectOnFail: false,
                    failurePolicy: .init(fatalDefault: Array(TestStep.stepIdsFatalOnFailure), overrides: [:])
                ),
                environment: .init(
                    bleScan: .init(
                        rssiFilterEnabled: false,
                        minRssiDbm: -100,
                        nameWhitelistEnabled: false,
                        nameWhitelistKeywords: [],
                        nameBlacklistKeywords: []
                    )
                ),
                steps: []
            )
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

