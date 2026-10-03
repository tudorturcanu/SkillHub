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

        if !isRemote && !PathExistenceCache.fileExists(atPath: filePath) {
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

        if itemKind == .skill && !isReadOnly {
            issues.append(contentsOf: agentSkillSpecIssues)
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

    /// Breaks of the shared SKILL.md format rules (see `AgentSkillSpec`).
    private var agentSkillSpecIssues: [SkillValidationIssue] {
        var issues: [SkillValidationIssue] = []
        let frontmatterName = frontmatter["name", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let problems = AgentSkillSpec.nameProblems(frontmatterName)

        if !problems.isEmpty {
            issues.append(.init(
                id: "spec-name-format",
                severity: .warning,
                title: "Name breaks the skill format",
                message: "Agents expect a name like \"\(AgentSkillSpec.normalizedName(frontmatterName))\": \(AgentSkillSpec.describe(problems))."
            ))
        } else if !frontmatterName.isEmpty,
                  let folder = AgentSkillSpec.folderName(forSkillAt: filePath, isDirectory: isDirectory),
                  folder != frontmatterName {
            issues.append(.init(
                id: "spec-name-folder-mismatch",
                severity: .info,
                title: "Name doesn't match folder",
                message: "The name \"\(frontmatterName)\" differs from its folder \"\(folder)\"; agents expect the two to match."
            ))
        }

        let descriptionLength = frontmatter["description", default: ""].trimmingCharacters(in: .whitespacesAndNewlines).count
        if descriptionLength > AgentSkillSpec.maxDescriptionLength {
            issues.append(.init(
                id: "spec-description-length",
                severity: .warning,
                title: "Description too long",
                message: "The description is \(descriptionLength) characters; agents allow at most \(AgentSkillSpec.maxDescriptionLength) and may truncate or reject it."
            ))
        }

        return issues
    }

    var hasValidationWarnings: Bool {
        validationIssues.contains { $0.severity == .warning }
    }
}
