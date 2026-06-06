import Foundation

enum SkillValidationSeverity: String {
    case warning
    case info

    var icon: String {
        switch self {
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

struct SkillValidationIssue: Identifiable, Hashable {
    let id: String
    let severity: SkillValidationSeverity
    let title: String
    let message: String
}

extension Skill {
    var validationIssues: [SkillValidationIssue] {
        var issues: [SkillValidationIssue] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = skillDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if !isRemote && !FileManager.default.fileExists(atPath: filePath) {
            issues.append(.init(
                id: "missing-file",
                severity: .warning,
                title: "Missing file",
                message: "The indexed path no longer exists on disk."
            ))
        }

        if frontmatter.isEmpty {
            issues.append(.init(
                id: "missing-frontmatter",
                severity: .warning,
                title: "Missing frontmatter",
                message: "Add YAML frontmatter so tools can read metadata consistently."
            ))
        }

        if trimmedName.isEmpty {
            issues.append(.init(
                id: "missing-name",
                severity: .warning,
                title: "Missing name",
                message: "Add a name field in frontmatter."
            ))
        }

        if itemKind == .skill && trimmedDescription.isEmpty {
            issues.append(.init(
                id: "missing-description",
                severity: .warning,
                title: "Missing description",
                message: "Add a short description explaining when the skill should be used."
            ))
        }

        if trimmedContent.isEmpty {
            issues.append(.init(
                id: "empty-content",
                severity: .warning,
                title: "Empty content",
                message: "Add instructions or remove this empty item."
            ))
        }

        if isReadOnly {
            issues.append(.init(
                id: "read-only",
                severity: .info,
                title: "Read-only",
                message: "This item comes from a plugin or bundled source and cannot be edited here."
            ))
        }

        return issues
    }

    var hasValidationWarnings: Bool {
        validationIssues.contains { $0.severity == .warning }
    }
}
