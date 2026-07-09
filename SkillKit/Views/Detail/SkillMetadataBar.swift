import SwiftUI
import SwiftData

struct SkillMetadataBar: View {
    @Bindable var skill: Skill
    var onRestoreSnapshot: (SkillVersionSnapshot) -> Void = { _ in }
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SkillCollection.sortOrder) private var allCollections: [SkillCollection]
    @AppStorage("securityScanningEnabled") private var securityScanningEnabled = true
    @State private var showingCollectionPicker = false
    @State private var showingHealth = false
    @State private var showingCompatibility = false
    @State private var showingHistory = false
    @State private var showingValidationIssues = false
    @State private var showingSecurity = false
    @State private var deepScanResult: SecurityScanResult?

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(skill.toolSources) { tool in
                    ToolIcon(tool: tool, size: 14)
                }
            }
            .help(installedPathsSummary)

            Divider().frame(height: 16)

            if skill.isRemote, let server = skill.remoteServer {
                Label {
                    Text(server.label)
                } icon: {
                    Image(systemName: "server.rack")
                }
                .font(.caption)
                .foregroundStyle(.indigo)

                Divider().frame(height: 16)
            }

            Text(skill.isRemote ? (skill.remotePath ?? "") : displayPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(skill.isRemote ? (skill.remotePath ?? "") : installedPathsSummary)

            Divider().frame(height: 16)

            Text(formattedSize)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            Text("\(characterCount) chars / \(wordCount) words / ~\(tokenCount) tokens")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            healthStatusButton

            Divider().frame(height: 16)

            compatibilityStatusButton

            Divider().frame(height: 16)

            validationStatusButton

            Divider().frame(height: 16)

            if securityScanningEnabled {
                securityStatusButton

                Divider().frame(height: 16)
            }

            versionHistoryButton

            Divider().frame(height: 16)

            Button {
                showingCollectionPicker.toggle()
            } label: {
                Image(systemName: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingCollectionPicker) {
                collectionPickerContent
            }

            Spacer()

            Text(skill.fileModifiedDate.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var displayPath: String {
        let additionalCount = max(0, displayInstalledPaths.count - 1)
        let suffix = additionalCount > 0 ? " (+\(additionalCount))" : ""
        return abbreviatedFilePath + suffix
    }

    private var abbreviatedFilePath: String {
        skill.filePath.replacingOccurrences(
            of: AppPaths.userHomeDirectory,
            with: "~"
        )
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(skill.fileSize), countStyle: .file)
    }

    private var installedPathsSummary: String {
        displayInstalledPaths
            .map { $0.replacingOccurrences(of: AppPaths.userHomeDirectory, with: "~") }
            .joined(separator: "\n")
    }

    private var displayInstalledPaths: [String] {
        let otherPaths = skill.installedPaths
            .filter { $0 != skill.filePath }
            .sorted()
        return [skill.filePath] + otherPaths
    }

    private var wordCount: Int {
        skill.content.split { $0.isWhitespace || $0.isNewline }.count
    }

    private var characterCount: Int {
        skill.content.count
    }

    private var tokenCount: Int {
        Int(Double(wordCount) / 0.75)
    }

    private var compatibilitySummaryStatus: SkillCompatibilityStatus {
        skill.compatibilityReports
            .map(\.status)
            .max(by: { $0.rawValue < $1.rawValue }) ?? .compatible
    }

    @ViewBuilder
    private var healthStatusButton: some View {
        let report = skill.healthReport
        Button {
            showingHealth.toggle()
        } label: {
            Label {
                Text("\(report.score)")
                    .monospacedDigit()
            } icon: {
                Image(systemName: report.topSeverity?.icon ?? "heart.fill")
            }
            .font(.caption)
            .foregroundStyle(report.topSeverity?.color ?? .green)
        }
        .buttonStyle(.plain)
        .help("\(report.rating) health score: \(report.score)/100")
        .popover(isPresented: $showingHealth) {
            SkillHealthView(report: report)
        }
    }

    @ViewBuilder
    private var compatibilityStatusButton: some View {
        let status = compatibilitySummaryStatus
        Button {
            showingCompatibility.toggle()
        } label: {
            Image(systemName: status.icon)
                .font(.caption)
                .foregroundStyle(status.color)
        }
        .buttonStyle(.plain)
        .help("Agent compatibility: \(status.label)")
        .popover(isPresented: $showingCompatibility) {
            CompatibilityMatrixView(reports: skill.compatibilityReports)
        }
    }

    @ViewBuilder
    private var versionHistoryButton: some View {
        let snapshots = SkillVersionHistory.snapshots(for: skill)
        Button {
            showingHistory.toggle()
        } label: {
            Label {
                Text("\(snapshots.count)")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.caption)
            .foregroundStyle(snapshots.isEmpty ? Color.secondary : Color.blue)
        }
        .buttonStyle(.plain)
        .help("\(snapshots.count) saved version\(snapshots.count == 1 ? "" : "s")")
        .popover(isPresented: $showingHistory) {
            VersionHistoryView(
                snapshots: snapshots,
                onRestore: { snapshot in
                    onRestoreSnapshot(snapshot)
                    showingHistory = false
                }
            )
        }
    }

    @ViewBuilder
    private var validationStatusButton: some View {
        let warnings = skill.validationIssues.filter { $0.severity == .warning }

        Button {
            showingValidationIssues.toggle()
        } label: {
            Image(systemName: warnings.isEmpty ? "checkmark.seal" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(warnings.isEmpty ? .green : .orange)
        }
        .buttonStyle(.plain)
        .help(warnings.isEmpty ? "No validation warnings" : "\(warnings.count) validation warning\(warnings.count == 1 ? "" : "s")")
        .popover(isPresented: $showingValidationIssues) {
            ValidationIssuesView(issues: skill.validationIssues)
        }
    }

    /// Active scan: the deep (file-aware) result once requested, else the
    /// fast in-memory body scan.
    private var activeScan: SecurityScanResult {
        deepScanResult ?? skill.securityScan
    }

    @ViewBuilder
    private var securityStatusButton: some View {
        let result = activeScan
        Button {
            showingSecurity.toggle()
        } label: {
            Image(systemName: result.isClean ? "shield" : (result.topSeverity?.icon ?? "shield.lefthalf.filled"))
                .font(.caption)
                .foregroundStyle(result.isClean ? .green : (result.topSeverity?.color ?? .secondary))
        }
        .buttonStyle(.plain)
        .help(result.isClean ? "No security findings" : "\(result.rating) · \(result.summaryText)")
        .popover(isPresented: $showingSecurity) {
            SecurityFindingsView(
                result: activeScan,
                canDeepScan: skill.isDirectory && !skill.isRemote,
                onDeepScan: { deepScanResult = skill.deepSecurityScan() }
            )
        }
    }

    private var collectionPickerContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Collections").font(.headline).padding(.bottom, 4)
            ForEach(allCollections) { collection in
                let isAssigned = skill.collections.contains(where: { $0.name == collection.name })
                Button {
                    if isAssigned {
                        skill.collections.removeAll { $0.name == collection.name }
                    } else {
                        skill.collections.append(collection)
                    }
                    try? modelContext.save()
                } label: {
                    HStack {
                        Image(systemName: collection.icon)
                        Text(collection.name)
                        Spacer()
                        if isAssigned {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if allCollections.isEmpty {
                Text("No collections yet")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding()
        .frame(width: 200)
    }
}

private struct SecurityFindingsView: View {
    let result: SecurityScanResult
    let canDeepScan: Bool
    let onDeepScan: () -> Void
    @State private var didDeepScan = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Security Scan")
                        .font(.headline)
                    Text(result.isClean ? "Static scan found no risky patterns" : result.summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                riskBadge
            }

            if result.isClean {
                Label("No findings", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    securitySummaryRow(
                        icon: "scope",
                        title: "Categories",
                        value: result.categorySummaryText
                    )
                    securitySummaryRow(
                        icon: result.topSeverity?.icon ?? "exclamationmark.triangle.fill",
                        title: "Strongest signal",
                        value: result.primaryConcernText
                    )
                    securitySummaryRow(
                        icon: "number",
                        title: "Score",
                        value: "\(result.riskScore) / 100"
                    )
                    securitySummaryRow(
                        icon: "function",
                        title: "Why this score",
                        value: result.scoreBreakdownText
                    )
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(result.findings.sorted { $0.severity > $1.severity }) { finding in
                            findingRow(finding)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            if canDeepScan {
                Divider()
                Button {
                    onDeepScan()
                    didDeepScan = true
                } label: {
                    Label(
                        didDeepScan ? "Re-scan bundled scripts" : "Scan bundled scripts",
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            Text("Static heuristic scan — flags risky patterns, not a guarantee. Review skills from untrusted sources yourself.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }

    private var riskBadge: some View {
        Text(result.isClean ? result.rating : "\(result.rating) · \(result.findingCountText)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(result.isClean ? .green : (result.topSeverity?.color ?? .secondary))
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background((result.topSeverity?.color ?? .green).opacity(0.12), in: Capsule())
    }

    private func securitySummaryRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func findingRow(_ finding: SecurityFinding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.severity.icon)
                .foregroundStyle(finding.severity.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.title)
                        .font(.subheadline.weight(.semibold))
                    if finding.heuristic {
                        Text("heuristic")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text("\(finding.category.rawValue) · line \(finding.lineNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("+\(finding.severity.weight) \(finding.severity.label.lowercased()) severity points")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !finding.snippet.isEmpty {
                    Text(finding.snippet)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

private struct ValidationIssuesView: View {
    let issues: [SkillValidationIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Validation")
                .font(.headline)

            if issues.isEmpty {
                Label("No warnings", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: issue.severity.icon)
                            .foregroundStyle(issue.severity == .warning ? .orange : .secondary)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                                .font(.subheadline.weight(.semibold))
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 280, alignment: .leading)
    }
}

private struct SkillHealthView: View {
    let report: SkillHealthReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Health")
                        .font(.headline)
                    Text(report.rating)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(report.score)/100")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(report.topSeverity?.color ?? .green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((report.topSeverity?.color ?? .green).opacity(0.12), in: Capsule())
            }

            if report.issues.isEmpty {
                Label("No health issues", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                ForEach(report.issues) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: issue.severity.icon)
                            .foregroundStyle(issue.severity.color)
                            .frame(width: 16)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                                .font(.subheadline.bold())
                            Text(issue.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }
}

private struct CompatibilityMatrixView: View {
    let reports: [SkillCompatibilityReport]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compatibility")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(reports) { report in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(report.targetName, systemImage: report.status.icon)
                                    .foregroundStyle(report.status.color)
                                Spacer()
                                Text(report.status.label)
                                    .font(.caption.bold())
                                    .foregroundStyle(report.status.color)
                            }

                            if report.findings.isEmpty {
                                Text("No compatibility warnings detected.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(report.findings) { finding in
                                    Label(finding.message, systemImage: finding.status.icon)
                                        .font(.caption)
                                        .foregroundStyle(finding.status.color)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding()
        .frame(width: 360, alignment: .leading)
    }
}

private struct VersionHistoryView: View {
    let snapshots: [SkillVersionSnapshot]
    let onRestore: (SkillVersionSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version History")
                .font(.headline)

            if snapshots.isEmpty {
                ContentUnavailableView(
                    "No Versions",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Snapshots are created before saves.")
                )
                .frame(height: 160)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(snapshots) { snapshot in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshot.displayTitle)
                                        .font(.subheadline.bold())
                                    Text(snapshot.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\(snapshot.content.count) chars")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                Button("Restore") {
                                    onRestore(snapshot)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding()
        .frame(width: 340, alignment: .leading)
    }
}
