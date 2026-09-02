import SwiftUI

struct DiscoverView: View {
    @State private var registry = SkillRegistry()
    @State private var searchText = "git"
    @State private var results: [SkillRegistry.RegistrySkill] = []
    @State private var selectedSkill: SkillRegistry.RegistrySkill?
    @State private var skillContent: String?
    @State private var selectedAgents: Set<String> = []
    @State private var isSearching = false
    @State private var isFetchingContent = false
    @State private var isInstalling = false
    @State private var searchError: String?
    @State private var previewError: String?
    @State private var installError: String?
    @State private var installSuccess = false
    @State private var searchTask: Task<Void, Never>?
    @State private var contentTask: Task<Void, Never>?
    @State private var installResetTask: Task<Void, Never>?
    @State private var sortOption: SortOption = .relevance
    /// Detected install targets. Probing them walks `PATH` and the filesystem, so it is
    /// done here (on appear / after an install) rather than in `body`, which re-evaluates
    /// on every keystroke in the search field.
    @State private var installedAgents: [AgentTarget] = []
    /// Per-target install state for the selected skill, keyed by `AgentTarget.id`.
    /// Refreshed alongside `installedAgents` and whenever the selected skill changes.
    @State private var targetInstallStates: [String: TargetInstallState] = [:]

    /// The filesystem facts a target card renders, sampled outside `body`.
    private struct TargetInstallState {
        let isInstalled: Bool
        let destinationPath: String
    }

    enum SortOption {
        case relevance
        case installs
    }

    private var sortedResults: [SkillRegistry.RegistrySkill] {
        switch sortOption {
        case .relevance:
            return results
        case .installs:
            return results.sorted { $0.installs > $1.installs }
        }
    }
    private let featuredQueries = ["swift", "testing", "xcode", "supabase", "docs", "git"]

