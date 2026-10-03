import Foundation

/// A parsed library search.
///
/// - Words are matched independently, so `pdf tools` finds an item that
///   mentions both anywhere, in any order.
/// - `"exact phrase"` keeps words together.
/// - A leading `-` excludes: `-draft`, `-"work in progress"`, `-is:rule`.
/// - `tool:cursor` keeps items installed for a tool (by id or display name).
/// - `is:` (or `kind:`) narrows by type or state: `skill`, `rule`, `favorite`,
///   `local`, `remote`, `global`, `project`, `editable`, `readonly`.
///
/// Any other `key:value` is searched as plain text, so URLs and metadata
/// such as `model: opus` still work as they did before.
struct SkillSearchQuery: Equatable {
    struct Term: Equatable {
        let text: String
        let negated: Bool
    }

    enum Flag: String, CaseIterable {
        case skill, rule, favorite, local, remote, global, project, editable, readonly

        init?(token: String) {
            switch token.lowercased() {
            case "fav", "favorite", "favourite", "starred": self = .favorite
            case "read-only", "readonly", "plugin": self = .readonly
            case "skills": self = .skill
            case "rules": self = .rule
            default:
                guard let flag = Flag(rawValue: token.lowercased()) else { return nil }
                self = flag
            }
        }
    }

    enum Filter: Equatable {
        case tool(String)
        case flag(Flag)
    }

    struct Condition: Equatable {
        let filter: Filter
        let negated: Bool
    }

    private(set) var terms: [Term] = []
    private(set) var conditions: [Condition] = []

    var isEmpty: Bool { terms.isEmpty && conditions.isEmpty }

    init(_ raw: String) {
        for (token, quoted) in Self.tokenize(raw) {
            var text = token
            var negated = false
            if text.hasPrefix("-") && text.count > 1 {
                negated = true
                text.removeFirst()
            }
            if !quoted, let filter = Self.filter(from: text) {
                conditions.append(Condition(filter: filter, negated: negated))
            } else if !text.isEmpty {
                terms.append(Term(text: text, negated: negated))
            }
        }
    }

    private static func filter(from token: String) -> Filter? {
        guard let colon = token.firstIndex(of: ":") else { return nil }
        let key = token[..<colon].lowercased()
        let value = String(token[token.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch key {
        case "tool", "agent": return .tool(value)
        case "is", "kind", "type": return Flag(token: value).map(Filter.flag)
        default: return nil
        }
    }

    /// Splits on whitespace, keeping `"quoted runs"` (and `-"quoted runs"`)
    /// together. An unclosed quote runs to the end of the text.
    private static func tokenize(_ raw: String) -> [(String, Bool)] {
        var tokens: [(String, Bool)] = []
        var current = ""
        var inQuotes = false
        var wasQuoted = false

        func flush() {
            if !current.isEmpty && current != "-" { tokens.append((current, wasQuoted)) }
            current = ""
            wasQuoted = false
        }

        for character in raw {
            if character == "\"" {
                if inQuotes { inQuotes = false } else if current.isEmpty || current == "-" {
                    inQuotes = true
                    wasQuoted = true
                } else {
                    current.append(character)
                }
            } else if character.isWhitespace && !inQuotes {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }
}

extension Skill {
    /// Whether this item satisfies every term and condition of `query`,
    /// searching the fields `scope` selects.
    func matches(_ query: SkillSearchQuery, in scope: SkillSearchScope) -> Bool {
        for condition in query.conditions where satisfies(condition.filter) == condition.negated {
            return false
        }
        guard !query.terms.isEmpty else { return true }

        let fields = searchFields(for: scope)
        for term in query.terms {
            let found = fields.contains { $0.localizedCaseInsensitiveContains(term.text) }
            if found == term.negated { return false }
        }
        return true
    }

    private func searchFields(for scope: SkillSearchScope) -> [String] {
        switch scope {
        case .all: [name, skillDescription, content, filePath] + Array(frontmatter.values)
        case .title: [name]
        case .description: [skillDescription]
        case .content: [content]
        case .path: [filePath]
        case .metadata: Array(frontmatter.values)
        }
    }

    private func satisfies(_ filter: SkillSearchQuery.Filter) -> Bool {
        switch filter {
        case .tool(let value):
            if toolSourceDisplayName.localizedCaseInsensitiveContains(value) { return true }
            return toolSources.contains {
                $0.rawValue.localizedCaseInsensitiveContains(value)
                    || $0.displayName.localizedCaseInsensitiveContains(value)
            }
        case .flag(let flag):
            switch flag {
            case .skill: return itemKind == .skill
            case .rule: return itemKind == .rule
            case .favorite: return isFavorite
            case .local: return !isRemote
            case .remote: return isRemote
            case .global: return isGlobal
            case .project: return !isGlobal
            case .editable: return !isReadOnly
            case .readonly: return isReadOnly
            }
        }
    }
}
