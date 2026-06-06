import SwiftUI

struct MarketplaceView: View {
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

    private let featuredQueries = ["swift", "testing", "xcode", "supabase", "docs", "git"]

    private var installedAgents: [AgentTarget] {
        AgentTarget.installed
    }

    var body: some View {
        VStack(spacing: 0) {
            marketplaceHeader
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 16)

            Divider()

            HSplitView {
                resultsPane
                    .frame(minWidth: 330, idealWidth: 390)

                Divider()

                detailPane
                    .frame(minWidth: 420)
            }
        }
        .navigationTitle("Marketplace")
        .onAppear {
            selectedAgents = Set(installedAgents.map(\.id))
            if results.isEmpty {
                debounceSearch(query: searchText)
            }
        }
        .onDisappear {
            searchTask?.cancel()
            contentTask?.cancel()
        }
    }

    private var marketplaceHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "storefront.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        Text("Skill Marketplace")
                            .font(.system(size: 28, weight: .bold, design: .rounded))

                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Text("Search skills.sh, preview the source skill, then install it into your local agent tools.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search skills, tools, frameworks, or workflows", text: $searchText)
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
                .help("Search marketplace")
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
                                .background(searchText == query ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.09), in: Capsule())
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
                Text(results.isEmpty ? "Results" : "\(results.count) Results")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            if results.isEmpty && isSearching {
                ProgressView("Searching Marketplace...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView {
                    Label("No Skills Found", systemImage: "storefront")
                } description: {
                    Text(searchText.count < 2 ? "Type at least two characters to search." : "Try another topic or framework.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(results) { skill in
                        Button {
                            selectSkill(skill)
                        } label: {
                            MarketplaceResultRow(
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

            if let searchError, selectedSkill == nil {
                Divider()
                InlineErrorView(message: searchError)
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
                Text("Preview marketplace details and choose install targets.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func skillDetail(_ skill: SkillRegistry.RegistrySkill) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.teal)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 5) {
                    Text(skill.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Text(skill.source)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Label("\(skill.formattedInstalls) installs", systemImage: "arrow.down.circle")
                        Label(skill.skillId, systemImage: "number")
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                } else if let previewError {
                    ContentUnavailableView {
                        Label("Preview Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(previewError)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            installBar(skill: skill)
        }
    }

    private func installBar(skill: SkillRegistry.RegistrySkill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Install Targets")
                    .font(.headline)

                Spacer()

                if !installedAgents.isEmpty {
                    Button(selectedAgents.count == installedAgents.count ? "Clear" : "Select All") {
                        if selectedAgents.count == installedAgents.count {
                            selectedAgents.removeAll()
                        } else {
                            selectedAgents = Set(installedAgents.map(\.id))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            if installedAgents.isEmpty {
                Text("No supported local agents were detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                    ForEach(installedAgents) { agent in
                        let isSelected = selectedAgents.contains(agent.id)
                        Button {
                            toggleAgent(agent)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                Text(agent.displayName)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.caption)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 9)
                            .background(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                if let installError {
                    InlineErrorView(message: installError)
                }

                if installSuccess {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
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
                        Label("Install", systemImage: "arrow.down.circle")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(skillContent == nil || selectedAgents.isEmpty || isInstalling || installSuccess)
            }
        }
        .padding(18)
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
            NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)
        } catch {
            self.installError = error.localizedDescription
            isInstalling = false
        }
    }

    private func featuredIcon(for query: String) -> String {
        switch query {
        case "swift": "swift"
        case "testing": "checkmark.seal"
        case "xcode": "hammer"
        case "supabase": "server.rack"
        case "docs": "doc.text"
        case "git": "point.3.connected.trianglepath.dotted"
        default: "sparkle.magnifyingglass"
        }
    }
}

private struct MarketplaceResultRow: View {
    let skill: SkillRegistry.RegistrySkill
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(skill.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Label("\(skill.formattedInstalls) installs", systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if isSelected {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

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
