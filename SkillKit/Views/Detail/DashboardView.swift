import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @Query private var skills: [Skill]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Header block
                headerSection

                // Stats overview cards
                statsGridSection

                HStack(alignment: .top, spacing: 24) {
                    // Left Column: Recent Skills & Quick Actions
                    VStack(alignment: .leading, spacing: 24) {
                        recentSkillsSection
                        auditDiagnosticsSection
                        quickActionsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Right Column: Chart Analytics
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Platform Distribution")
                            .font(.headline)
                        analyticsChartSection
                    }
                    .frame(width: 280)
                    .padding(20)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }
            .padding(32)
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SkillKit Command Center")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text("One native workspace for the skills, rules, and agents scattered across your developer tools.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Stats Cards
    private var statsGridSection: some View {
        HStack(spacing: 16) {
            StatCard(
                title: "Total Skills & Rules",
                value: "\(skills.count)",
                icon: "doc.text.fill",
                gradient: Gradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)])
            )

            StatCard(
                title: "Starred Favorites",
                value: "\(skills.filter(\.isFavorite).count)",
                icon: "star.fill",
                gradient: Gradient(colors: [Color.yellow, Color.orange])
            )

            let toolCount = Set(skills.flatMap(\.toolSources)).count
            StatCard(
                title: "Active Platforms",
                value: "\(toolCount)",
                icon: "cpu.fill",
                gradient: Gradient(colors: [Color.teal, Color.green])
            )
        }
    }

    // MARK: - Recent Skills
    private var recentSkillsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)

            let sorted = skills.sorted(by: { $0.fileModifiedDate > $1.fileModifiedDate })
            let recents = Array(sorted.prefix(5))

            if recents.isEmpty {
                Text("No skills created yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(recents) { skill in
                        Button {
                            appState.selectedSkill = skill
                        } label: {
                            HStack {
                                Image(systemName: skill.itemKind.icon)
                                    .foregroundStyle(skill.toolSource.color)
                                    .font(.system(size: 14))
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name)
                                        .font(.body)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                    Text(skill.toolSource.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(skill.fileModifiedDate, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if skill != recents.last {
                            Divider()
                                .padding(.leading, 32)
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

    // MARK: - Quick Actions
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)

            HStack(spacing: 16) {
                ActionButton(
                    title: "Create Skill",
                    description: "Start a reusable skill instruction",
                    icon: "plus.circle.fill",
                    color: Color.accentColor
                ) {
                    appState.showingNewSkillSheet = true
                }
                ActionButton(
                    title: "Browse Registry",
                    description: "Install from the skills ecosystem",
                    icon: "globe.americas.fill",
                    color: Color.teal
                ) {
                    appState.sidebarFilter = .discover
                }
            }
        }
    }

    // MARK: - Chart Analytics
    private var analyticsChartSection: some View {
        Group {
            let data = toolBreakdown
            if data.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No platform stats available yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 180)
                .frame(maxWidth: .infinity)
            } else {
                Chart {
                    ForEach(data, id: \.tool.rawValue) { item in
                        BarMark(
                            x: .value("Count", item.count),
                            y: .value("Platform", item.tool.displayName)
                        )
                        .foregroundStyle(item.tool.color)
                        .annotation(position: .trailing) {
                            Text("\(item.count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(stroke: StrokeStyle(lineWidth: 0))
                }
                .frame(height: CGFloat(max(3, data.count)) * 34)
            }
        }
    }

    private struct ToolCount {
        let tool: ToolSource
        let count: Int
    }

    private var toolBreakdown: [ToolCount] {
        var counts: [ToolSource: Int] = [:]
        for skill in skills {
            for tool in skill.toolSources {
                counts[tool, default: 0] += 1
            }
        }
        return counts.map { ToolCount(tool: $0.key, count: $0.value) }
            .sorted(by: { $0.count > $1.count })
    }

    // MARK: - System Health Audit
    private var skillsWithIssues: [Skill] {
        skills.filter(\.hasValidationWarnings)
            .sorted(by: { $0.name < $1.name })
    }

    private var auditDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Health Audit")
                .font(.headline)

            let issues = skillsWithIssues
            if issues.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Healthy")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Text("All local skills and rules are fully compliant with agent metadata standards.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.green.opacity(0.15), lineWidth: 1)
                )
            } else {
                let issuesToShow = Array(issues.prefix(4))
                VStack(spacing: 0) {
                    ForEach(issuesToShow) { skill in
                        HStack {
                            Image(systemName: skill.itemKind.icon)
                                .foregroundStyle(skill.toolSource.color)
                                .font(.system(size: 14))
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)
                                
                                let warnings = skill.validationIssues.filter { $0.severity == .warning }
                                Text(warnings.map(\.title).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }

                            Spacer()

                            Button {
                                appState.sidebarFilter = .needsReview
                                appState.selectedSkill = skill
                            } label: {
                                Text("Resolve")
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
                        .contentShape(Rectangle())

                        if skill != issuesToShow.last {
                            Divider()
                                .padding(.leading, 32)
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
}

// MARK: - Subviews

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let gradient: Gradient
    
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(LinearGradient(gradient: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct ActionButton: View {
    let title: String
    let description: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.plain)
    }
}
