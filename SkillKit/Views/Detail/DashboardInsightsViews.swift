import SwiftUI

// MARK: - Context Budget

/// Per-agent estimate of the tokens the library occupies in every session.
struct ContextBudgetSection: View {
    @Environment(AppState.self) private var appState
    let skills: [Skill]

    var body: some View {
        let entries = ContextBudget.entries(for: skills.filter { !$0.isRemote }.map {
            ContextBudget.Item(
                tools: $0.toolSources,
                kind: $0.itemKind,
                name: $0.name,
                description: $0.skillDescription,
                content: $0.content
            )
        })
        let largest = max(entries.first?.totalTokens ?? 0, 1)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Context Budget")
                    .font(.headline)
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(ContextBudget.helpText)
            }
            Text("Tokens each agent loads at the start of every session.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if entries.isEmpty {
                Text("No local items yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    Button {
                        // Show what fills this agent's budget, biggest first.
                        appState.skillSortOption = .largest
                        appState.sidebarFilter = .tool(entry.tool)
                    } label: {
                        row(entry, largest: largest)
                    }
                    .buttonStyle(.plain)
                    .help(breakdown(entry) + ". Click to list them, largest first.")
                    .accessibilityLabel("\(entry.tool.displayName): \(breakdown(entry))")
                    .accessibilityHint("Lists this agent's items, largest first")
                }
            }
        }
    }

    private func row(_ entry: ContextBudget.Entry, largest: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.tool.displayName)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(ContextBudget.formatted(entry.totalTokens))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let width = proxy.size.width * CGFloat(entry.totalTokens) / CGFloat(largest)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(entry.tool.color)
                        .frame(width: width * share(entry.ruleTokens, of: entry))
                    Rectangle()
                        .fill(entry.tool.color.opacity(0.45))
                        .frame(width: width * share(entry.skillMetadataTokens, of: entry))
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
        }
        .contentShape(Rectangle())
    }

    private func share(_ tokens: Int, of entry: ContextBudget.Entry) -> CGFloat {
        entry.totalTokens == 0 ? 0 : CGFloat(tokens) / CGFloat(entry.totalTokens)
    }

    private func breakdown(_ entry: ContextBudget.Entry) -> String {
        var parts: [String] = []
        if entry.ruleCount > 0 {
            parts.append("\(entry.ruleCount) \(entry.ruleCount == 1 ? "rule" : "rules") loaded whole, \(ContextBudget.formatted(entry.ruleTokens)) tokens")
        }
        if entry.skillCount > 0 {
            parts.append("\(entry.skillCount) \(entry.skillCount == 1 ? "skill" : "skills") by name and description, \(ContextBudget.formatted(entry.skillMetadataTokens)) tokens")
        }
        return parts.joined(separator: "; ")
    }
}

// MARK: - Possible Duplicates

/// Pairs of items whose text is nearly identical, with a Compare shortcut.
struct DuplicateSkillsSection: View {
    let skills: [Skill]

    @State private var matches: [SkillSimilarity.Match] = []
    @State private var comparison: SkillComparison?

    private static let maxRows = 4

    var body: some View {
        let byID = Dictionary(skills.map { ($0.resolvedPath, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = matches.compactMap { match -> (match: SkillSimilarity.Match, left: Skill, right: Skill)? in
            guard let left = byID[match.leftID], let right = byID[match.rightID] else { return nil }
            return (match, left, right)
        }

        Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Possible Duplicates")
                            .font(.headline)
                        Spacer()
                        if rows.count > Self.maxRows {
                            Text("\(rows.count) pairs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(spacing: 0) {
                        let shown = Array(rows.prefix(Self.maxRows))
                        ForEach(shown.indices, id: \.self) { index in
                            let row = shown[index]
                            HStack(spacing: 10) {
                                Image(systemName: "doc.on.doc")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 14))
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(row.left.name) · \(row.right.name)")
                                        .font(.body)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Text("\(row.left.toolSourceDisplayName) and \(row.right.toolSourceDisplayName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text("\(Int((row.match.similarity * 100).rounded(.down)))% alike")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)

                                Button {
                                    comparison = SkillComparison(row.left, row.right)
                                } label: {
                                    Text("Compare")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 10)
                                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)

                            if index != shown.count - 1 {
                                Divider().padding(.leading, 32)
                            }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                    )
                }
            }
        }
        .task(id: signature) {
            let documents = skills.map { SkillSimilarity.Document(id: $0.resolvedPath, text: $0.content) }
            let found = await Task.detached(priority: .utility) {
                SkillSimilarity.matches(in: documents)
            }.value
            guard !Task.isCancelled else { return }
            matches = found
        }
        .sheet(item: $comparison) { comparison in
            SkillComparisonSheet(comparison: comparison) { self.comparison = nil }
        }
    }

    /// Changes whenever an item is added, removed or edited, so the pairwise
    /// scan only reruns when its answer could.
    private var signature: Int {
        var hasher = Hasher()
        for skill in skills {
            hasher.combine(skill.resolvedPath)
            hasher.combine(skill.fileModifiedDate)
            hasher.combine(skill.content.utf8.count)
        }
        return hasher.finalize()
    }
}
