import Foundation

/// 负责从应用内置资源或磁盘加载 / 保存产测规则的辅助方法
enum ProductionRulesLoader {
    /// 从应用 Bundle 中加载内置默认规则（`rules/default_production_rules.json`）
    static func loadBundledDefaultRules() throws -> ProductionRules {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "default_production_rules", withExtension: "json", subdirectory: "rules") else {
            throw NSError(domain: "ProductionRulesLoader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "未找到内置规则文件 rules/default_production_rules.json"
            ])
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(ProductionRules.self, from: data)
    }
}

