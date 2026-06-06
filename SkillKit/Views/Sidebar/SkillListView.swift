import SwiftUI
import SwiftData

struct SkillListView: View {
    private enum ActiveAlert: Identifiable {
        case confirmDelete(Skill)
        case confirmMakeGlobal(Skill)
        case deleteError(String)
        case makeGlobalError(String)

        var id: String {
            switch self {
            case .confirmDelete(let skill):
                return "confirm-delete-\(skill.filePath)"
            case .confirmMakeGlobal(let skill):
                return "confirm-make-global-\(skill.filePath)"
            case .deleteError(let message):
                return "delete-error-\(message)"
            case .makeGlobalError(let message):
                return "make-global-error-\(message)"
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \Skill.name) private var allSkills: [Skill]
    @Query(sort: \SkillCollection.name) private var allCollections: [SkillCollection]
    @State private var activeAlert: ActiveAlert?

    private var baseFilteredSkills: [Skill] {
        var result = allSkills

        switch appState.sidebarFilter {
        case .dashboard, .marketplace:
            result = []
        case .allSkills:
            result = result.filter { $0.itemKind == .skill }
        case .allRules:
            result = result.filter { $0.itemKind == .rule }
        case .needsReview:
            result = result.filter(\.hasValidationWarnings)
        case .favorites:
            result = result.filter { $0.isFavorite }
        case .tool(let tool):
            result = result.filter { $0.toolSources.contains(tool) }
            if let kind = appState.toolKindFilter {
                result = result.filter { $0.itemKind == kind }
            }
        case .collection(let collName):
            result = result.filter { skill in
                skill.collections.contains { $0.name == collName }
            }
        case .server(let serverID):
            result = result.filter { $0.remoteServer?.id == serverID }
        }

        switch appState.skillQuickFilter {
        case .all:
            break
        case .favorites:
            result = result.filter(\.isFavorite)
        case .needsReview:
            result = result.filter(\.hasValidationWarnings)
        case .editable:
            result = result.filter { !$0.isReadOnly }
        case .readOnly:
            result = result.filter(\.isReadOnly)
        case .local:
            result = result.filter { !$0.isRemote }
        case .remote:
            result = result.filter(\.isRemote)
        }

        if !appState.searchText.isEmpty {
            result = result.filter { matchesSearch($0) }
        }

        return result
    }

    private var filteredSkills: [Skill] {
        switch appState.skillSortOption {
        case .nameAscending:
            return baseFilteredSkills.sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .modifiedNewest:
            return baseFilteredSkills.sorted { $0.fileModifiedDate > $1.fileModifiedDate }
        case .modifiedOldest:
            return baseFilteredSkills.sorted { $0.fileModifiedDate < $1.fileModifiedDate }
        case .platform:
            return baseFilteredSkills.sorted { lhs, rhs in
                let platformComparison = lhs.toolSource.displayName.localizedStandardCompare(rhs.toolSource.displayName)
                if platformComparison == .orderedSame {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return platformComparison == .orderedAscending
            }
        case .warningsFirst:
            return baseFilteredSkills.sorted { lhs, rhs in
                if lhs.hasValidationWarnings != rhs.hasValidationWarnings {
                    return lhs.hasValidationWarnings
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private var scopedTotalCount: Int {
        let savedSearch = appState.searchText
        guard !savedSearch.isEmpty || appState.skillQuickFilter != .all else {
            return baseFilteredSkills.count
        }

        var result = allSkills
        switch appState.sidebarFilter {
        case .dashboard, .marketplace:
            result = []
        case .allSkills:
            result = result.filter { $0.itemKind == .skill }
        case .allRules:
            result = result.filter { $0.itemKind == .rule }
        case .needsReview:
            result = result.filter(\.hasValidationWarnings)
        case .favorites:
            result = result.filter(\.isFavorite)
        case .tool(let tool):
            result = result.filter { $0.toolSources.contains(tool) }
            if let kind = appState.toolKindFilter {
                result = result.filter { $0.itemKind == kind }
            }
        case .collection(let collName):
            result = result.filter { skill in
                skill.collections.contains { $0.name == collName }
            }
        case .server(let serverID):
            result = result.filter { $0.remoteServer?.id == serverID }
        }
        return result.count
    }

    private var title: String {
        switch appState.sidebarFilter {
        case .dashboard: "Dashboard"
        case .marketplace: "Marketplace"
        case .allSkills: "Skills"
        case .allRules: "Rules"
        case .needsReview: "Needs Review"
        case .favorites: "Favorites"
        case .tool(let tool): tool.displayName
        case .collection(let name): name
        case .server(let id):
            allSkills.first(where: { $0.remoteServer?.id == id })?.remoteServer?.label ?? "Remote"
        }
    }

    private var isControlBarVisible: Bool {
        appState.sidebarFilter != .dashboard && appState.sidebarFilter != .marketplace
    }

    /// Whether the current filter shows mixed item types (skills and agents together)
    private var showsTypeBadge: Bool {
        switch appState.sidebarFilter {
        case .dashboard, .allSkills, .allRules: false
        case .tool: appState.toolKindFilter == nil
        default: true
        }
    }

    private var availableKinds: [ItemKind] {
        guard case .tool(let tool) = appState.sidebarFilter else { return [] }
        let kinds = Set(allSkills.filter { $0.toolSources.contains(tool) }.map(\.itemKind))
        return ItemKind.allCases.filter { kinds.contains($0) }
    }

    private func matchesSearch(_ skill: Skill) -> Bool {
        let searchText = appState.searchText
        switch appState.skillSearchScope {
        case .all:
            return skill.name.localizedCaseInsensitiveContains(searchText) ||
                skill.skillDescription.localizedCaseInsensitiveContains(searchText) ||
                skill.content.localizedCaseInsensitiveContains(searchText) ||
                skill.filePath.localizedCaseInsensitiveContains(searchText) ||
                skill.frontmatter.values.contains { $0.localizedCaseInsensitiveContains(searchText) }
        case .title:
            return skill.name.localizedCaseInsensitiveContains(searchText)
        case .description:
            return skill.skillDescription.localizedCaseInsensitiveContains(searchText)
        case .content:
            return skill.content.localizedCaseInsensitiveContains(searchText)
        case .path:
            return skill.filePath.localizedCaseInsensitiveContains(searchText)
        case .metadata:
            return skill.frontmatter.values.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private func updateSelectionForCurrentFilter() {
        if let selected = appState.selectedSkill, filteredSkills.contains(selected) {
            return
        }
        appState.selectedSkill = filteredSkills.first
    }

    @ViewBuilder
    private var emptyStateView: some View {
        if let kind = appState.toolKindFilter {
            ContentUnavailableView(
                "No \(kind.displayName)",
                systemImage: kind.icon,
                description: Text("No \(kind.displayName.lowercased()) match the current filter.")
            )
        } else {
            switch appState.sidebarFilter {
            case .dashboard:
                ContentUnavailableView("Dashboard", systemImage: "gauge.with.dots.needle.bottom.50percent",
                    description: Text("Select Skills or Rules to browse individual files."))
            case .marketplace:
                ContentUnavailableView("Marketplace", systemImage: "storefront",
                    description: Text("Browse the marketplace from the sidebar."))
            case .allRules:
                ContentUnavailableView("No Rules", systemImage: "list.bullet.rectangle",
                    description: Text("No rules match the current filter."))
            case .needsReview:
                ContentUnavailableView("Nothing Needs Review", systemImage: "checkmark.seal",
                    description: Text("All indexed skills and rules have the expected metadata."))
            default:
                ContentUnavailableView("No Skills", systemImage: "doc.text",
                    description: Text("No skills match the current filter."))
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for skill: Skill) -> some View {
        Button(skill.isFavorite ? "Unfavorite" : "Favorite") {
            skill.isFavorite.toggle()
            try? modelContext.save()
        }
        if skill.canMakeGlobal {
            Button("Make Global") {
                activeAlert = .confirmMakeGlobal(skill)
            }
        }
        if !allCollections.isEmpty {
            Menu("Collections") {
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
                        Toggle(isOn: .constant(isAssigned)) {
                            Label(collection.name, systemImage: collection.icon)
                        }
                    }
                }
            }
        }
        if !skill.isRemote {
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(skill.filePath, inFileViewerRootedAtPath: "")
            }
        }
        if !skill.isReadOnly {
            Divider()
            Button("Delete", role: .destructive) {
                activeAlert = .confirmDelete(skill)
            }
        }
    }

    private func makeSkillGlobal(_ skill: Skill) {
        do {
            try skill.makeGlobal()
            try? modelContext.save()
        } catch {
            activeAlert = .makeGlobalError(error.localizedDescription)
        }
    }

    private func deleteSkill(_ skill: Skill) {
        guard !skill.isReadOnly else { return }
        do {
            try skill.deleteFromDisk()
            if appState.selectedSkill == skill {
                appState.selectedSkill = nil
            }
            modelContext.delete(skill)
            try modelContext.save()
        } catch {
            activeAlert = .deleteError(error.localizedDescription)
        }
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            if isControlBarVisible {
                SkillListControlBar(
                    filteredCount: filteredSkills.count,
                    totalCount: scopedTotalCount
                )
                Divider()
            }

            List(selection: $appState.selectedSkill) {
                ForEach(filteredSkills) { skill in
                    SkillRow(
                        skill: skill,
                        showTypeBadge: showsTypeBadge,
                        onToggleFavorite: {
                            skill.isFavorite.toggle()
                            try? modelContext.save()
                        }
                    )
                        .tag(skill)
                        .draggable(skill.resolvedPath)
                        .contextMenu { contextMenu(for: skill) }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    if case .tool = appState.sidebarFilter, availableKinds.count > 1 {
                        Menu {
                            Button {
                                appState.toolKindFilter = nil
                            } label: {
                                if appState.toolKindFilter == nil {
                                    Label("All", systemImage: "checkmark")
                                } else {
                                    Text("All")
                                }
                            }
                            Divider()
                            ForEach(availableKinds, id: \.self) { kind in
                                Button {
                                    appState.toolKindFilter = kind
                                } label: {
                                    if appState.toolKindFilter == kind {
                                        Label(kind.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(kind.displayName)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: appState.toolKindFilter != nil ? "ellipsis.circle.fill" : "ellipsis.circle")
                        }
                    }
                    Menu {
                        Button {
                            appState.newItemKind = .skill
                            appState.showingNewSkillSheet = true
                        } label: {
                            Label("New Skill", systemImage: "doc.text")
                        }
                        Button {
                            appState.newItemKind = .rule
                            appState.showingNewSkillSheet = true
                        } label: {
                            Label("New Rule", systemImage: "list.bullet.rectangle")
                        }
                        Divider()
                        Button {
                            appState.sidebarFilter = .marketplace
                        } label: {
                            Label("Browse Registry", systemImage: "globe")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                }
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .confirmMakeGlobal(let skill):
                return Alert(
                    title: Text("Make \"\(skill.name)\" Global?"),
                    message: Text("This will move the skill to ~/.agents/skills/ and symlink it to all installed agents."),
                    primaryButton: .default(Text("Make Global")) {
                        makeSkillGlobal(skill)
                    },
                    secondaryButton: .cancel()
                )
            case .confirmDelete(let skill):
                return Alert(
                    title: Text("Delete \(skill.displayTypeName)?"),
                    message: Text("This will permanently delete \"\(skill.name)\" from disk."),
                    primaryButton: .destructive(Text("Delete")) {
                        deleteSkill(skill)
                    },
                    secondaryButton: .cancel()
                )
            case .deleteError(let message):
                return Alert(
                    title: Text("Delete Failed"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            case .makeGlobalError(let message):
                return Alert(
                    title: Text("Make Global Failed"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .overlay {
            if filteredSkills.isEmpty { emptyStateView }
        }
        .onChange(of: appState.sidebarFilter) {
            updateSelectionForCurrentFilter()
        }
        .onChange(of: appState.skillQuickFilter) {
            updateSelectionForCurrentFilter()
        }
        .onChange(of: appState.skillSearchScope) {
            updateSelectionForCurrentFilter()
        }
        .onChange(of: appState.skillSortOption) {
            updateSelectionForCurrentFilter()
        }
        .onChange(of: appState.searchText) {
            updateSelectionForCurrentFilter()
        }
    }
}

private struct SkillListControlBar: View {
    @Environment(AppState.self) private var appState
    let filteredCount: Int
    let totalCount: Int

    private var countText: String {
        if filteredCount == totalCount {
            return "\(filteredCount)"
        }
        return "\(filteredCount) of \(totalCount)"
    }

    var body: some View {
        @Bindable var appState = appState

        HStack(spacing: 8) {
            Menu {
                ForEach(SkillQuickFilter.allCases) { filter in
                    Button {
                        appState.skillQuickFilter = filter
                    } label: {
                        if appState.skillQuickFilter == filter {
                            Label(filter.displayName, systemImage: "checkmark")
                        } else {
                            Label(filter.displayName, systemImage: filter.icon)
                        }
                    }
                }
            } label: {
                Label(appState.skillQuickFilter.displayName, systemImage: appState.skillQuickFilter.icon)
                    .labelStyle(.titleAndIcon)
            }
            .fixedSize()

            Menu {
                ForEach(SkillSortOption.allCases) { option in
                    Button {
                        appState.skillSortOption = option
                    } label: {
                        if appState.skillSortOption == option {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Label(option.displayName, systemImage: option.icon)
                        }
                    }
                }
            } label: {
                Label(appState.skillSortOption.displayName, systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .help("Sort")

            Menu {
                ForEach(SkillSearchScope.allCases) { scope in
                    Button {
                        appState.skillSearchScope = scope
                    } label: {
                        if appState.skillSearchScope == scope {
                            Label(scope.displayName, systemImage: "checkmark")
                        } else {
                            Label(scope.displayName, systemImage: scope.icon)
                        }
                    }
                }
            } label: {
                Label(appState.skillSearchScope.displayName, systemImage: appState.skillSearchScope.icon)
                    .labelStyle(.iconOnly)
            }
            .help("Search Scope")

            Spacer(minLength: 8)

            Text(countText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if appState.skillQuickFilter != .all || appState.skillSearchScope != .all {
                Button {
                    appState.skillQuickFilter = .all
                    appState.skillSearchScope = .all
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear list filters")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct SkillRow: View {
    let skill: Skill
    var showTypeBadge: Bool = false
    var onToggleFavorite: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            if showTypeBadge {
                let kindIcon: String = switch skill.itemKind {
                case .rule: "list.bullet.rectangle"
                case .skill: "doc.text"
                }
                Image(systemName: kindIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(skill.name)
                .lineLimit(1)

            Button {
                onToggleFavorite()
            } label: {
                Image(systemName: skill.isFavorite ? "star.fill" : "star")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(skill.isFavorite ? Color.yellow : Color.secondary.opacity(0.55))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(skill.isFavorite ? "Remove Favorite" : "Add Favorite")

            if skill.hasValidationWarnings {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(skill.validationIssues.map(\.title).joined(separator: "\n"))
            }

            Spacer()

            if skill.isRemote, let serverLabel = skill.remoteServer?.label {
                Text(serverLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if let project = skill.projectName {
                Text(project)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 3) {
                ForEach(skill.toolSources, id: \.self) { tool in
                    ToolIcon(tool: tool, size: 14)
                        .help(tool.displayName)
                        .opacity(0.6)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
