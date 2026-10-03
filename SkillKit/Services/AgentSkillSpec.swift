import Foundation

/// The Agent Skills format rules that Claude Code, Codex and the other
/// SKILL.md readers share: a `name` of lowercase letters, digits and single
/// hyphens (at most 64 characters) that matches the skill's folder, and a
/// `description` of at most 1024 characters. Agents may refuse or silently
/// skip a skill that breaks them, so SkillKit flags these before they do.
enum AgentSkillSpec {
    static let maxNameLength = 64
    static let maxDescriptionLength = 1024

    enum NameProblem: Equatable {
        case tooLong(Int)
        case invalidCharacters
        case badHyphens
    }

    /// Every rule `name` breaks. Empty names are reported elsewhere.
    static func nameProblems(_ name: String) -> [NameProblem] {
        guard !name.isEmpty else { return [] }
        var problems: [NameProblem] = []
        if name.count > maxNameLength {
            problems.append(.tooLong(name.count))
        }
        if !name.unicodeScalars.allSatisfy(isAllowedNameScalar) {
            problems.append(.invalidCharacters)
        }
        if name.hasPrefix("-") || name.hasSuffix("-") || name.contains("--") {
            problems.append(.badHyphens)
        }
        return problems
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && nameProblems(name).isEmpty
    }

    /// The closest valid name: lowercased, accents folded, every run of other
    /// characters collapsed to one hyphen, and trimmed to 64 characters.
    /// Returns an empty string when nothing usable is left.
    static func normalizedName(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en_US_POSIX"))
            .lowercased()
        var result = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            if isAllowedNameScalar(scalar) && scalar != "-" {
                if pendingHyphen && !result.isEmpty { result.append("-") }
                pendingHyphen = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        if result.count > maxNameLength {
            result = String(result.prefix(maxNameLength))
            while result.hasSuffix("-") { result.removeLast() }
        }
        return result
    }

    /// The folder a SKILL.md-style skill lives in, which the spec says must
    /// equal its `name`. Nil for loose files, where the rule doesn't apply.
    static func folderName(forSkillAt filePath: String, isDirectory: Bool) -> String? {
        guard isDirectory else { return nil }
        let folder = URL(fileURLWithPath: filePath).deletingLastPathComponent().lastPathComponent
        return folder.isEmpty || folder == "/" ? nil : folder
    }

    /// The name the "Fix name" quick-fix writes: the folder name when that is
    /// itself valid (so name and folder end up matching), else the normalized name.
    static func suggestedName(for name: String, folderName: String?) -> String {
        if let folderName, isValidName(folderName) { return folderName }
        return normalizedName(name)
    }

    static func describe(_ problems: [NameProblem]) -> String {
        problems.map { problem in
            switch problem {
            case .tooLong(let count):
                "it is \(count) characters long (the limit is \(maxNameLength))"
            case .invalidCharacters:
                "it may only use lowercase letters, digits and hyphens"
            case .badHyphens:
                "it can't start or end with a hyphen or contain two in a row"
            }
        }
        .joined(separator: "; ")
    }

    private static func isAllowedNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
    }
}
