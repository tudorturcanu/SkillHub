import Foundation
import SwiftUI

enum SkillHealthSeverity: String {
    case critical
    case warning
    case info

    var icon: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .info: .secondary
        }
    }

    var penalty: Int {
        switch self {
        case .critical: 30
        case .warning: 15
        case .info: 5
        }
    }
}

struct SkillHealthIssue: Identifiable, Hashable {
    let id: String
    let severity: SkillHealthSeverity
    let title: String
    let message: String
}

struct SkillHealthReport {
    let issues: [SkillHealthIssue]

    var score: Int {
        max(0, 100 - issues.reduce(0) { $0 + $1.severity.penalty })
    }

    var rating: String {
        switch score {
        case 90...100: "Healthy"
        case 70..<90: "Good"
        case 40..<70: "Needs Review"
        default: "Poor"
        }
    }

    var topSeverity: SkillHealthSeverity? {
        if issues.contains(where: { $0.severity == .critical }) { return .critical }
        if issues.contains(where: { $0.severity == .warning }) { return .warning }
        if issues.contains(where: { $0.severity == .info }) { return .info }
        return nil
    }
}

extension Skill {
    var healthReport: SkillHealthReport {
        var issues: [SkillHealthIssue] = validationIssues.map { issue in
            SkillHealthIssue(
                id: "validation-\(issue.id)",
                severity: issue.severity == .warning ? .warning : .info,
                title: issue.title,
                message: issue.message
            )
        }

        let scan = securityScan
        if !scan.isClean {
            let severity: SkillHealthSeverity = scan.riskScore >= 50 ? .critical : .warning
            issues.append(.init(
                id: "security-findings",
                severity: severity,
                title: "Security findings",
                message: "\(scan.rating): \(scan.summaryText)"
            ))
        }

        let age = Date.now.timeIntervalSince(fileModifiedDate)
        if age > 180 * 24 * 60 * 60 {
            issues.append(.init(
                id: "stale",
                severity: .info,
                title: "Stale item",
                message: "This item has not changed in more than 180 days."
            ))
        }

        if content.count > 24_000 {
            issues.append(.init(
                id: "oversized",
                severity: .warning,
                title: "Oversized prompt",
                message: "Large instructions are harder to inspect and may consume significant context."
            ))
        }

        if !frontmatter.isEmpty && frontmatter["description", default: ""].trimmingCharacters(in: .whitespacesAndNewlines).count < 12 {
            issues.append(.init(
                id: "weak-description",
                severity: .info,
                title: "Weak description",
                message: "Use a clear trigger-oriented description so agents know when to load this item."
            ))
        }

        return SkillHealthReport(issues: issues)
    }
}
