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
    /// Unfiltered deep-scan result; suppressions are applied at display time so
    /// ignoring / un-ignoring a rule doesn't need another walk of the folder.
    @State private var deepScanResult: SecurityScanResult?
    /// Cached so the bar doesn't decode the full history JSON on every render.
    @State private var snapshotCount = 0
    /// Cached because building it stats each agent's skills directory.
    @State private var compatibilityMatrix: SkillCompatibilityMatrix?

    var body: some View {
        HStack(spacing: 8) {
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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Divider().frame(height: 16)

            Text("\(characterCount) chars / \(wordCount) words / \(TokenEstimator.label(for: skill.content))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help(TokenEstimator.helpText)

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
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear(perform: refreshCachedState)
        .onChange(of: skill.filePath) {
            // A different skill (or a moved one): nothing from the previous
            // one applies.
            deepScanResult = nil
            showingSecurity = false
            showingHistory = false
            showingCompatibility = false
            refreshCachedState()
        }
        .onChange(of: skill.fileModifiedDate) {
            // Saved / restored / rescanned: the deep scan and history are stale.
            deepScanResult = nil
            refreshCachedState()
        }
    }

    private func refreshCachedState() {
        snapshotCount = SkillVersionHistory.snapshotCount(for: skill)
        compatibilityMatrix = skill.compatibilityMatrix
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

    private var currentCompatibilityMatrix: SkillCompatibilityMatrix {
        compatibilityMatrix ?? skill.compatibilityMatrix
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
        let matrix = currentCompatibilityMatrix
        let status = matrix.summaryStatus
        Button {
            compatibilityMatrix = skill.compatibilityMatrix // fresh stats when opened
            showingCompatibility.toggle()
        } label: {
            Image(systemName: status.icon)
                .font(.caption)
                .foregroundStyle(status.color)
        }
        .buttonStyle(.plain)
        .help("Agent compatibility: \(status.label)")
        .popover(isPresented: $showingCompatibility) {
            CompatibilityMatrixView(matrix: currentCompatibilityMatrix)
        }
    }

    @ViewBuilder
    private var versionHistoryButton: some View {
        Button {
            showingHistory.toggle()
        } label: {
            Label {
                Text("\(snapshotCount)")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.caption)
            .foregroundStyle(snapshotCount == 0 ? Color.secondary : Color.blue)
        }
        .buttonStyle(.plain)
        .help("\(snapshotCount) saved version\(snapshotCount == 1 ? "" : "s")")
        .popover(isPresented: $showingHistory) {
            VersionHistoryView(
                skill: skill,
                canRestore: !skill.isReadOnly && !skill.isRemote,
                onRestore: { snapshot in
                    onRestoreSnapshot(snapshot)
                    showingHistory = false
                    snapshotCount = SkillVersionHistory.snapshotCount(for: skill)
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
    /// fast in-memory scan. Both have the user's suppressions applied.
    private var activeScan: SecurityScanResult {
        if let deepScanResult {
            return deepScanResult.excluding(ruleIDs: SecurityFindingSuppressions.shared.ruleIDs(for: skill.filePath))
        }
        return skill.securityScan
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
                skillPath: skill.filePath,
                baseResult: deepScanResult ?? SecurityScanner.scan(text: skill.securityScanSourceText),
                isDeepResult: deepScanResult != nil,
                canDeepScan: skill.isDirectory && !skill.isRemote,
                onDeepScan: { deepScanResult = skill.deepSecurityScan(applyingSuppressions: false) }
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

// MARK: - Security findings

private struct SecurityFindingsView: View {
    let skillPath: String
    /// Unfiltered result; suppressions are applied here so the popover
    /// updates live when a rule is ignored or restored.
    let baseResult: SecurityScanResult
    let isDeepResult: Bool
    let canDeepScan: Bool
    let onDeepScan: () -> Void
    @State private var showingIgnored = false

    private var suppressions: SecurityFindingSuppressions { .shared }

    private var filteredResult: SecurityScanResult {
        baseResult.excluding(ruleIDs: suppressions.ruleIDs(for: skillPath))
    }

    var body: some View {
        let result = filteredResult
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
                riskBadge(result)
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
                            findingRow(finding, ignored: false)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            if !result.suppressedFindings.isEmpty {
                ignoredSection(result.suppressedFindings)
            }

            if canDeepScan {
                Divider()
                Button {
                    onDeepScan()
                } label: {
                    Label(
                        isDeepResult ? "Re-scan bundled scripts" : "Scan bundled scripts",
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
        .frame(width: 340, alignment: .leading)
    }

    private func riskBadge(_ result: SecurityScanResult) -> some View {
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

    @ViewBuilder
    private func ignoredSection(_ suppressed: [SecurityFinding]) -> some View {
        let ruleIDs = Set(suppressed.map(\.ruleID)).sorted()
        Divider()
        DisclosureGroup(isExpanded: $showingIgnored) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(suppressed.sorted { $0.severity > $1.severity }) { finding in
                    findingRow(finding, ignored: true)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                Text("Ignored (\(suppressed.count)) — \(showingIgnored ? "Hide" : "Show")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore all") {
                    for id in ruleIDs {
                        suppressions.unsuppress(id, for: skillPath)
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .font(.caption2)
            }
        }
        .help("Findings ignored for this skill. They are excluded from the score.")
    }

    private func findingRow(_ finding: SecurityFinding, ignored: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.severity.icon)
                .foregroundStyle(ignored ? Color.secondary : finding.severity.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(finding.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ignored ? .secondary : .primary)
                    if finding.heuristic {
                        Text("heuristic")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                    Text(finding.ruleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Text("\(finding.category.rawValue) · \(finding.locationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !ignored {
                    Text("+\(finding.severity.weight) \(finding.severity.label.lowercased()) severity points")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !finding.snippet.isEmpty {
                    Text(finding.snippet)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                HStack(spacing: 10) {
                    if finding.isInMainFile {
                        Button {
                            NotificationCenter.default.post(
                                name: .jumpToEditorLine,
                                object: nil,
                                userInfo: ["line": finding.lineNumber]
                            )
                        } label: {
                            Label("Jump to line \(finding.lineNumber)", systemImage: "arrow.right.to.line")
                        }
                        .help("Select this line in the editor")
                    } else if let file = finding.file {
                        Button {
                            NotificationCenter.default.post(
                                name: .jumpToEditorLine,
                                object: nil,
                                userInfo: ["line": finding.lineNumber, "file": file]
                            )
                        } label: {
                            Label("Line \(finding.lineNumber) in \(file)", systemImage: "doc.text")
                        }
                        .help("This finding is in a bundled file, not the main skill file")
                    }

                    if ignored {
                        Button {
                            suppressions.unsuppress(finding.ruleID, for: skillPath)
                        } label: {
                            Label("Stop ignoring", systemImage: "eye")
                        }
                        .help("Show \(finding.ruleID) findings for this skill again")
                    } else {
                        Button {
                            suppressions.suppress(finding.ruleID, for: skillPath)
                        } label: {
                            Label("Ignore in this skill", systemImage: "eye.slash")
                        }
                        .help("Hide every \(finding.ruleID) finding for this skill and drop it from the score")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .font(.caption2)
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - Validation

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

// MARK: - Health

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

// MARK: - Compatibility

private struct CompatibilityMatrixView: View {
    let matrix: SkillCompatibilityMatrix

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compatibility")
                    .font(.headline)
                Spacer()
                Text("\(matrix.targetCount) agent\(matrix.targetCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let note = matrix.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(matrix.rows) { report in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(report.targetName, systemImage: report.status.icon)
                                    .foregroundStyle(report.status.color)
                                Spacer()
                                Text(report.status.label)
                                    .font(.caption.bold())
                                    .foregroundStyle(report.status.color)
                            }

                            Label(report.installState.label, systemImage: report.installState.icon)
                                .font(.caption)
                                .foregroundStyle(report.installState.isInstalled ? .green : .secondary)

                            if !report.collapsedTargetNames.isEmpty {
                                Text(report.collapsedTargetNames.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if report.findings.isEmpty {
                                Text("No compatibility warnings detected.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(report.findings) { finding in
                                    Label(finding.message, systemImage: finding.status.icon)
                                        .font(.caption)
                                        .foregroundStyle(finding.status == .compatible ? Color.secondary : finding.status.color)
                                        .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 380, alignment: .leading)
    }
}

// MARK: - Version history

private struct VersionHistoryView: View {
    let skill: Skill
    let canRestore: Bool
    let onRestore: (SkillVersionSnapshot) -> Void

    @State private var snapshots: [SkillVersionSnapshot] = []
    @State private var currentText = ""
    @State private var expandedSnapshotID: UUID?
    @State private var pendingRestore: SkillVersionSnapshot?

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
                            snapshotRow(snapshot)
                        }
                    }
                }
                .frame(maxHeight: expandedSnapshotID == nil ? 300 : 460)
            }
        }
        .padding()
        .frame(width: expandedSnapshotID == nil ? 340 : 560, alignment: .leading)
        .onAppear(perform: load)
        .confirmationDialog(
            "Restore this version?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRestore
        ) { snapshot in
            Button("Restore") {
                pendingRestore = nil
                onRestore(snapshot)
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: { snapshot in
            Text("The file will be replaced with the version from \(snapshot.displayTitle). A snapshot of the current text will be kept.")
        }
    }

    private func load() {
        snapshots = SkillVersionHistory.snapshots(for: skill)
        currentText = skill.securityScanSourceText
    }

    @ViewBuilder
    private func snapshotRow(_ snapshot: SkillVersionSnapshot) -> some View {
        let isExpanded = expandedSnapshotID == snapshot.id
        let isIdentical = snapshot.content == currentText
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expandedSnapshotID = isExpanded ? nil : snapshot.id
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snapshot.displayTitle)
                                .font(.subheadline.bold())
                            Text(snapshot.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(isIdentical ? "\(snapshot.content.count) chars · identical to current" : "\(snapshot.content.count) chars")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide the diff against the current text" : "Preview the diff against the current text")

                Spacer()

                Button("Restore") {
                    pendingRestore = snapshot
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canRestore || isIdentical)
                .help(canRestore ? "Replace the file with this version (after confirmation)" : "Read-only or remote items can't be restored here")
            }

            if isExpanded {
                DiffReviewPanel(
                    original: currentText,
                    proposed: snapshot.content,
                    onAccept: nil,
                    onReject: nil
                )
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
