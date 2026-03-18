import Foundation

/// 负责从应用内置资源或磁盘加载 / 保存产测规则的辅助方法
enum ProductionRulesLoader {
    /// 从应用 Bundle 中加载内置默认规则（`default_production_rules.json`）
    static func loadBundledDefaultRules() throws -> ProductionRules {
        let bundle = Bundle.main
        // 先尝试从根目录加载（当前工程将 JSON 直接打到 Resources 根部）
        if let url = bundle.url(forResource: "default_production_rules", withExtension: "json") {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(ProductionRules.self, from: data)
        }
        // 兼容旧版本：若未来又改回放在 rules/ 子目录，则继续尝试该路径
        if let url = bundle.url(forResource: "default_production_rules", withExtension: "json", subdirectory: "rules") {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(ProductionRules.self, from: data)
        }

        // 两种路径都找不到则抛错，外层会回退到 FALLBACK
        throw NSError(domain: "ProductionRulesLoader", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "未找到内置规则文件 default_production_rules.json（根目录或 rules/ 子目录）"
        ])
    }
}

