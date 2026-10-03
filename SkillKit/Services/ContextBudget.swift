import Foundation

/// Estimates how much of every session's context each agent spends on the
/// library before the user types anything.
///
/// Agents load a skill progressively: only its name and description sit in
/// context until the skill is triggered. Rules and instruction files are
/// loaded whole. Counts use `TokenEstimator`, so they are size hints, not
/// vendor-exact numbers.
enum ContextBudget {
    struct Item {
        let tools: [ToolSource]
        let kind: ItemKind
        let name: String
        let description: String
        let content: String
    }

    struct Entry: Identifiable, Equatable {
        let tool: ToolSource
        var skillCount = 0
        var ruleCount = 0
        /// Names and descriptions of skills, always in context.
        var skillMetadataTokens = 0
        /// Full bodies of rules, always in context.
        var ruleTokens = 0

        var id: String { tool.rawValue }
        var totalTokens: Int { skillMetadataTokens + ruleTokens }
    }

    static let helpText = "Skills cost only their name and description until they're used; rules are loaded whole. " + TokenEstimator.helpText

    /// One entry per tool that has items, largest total first.
    static func entries(for items: [Item]) -> [Entry] {
        var byTool: [ToolSource: Entry] = [:]
        for item in items {
            let tokens: Int
            switch item.kind {
            case .skill: tokens = TokenEstimator.estimate(item.name) + TokenEstimator.estimate(item.description)
            case .rule: tokens = TokenEstimator.estimate(item.content)
            }
            for tool in Set(item.tools) {
                var entry = byTool[tool] ?? Entry(tool: tool)
                switch item.kind {
                case .skill:
                    entry.skillCount += 1
                    entry.skillMetadataTokens += tokens
                case .rule:
                    entry.ruleCount += 1
                    entry.ruleTokens += tokens
                }
                byTool[tool] = entry
            }
        }
        return byTool.values.sorted {
            $0.totalTokens != $1.totalTokens
                ? $0.totalTokens > $1.totalTokens
                : $0.tool.displayName.localizedStandardCompare($1.tool.displayName) == .orderedAscending
        }
    }

    static func formatted(_ tokens: Int) -> String {
        tokens >= 1000 ? String(format: "~%.1fk", Double(tokens) / 1000) : "~\(tokens)"
    }
}