    var body: some View {
        VStack(spacing: 0) {
            discoverHeader
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 16)

            Divider()

            HSplitView {
                resultsPane
                    .frame(minWidth: 260, idealWidth: 340)

                detailPane
                    .frame(minWidth: 340)
            }
        }
        .navigationTitle("Discover")
        .onAppear {
            refreshInstallTargets()
            // Installing a library item into every detected tool is surprising and can
            // create configuration directories the user never intended to manage.
            selectedAgents = installedAgents.contains(where: { $0.id == "agents" }) ? ["agents"] : []
            if results.isEmpty {
                debounceSearch(query: searchText)
            }
        }
        .onDisappear {
            searchTask?.cancel()
            contentTask?.cancel()
            installResetTask?.cancel()
        }
    }

    private var discoverHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "compass.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text("Discover Library")
                            .font(.system(size: 28, weight: .bold, design: .rounded))

                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text("Search the library, preview source skills, and install them into your local developer agents.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search library skills, tools, frameworks, or workflows...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        runSearch(query: searchText)
                    }

                Button {
                    runSearch(query: searchText)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Search registry")
                .accessibilityLabel("Search registry")
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .onChange(of: searchText) { _, newValue in
                debounceSearch(query: newValue)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(featuredQueries, id: \.self) { query in
                        Button {
                            searchText = query
                            runSearch(query: query)
                        } label: {
                            Label(query, systemImage: featuredIcon(for: query))
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.medium))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(searchText == query ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07), in: Capsule())
                                .foregroundStyle(searchText == query ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var resultsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(results.isEmpty ? "Library" : "\(results.count) Skills")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                
                if !results.isEmpty {
                    Picker("", selection: $sortOption) {
                        Text("Relevance").tag(SortOption.relevance)
                        Text("Most Installed").tag(SortOption.installs)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            if results.isEmpty && isSearching {
                ProgressView("Searching library...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty, let searchError {
                ContentUnavailableView {
                    Label("Couldn't reach the registry", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(searchError)
                } actions: {
                    Button("Retry") {
                        runSearch(query: searchText)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView {
                    Label("No Skills Found", systemImage: "compass")
                } description: {
                    Text(searchText.count < 2 ? "Type at least two characters to search." : "Try another topic or framework.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sortedResults) { skill in
                        Button {
                            selectSkill(skill)
                        } label: {
                            DiscoverResultRow(
                                skill: skill,
                                isSelected: selectedSkill?.id == skill.id
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }

            if let searchError, selectedSkill == nil, !results.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    InlineErrorView(message: searchError)
                    Button("Retry") {
                        runSearch(query: searchText)
                    }
                    .controlSize(.small)
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedSkill {
            skillDetail(selectedSkill)
        } else {
            ContentUnavailableView {
                Label("Select a Skill", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Preview library details and choose install targets.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func skillDetail(_ skill: SkillRegistry.RegistrySkill) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: platformIcon(for: skill.name))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(platformColor(for: skill.name))
                    .frame(width: 44, height: 44)
                    .background(platformColor(for: skill.name).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(skill.source)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("\(skill.formattedInstalls) installs")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())

                        HStack(spacing: 3) {
                            Image(systemName: "number")
                            Text(skill.skillId)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                        .textSelection(.enabled)
                    }
                    .font(.system(size: 11, weight: .bold))
                    .padding(.top, 4)
                }

                Spacer()
            }
            .padding(22)

            Divider()

            Group {
                if isFetchingContent {
                    ProgressView("Loading skill preview...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let skillContent {
                    SkillPreviewView(content: skillContent)
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .padding(16)
                } else if let previewError {
                    ContentUnavailableView {
                        Label("Preview Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(previewError)
                    } actions: {
                        Button("Retry") {
                            selectSkill(skill)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            installBar(skill: skill)
        }
    }

    private func installBar(skill: SkillRegistry.RegistrySkill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Install Targets")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !installedAgents.isEmpty {
                    Button(selectedAgents.count == installedAgents.count ? "Clear All" : "Select All") {
                        if selectedAgents.count == installedAgents.count {
                            selectedAgents.removeAll()
                        } else {
                            selectedAgents = Set(installedAgents.map(\.id))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 11, weight: .semibold))
                }
            }

            if installedAgents.isEmpty {
                Text("No supported local agents were detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 6)], spacing: 6) {
                        ForEach(installedAgents) { agent in
                            AgentTargetCard(
                                agent: agent,
                                isSelected: selectedAgents.contains(agent.id),
                                isInstalled: targetInstallStates[agent.id]?.isInstalled ?? false,
                                destinationPath: targetInstallStates[agent.id]?.destinationPath ?? ""
                            ) {
                                toggleAgent(agent)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 130)
            }

            HStack {
                if let installError {
                    InlineErrorView(message: installError)
                }

                if installSuccess {
                    Label("Successfully Installed!", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                }

                Spacer()

                Button {
                    if let skillContent {
                        performInstall(content: skillContent, skillName: skill.skillId)
                    }
                } label: {
                    if isInstalling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Install Skill", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .disabled(skillContent == nil || selectedAgents.isEmpty || isInstalling || installSuccess)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.3))
    }

    /// Re-probes which agents are present and what is already installed for the selected
    /// skill. Deliberately called from event handlers only — `AgentTarget.installed` walks
    /// `PATH` and several directories, which must never happen during view evaluation.
    private func refreshInstallTargets() {
        installedAgents = AgentTarget.installed
        refreshTargetInstallStates(for: selectedSkill)
    }

    private func refreshTargetInstallStates(for skill: SkillRegistry.RegistrySkill?) {
        guard let skill else {
            targetInstallStates = [:]
            return
        }
        var states: [String: TargetInstallState] = [:]
        for agent in installedAgents {
            states[agent.id] = TargetInstallState(
                isInstalled: registry.isInstalled(skillName: skill.skillId, target: agent),
                destinationPath: displayPath(registry.installedDestination(for: skill.skillId, target: agent))
            )
        }
        targetInstallStates = states
    }

    private func debounceSearch(query: String) {
        searchTask?.cancel()

        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else {
            results = []
            selectedSkill = nil
            skillContent = nil
            searchError = nil
            previewError = nil
            installError = nil
            isSearching = false
            return
        }

        isSearching = true
        searchError = nil

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: normalized)
        }
    }

    private func runSearch(query: String) {
        searchTask?.cancel()
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else { return }
        isSearching = true
        searchError = nil
        searchTask = Task {
            await performSearch(query: normalized)
        }
    }

    private func performSearch(query: String) async {
        do {
            let skills = try await registry.search(query: query)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                results = skills
                isSearching = false
                selectedSkill = skills.first
                if let first = skills.first {
                    selectSkill(first)
                } else {
                    skillContent = nil
                    previewError = nil
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.searchError = error.localizedDescription
                results = []
                selectedSkill = nil
                skillContent = nil
                isSearching = false
            }
        }
    }

    private func selectSkill(_ skill: SkillRegistry.RegistrySkill) {
        contentTask?.cancel()
        selectedSkill = skill
        skillContent = nil
        previewError = nil
        installError = nil
        installSuccess = false
        isFetchingContent = true
        refreshTargetInstallStates(for: skill)

        contentTask = Task {
            do {
                let content = try await registry.fetchContent(skill: skill)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard selectedSkill?.id == skill.id else { return }
                    skillContent = content
                    isFetchingContent = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard selectedSkill?.id == skill.id else { return }
                    self.previewError = error.localizedDescription
                    isFetchingContent = false
                }
            }
        }
    }

    private func toggleAgent(_ agent: AgentTarget) {
        if selectedAgents.contains(agent.id) {
            selectedAgents.remove(agent.id)
        } else {
            selectedAgents.insert(agent.id)
        }
        // Changing targets starts a fresh install attempt, so clear stale feedback and
        // re-enable the Install button.
        installResetTask?.cancel()
        installSuccess = false
        installError = nil
    }

    private func displayPath(_ path: String) -> String {
        let home = AppPaths.userHomeDirectory
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func performInstall(content: String, skillName: String) {
        let agents = installedAgents.filter { selectedAgents.contains($0.id) }
        guard !agents.isEmpty else { return }

        isInstalling = true
        installError = nil

        do {
            try registry.install(content: content, skillName: skillName, agents: agents)
            installSuccess = true
            isInstalling = false
            // The install just created directories, so both the detected-target list and
            // the per-target badges need re-sampling.
            refreshInstallTargets()
            NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)
            // Let the confirmation show briefly, then re-enable the button so the user can
            // pick other targets and install again without reselecting the skill.
            installResetTask?.cancel()
            installResetTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                installSuccess = false
            }
        } catch {
            self.installError = error.localizedDescription
            isInstalling = false
        }
    }

    private func featuredIcon(for query: String) -> String {
        switch query {
        case "swift": return "swift"
        case "testing": return "checkmark.seal"
        case "xcode": return "hammer"
        case "supabase": return "server.rack"
        case "docs": return "doc.text"
        case "git": return "point.3.connected.trianglepath.dotted"
        default: return "sparkle.magnifyingglass"
        }
    }

    private func platformIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("swift") || lower.contains("xcode") || lower.contains("ios") || lower.contains("macos") {
            return "hammer.fill"
        } else if lower.contains("git") || lower.contains("github") || lower.contains("gitlab") {
            return "terminal.fill"
        } else if lower.contains("supabase") || lower.contains("db") || lower.contains("postgres") || lower.contains("sql") {
            return "server.rack"
        } else if lower.contains("node") || lower.contains("npm") || lower.contains("js") || lower.contains("ts") || lower.contains("react") {
            return "app.dashed"
        } else {
            return "shippingbox.fill"
        }
    }

    private func platformColor(for name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("swift") || lower.contains("xcode") || lower.contains("ios") || lower.contains("macos") {
            return .orange
        } else if lower.contains("git") || lower.contains("github") || lower.contains("gitlab") {
            return .purple
        } else if lower.contains("supabase") || lower.contains("db") || lower.contains("postgres") || lower.contains("sql") {
            return .green
        } else if lower.contains("node") || lower.contains("npm") || lower.contains("js") || lower.contains("ts") || lower.contains("react") {
            return .blue
        } else {
            return .teal
        }
    }
}

// MARK: - DiscoverResultRow

private struct DiscoverResultRow: View {
    let skill: SkillRegistry.RegistrySkill
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: platformIcon(for: skill.name))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isSelected ? Color.accentColor : platformColor(for: skill.name))
                .frame(width: 32, height: 32)
                .background(
                    (isSelected ? Color.accentColor : platformColor(for: skill.name))
                        .opacity(0.12)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(skill.source)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10))
                    Text("\(skill.formattedInstalls) installs")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.03), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func platformIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("swift") || lower.contains("xcode") || lower.contains("ios") || lower.contains("macos") {
            return "hammer.fill"
        } else if lower.contains("git") || lower.contains("github") || lower.contains("gitlab") {
            return "terminal.fill"
        } else if lower.contains("supabase") || lower.contains("db") || lower.contains("postgres") || lower.contains("sql") {
            return "server.rack"
        } else if lower.contains("node") || lower.contains("npm") || lower.contains("js") || lower.contains("ts") || lower.contains("react") {
            return "app.dashed"
        } else {
            return "shippingbox.fill"
        }
    }

    private func platformColor(for name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("swift") || lower.contains("xcode") || lower.contains("ios") || lower.contains("macos") {
            return .orange
        } else if lower.contains("git") || lower.contains("github") || lower.contains("gitlab") {
            return .purple
        } else if lower.contains("supabase") || lower.contains("db") || lower.contains("postgres") || lower.contains("sql") {
            return .green
        } else if lower.contains("node") || lower.contains("npm") || lower.contains("js") || lower.contains("ts") || lower.contains("react") {
            return .blue
        } else {
            return .teal
        }
    }
}

// MARK: - AgentTargetCard

private struct AgentTargetCard: View {
    let agent: AgentTarget
    let isSelected: Bool
    var isInstalled: Bool = false
    var destinationPath: String = ""
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: agentIcon(for: agent.id))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        (isSelected ? Color.accentColor : Color.secondary)
                            .opacity(0.1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(agent.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isInstalled {
                            Text("Installed")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    if !destinationPath.isEmpty {
                        Text(destinationPath)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(destinationPath)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.06) : Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : (isHovered ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04)), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.displayName + (isInstalled ? ", already installed" : ""))
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func agentIcon(for id: String) -> String {
        switch id {
        case "agents": return "globe"
        case "claude": return "sparkles"
        case "codex": return "cpu"
        case "copilot": return "square.stack.3d.up"
        case "cursor": return "cursorarrow"
        case "windsurf": return "wind"
        default: return "terminal"
        }
    }
}

// MARK: - InlineErrorView

private struct InlineErrorView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
