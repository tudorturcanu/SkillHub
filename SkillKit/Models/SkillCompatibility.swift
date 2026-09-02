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

/// Whether this skill is already present in a target's skills directory.
enum SkillInstallState: Hashable {
    /// The skill's own file lives inside the target's skills directory.
    case source
    /// A symlink in the target's skills directory points at this skill.
    case installedLink
    /// A separate copy exists in the target's skills directory.
    case installedCopy
    case notInstalled
    /// The target's skills directory can't load this kind of item (rules).
    case unsupportedKind
    /// Remote / read-only items — no local directory to check.
    case unknown

    var label: String {
        switch self {
        case .source: "Installed (source)"
        case .installedLink: "Installed (linked)"
        case .installedCopy: "Installed (copy)"
        case .notInstalled: "Not installed"
        case .unsupportedKind: "Unsupported kind"
        case .unknown: "Unknown"
        }
    }

    var icon: String {
        switch self {
        case .source, .installedLink, .installedCopy: "checkmark.circle"
        case .notInstalled: "circle.dashed"
        case .unsupportedKind: "nosign"
        case .unknown: "questionmark.circle"
        }
    }

    var isInstalled: Bool {
        switch self {
        case .source, .installedLink, .installedCopy: true
        default: false
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
    var installState: SkillInstallState = .unknown
    /// Targets folded into this row (only set on a collapsed summary row).
    var collapsedTargetNames: [String] = []

    /// Everything that matters for "do these targets agree?".
    fileprivate var agreementKey: String {
        let ids = findings.map { "\($0.id)=\($0.status.rawValue)" }.joined(separator: ",")
        return "\(status.rawValue)|\(installState)|\(ids)"
    }
}

/// The per-target compatibility matrix, already collapsed when every target
/// agrees. `note` explains fallbacks (no installed agents) or collapsing.
struct SkillCompatibilityMatrix {
    let rows: [SkillCompatibilityReport]
    let note: String?
    let isCollapsed: Bool
    let targetCount: Int

    var summaryStatus: SkillCompatibilityStatus {
        rows.map(\.status).max(by: { $0.rawValue < $1.rawValue }) ?? .compatible
    }
}

extension Skill {
    /// One report per installed agent (all agents when none are detected).
    /// Does filesystem checks — cache the result in view state rather than
    /// calling it from a hot `body`.
    var compatibilityReports: [SkillCompatibilityReport] {
        compatibilityTargets.targets.map { compatibilityReport(for: $0) }
    }

    /// `compatibilityReports` collapsed to a single row when all targets agree.
    var compatibilityMatrix: SkillCompatibilityMatrix {
        let (targets, fallbackNote) = compatibilityTargets
        let reports = targets.map { compatibilityReport(for: $0) }

        guard reports.count > 1,
              let first = reports.first,
              reports.allSatisfy({ $0.agreementKey == first.agreementKey })
        else {
            return SkillCompatibilityMatrix(
                rows: reports,
                note: fallbackNote,
                isCollapsed: false,
                targetCount: reports.count
            )
        }

        let names = reports.map(\.targetName)
        let summary = SkillCompatibilityReport(
            id: "all-targets",
            targetName: "All \(reports.count) agents",
            status: first.status,
            findings: first.findings,
            installState: first.installState,
            collapsedTargetNames: names
        )
        let collapseNote = "\(names.joined(separator: ", ")) all report the same result."
        return SkillCompatibilityMatrix(
            rows: [summary],
            note: fallbackNote.map { "\($0) \(collapseNote)" } ?? collapseNote,
            isCollapsed: true,
            targetCount: reports.count
        )
    }

    private var compatibilityTargets: (targets: [AgentTarget], note: String?) {
        let installed = AgentTarget.installed
        if installed.isEmpty {
            return (AgentTarget.all, "No agent installs detected — showing every known target.")
        }
        return (installed, nil)
    }

    private func compatibilityReport(for target: AgentTarget) -> SkillCompatibilityReport {
        var findings: [SkillCompatibilityFinding] = []
        var installState: SkillInstallState = .unknown

        let fileName = (filePath as NSString).lastPathComponent
        let skillDirName = URL(fileURLWithPath: filePath).deletingLastPathComponent().lastPathComponent

        if itemKind == .rule {
            installState = .unsupportedKind
            findings.append(.init(
                id: "rule-target",
                message: "\(target.displayName) loads skills from \(abbreviated(target.globalSkillsDir)); rule files are not picked up there.",
                status: .warning
            ))
        }

        if itemKind == .skill {
            if !isDirectory {
                findings.append(.init(
                    id: "loose-file",
                    message: "\(target.displayName) expects a skill folder containing \(target.skillFileName); this is a loose \(fileName) file.",
                    status: .warning
                ))
            } else if fileName != target.skillFileName {
                findings.append(.init(
                    id: "file-name",
                    message: "\(target.displayName) expects \(target.skillFileName); this skill's file is named \(fileName).",
                    status: .warning
                ))
            }
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

        if itemKind == .skill, !isRemote, !isReadOnly {
            let skillsDir = target.expandedSkillsDir
            let candidate = isDirectory ? "\(skillsDir)/\(skillDirName)" : "\(skillsDir)/\(fileName)"

            if filePath.hasPrefix(skillsDir + "/") {
                installState = .source
            } else if PathExistenceCache.fileExists(atPath: candidate) {
                installState = isLinked(candidate: candidate) ? .installedLink : .installedCopy
            } else {
                installState = .notInstalled
                if !PathExistenceCache.fileExists(atPath: skillsDir) {
                    findings.append(.init(
                        id: "skills-dir-missing",
                        message: "\(abbreviated(target.globalSkillsDir)) does not exist yet; it will be created on install.",
                        status: .compatible
                    ))
                }
            }
        }

        let status = findings.map(\.status).max(by: { $0.rawValue < $1.rawValue }) ?? .compatible
        return SkillCompatibilityReport(
            id: target.id,
            targetName: target.displayName,
            status: status,
            findings: findings,
            installState: installState
        )
    }

    /// `candidate` (which exists) is a symlink — or a directory reached through
    /// one — that resolves to this skill, rather than an independent copy.
    private func isLinked(candidate: String) -> Bool {
        let fm = FileManager.default
        let resolvedCandidate = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        let ownDirs = Set(([filePath] + installedPaths).map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().resolvingSymlinksInPath().path
        })
        let ownFiles = Set(([filePath] + installedPaths).map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        })
        if ownDirs.contains(resolvedCandidate) || ownFiles.contains(resolvedCandidate) { return true }
        return (try? fm.destinationOfSymbolicLink(atPath: candidate)) != nil
    }

    private func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: AppPaths.userHomeDirectory, with: "~")
    }
}
