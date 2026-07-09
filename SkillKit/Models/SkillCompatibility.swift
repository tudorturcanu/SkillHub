import Foundation
import SwiftUI

enum SkillCompatibilityStatus: Int {
    case compatible = 0
    case warning = 1
    case incompatible = 2

    var label: String {
        switch self {
        case .compatible: "Compatible"
        case .warning: "Warnings"
        case .incompatible: "Blocked"
        }
    }

    var icon: String {
        switch self {
        case .compatible: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .incompatible: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .compatible: .green
        case .warning: .orange
        case .incompatible: .red
        }
    }
}

struct SkillCompatibilityFinding: Identifiable, Hashable {
    let id: String
    let message: String
    let status: SkillCompatibilityStatus
}

struct SkillCompatibilityReport: Identifiable, Hashable {
    let id: String
    let targetName: String
    let status: SkillCompatibilityStatus
    let findings: [SkillCompatibilityFinding]
}

extension Skill {
    var compatibilityReports: [SkillCompatibilityReport] {
        AgentTarget.all.map { target in
            compatibilityReport(for: target)
        }
    }

    private func compatibilityReport(for target: AgentTarget) -> SkillCompatibilityReport {
        var findings: [SkillCompatibilityFinding] = []

        if itemKind == .rule {
            findings.append(.init(
                id: "rule-target",
                message: "\(target.displayName) may not load rule files from its skills directory.",
                status: .warning
            ))
        }

        if target.skillFileName == "SKILL.md", !isDirectory {
            findings.append(.init(
                id: "loose-file",
                message: "This target expects a skill folder containing SKILL.md.",
                status: .warning
            ))
        }

        if frontmatter["name", default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(.init(
                id: "missing-name",
                message: "Missing frontmatter name may make registry display inconsistent.",
                status: .warning
            ))
        }

        if itemKind == .skill && frontmatter["description", default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(.init(
                id: "missing-description",
                message: "Missing description reduces automatic skill selection quality.",
                status: .warning
            ))
        }

        if isReadOnly {
            findings.append(.init(
                id: "read-only",
                message: "Read-only items cannot be installed or reshaped from SkillKit.",
                status: .incompatible
            ))
        }

        if isRemote {
            findings.append(.init(
                id: "remote",
                message: "Remote items need to be synced locally before direct installation.",
                status: .warning
            ))
        }

        if content.count > 24_000 {
            findings.append(.init(
                id: "large-context",
                message: "Large instructions may exceed practical context budgets in some agents.",
                status: .warning
            ))
        }

        let status = findings.map(\.status).max(by: { $0.rawValue < $1.rawValue }) ?? .compatible
        return SkillCompatibilityReport(
            id: target.id,
            targetName: target.displayName,
            status: status,
            findings: findings
        )
    }
}
