import SwiftUI
import SwiftData

struct SkillListView: View {
    private enum ActiveAlert: Identifiable {
        case confirmDelete(Skill)
        case confirmDeleteSelected(Int)
        case confirmMakeGlobal(Skill)
        case deleteError(String)
        case makeGlobalError(String)

        var id: String {
            switch self {
            case .confirmDelete(let skill):
                return "confirm-delete-\(skill.filePath)"
            case .confirmDeleteSelected(let count):
                return "confirm-delete-selected-\(count)"
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
    @AppStorage("securityScanningEnabled") private var securityScanningEnabled = true
    @State private var activeAlert: ActiveAlert?
    @State private var selectedSkillPaths: Set<String> = []
    /// The row the user clicked most recently. With several rows selected, the
    /// detail shows this one rather than an arbitrary member of the set.
    @State private var lastClickedPath: String?
    /// Search text the list is actually filtering on. Matching scans every
    /// skill's body, so it trails the field by a moment rather than running on
    /// each keystroke; typing stays responsive on a large library.
    @State private var appliedSearchText: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    /// A selection value this view set itself. `onChange(of: selectedSkillPaths)`
    /// compares against it to tell programmatic changes from user clicks.
    @State private var programmaticSelection: Set<String>?
    /// A path selected automatically (filter change, deletion). Automatic
    /// selections must not stamp `lastOpened`.
    @State private var suppressOpenedStampPath: String?
    /// Where the selected row sat in the visible list, so a deletion can move
    /// the selection to a neighbor instead of clearing it.
    @State private var lastSelectedIndex: Int?
    @State private var lastSelectedPath: String?

    /// The sidebar selection alone, before quick filters and search. Shared by
    /// the visible list and by `scopedTotalCount`, which reports how many items
    /// the selection holds when a search or quick filter is narrowing it.
    private var skillsMatchingSidebarFilter: [Skill] {
        var result = allSkills

        switch appState.sidebarFilter {
        case .dashboard, .discover:
            result = []
        case .recent:
            result = result.filter { $0.lastOpened != nil }
        case .allSkills:
            result = result.filter { $0.itemKind == .skill }
        case .allRules:
            result = result.filter { $0.itemKind == .rule }
        case .needsReview:
            result = result.filter(\.hasValidationWarnings)
        case .securityReview:
            result = securityScanningEnabled ? result.filter { !$0.securityScan.isClean } : []
        case .favorites:
            result = result.filter { $0.isFavorite }
        case .tool(let tool):
            result = result.filter { $0.toolSources.contains(tool) }
            if let kind = appState.toolKindFilter {
                result = result.filter { $0.itemKind == kind }
            }
        case .customPlatform(let platformID):
            if let platform = PlatformOption.customPlatforms.first(where: { $0.id == platformID }) {
                result = result.filter { skill in
                    guard skill.toolSource == .custom else { return false }
                    let path = skill.filePath.lowercased()
                    let platformSkills = platform.expandedSkillsPath.lowercased()
                    let platformXcode = platform.expandedXcodePath?.lowercased()
                    return path.hasPrefix(platformSkills) || (platformXcode != nil && path.hasPrefix(platformXcode!))
                }
                if let kind = appState.toolKindFilter {
                    result = result.filter { $0.itemKind == kind }
                }
            } else {
                result = []
            }
        case .collection(let collName):
            result = result.filter { skill in
                skill.collections.contains { $0.name == collName }
            }
        case .server(let serverID):
            result = result.filter { $0.remoteServer?.id == serverID }
        }

        return result
    }

    private var baseFilteredSkills: [Skill] {
        var result = skillsMatchingSidebarFilter

        switch appState.skillQuickFilter {
        case .all:
            break
        case .favorites:
            result = result.filter(\.isFavorite)
        case .needsReview:
            result = result.filter(\.hasValidationWarnings)
        case .securityFindings:
            if securityScanningEnabled {
                result = result.filter { !$0.securityScan.isClean }
            }
        case .editable:
            result = result.filter { !$0.isReadOnly }
        case .readOnly:
            result = result.filter(\.isReadOnly)
        case .local:
            result = result.filter { !$0.isRemote }
        case .remote:
            result = result.filter(\.isRemote)
        }

        if !appliedSearchText.isEmpty {
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
        case .lastOpened:
            return baseFilteredSkills.sorted {
                ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast)
            }
        case .modifiedNewest:
            return baseFilteredSkills.sorted { $0.fileModifiedDate > $1.fileModifiedDate }
        case .modifiedOldest:
            return baseFilteredSkills.sorted { $0.fileModifiedDate < $1.fileModifiedDate }
        case .platform:
            return baseFilteredSkills.sorted { lhs, rhs in
                let platformComparison = lhs.toolSourceDisplayName.localizedStandardCompare(rhs.toolSourceDisplayName)
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
        case .securityRisk:
            guard securityScanningEnabled else {
                return baseFilteredSkills.sorted { lhs, rhs in
                    lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
            return baseFilteredSkills.sorted { lhs, rhs in
                let lhsScan = lhs.securityScan
                let rhsScan = rhs.securityScan
                if lhsScan.riskScore != rhsScan.riskScore {
                    return lhsScan.riskScore > rhsScan.riskScore
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private var scopedTotalCount: Int {
        guard !appliedSearchText.isEmpty || appState.skillQuickFilter != .all else {
            return baseFilteredSkills.count
        }

        return skillsMatchingSidebarFilter.count
    }

    private var selectedSkills: [Skill] {
        allSkills.filter { selectedSkillPaths.contains($0.resolvedPath) }
    }

    private var selectedLocalEditableSkills: [Skill] {
        selectedSkills.filter { !$0.isReadOnly && !$0.isRemote }
    }

    private var selectedGlobalizableSkills: [Skill] {
        selectedSkills.filter(\.canMakeGlobal)
    }

    private var title: String {
        switch appState.sidebarFilter {
        case .dashboard: "Dashboard"
        case .discover: "Discover"
        case .recent: "Recent"
        case .allSkills: "Skills"
        case .allRules: "Rules"
        case .needsReview: "Needs Review"
        case .securityReview: "Security"
        case .favorites: "Favorites"
        case .tool(let tool): tool.displayName
        case .customPlatform(let platformID):
            PlatformOption.customPlatforms.first(where: { $0.id == platformID })?.displayName ?? "Custom Platform"
        case .collection(let name): name
        case .server(let id):
            allSkills.first(where: { $0.remoteServer?.id == id })?.remoteServer?.label ?? "Remote"
        }
    }

    private var isControlBarVisible: Bool {
        appState.sidebarFilter != .dashboard && appState.sidebarFilter != .discover
    }

    /// Whether the current filter shows mixed item types (skills and agents together)
    private var showsTypeBadge: Bool {
        switch appState.sidebarFilter {
        case .dashboard, .allSkills, .allRules: false
        case .tool: appState.toolKindFilter == nil
        case .customPlatform: appState.toolKindFilter == nil
        default: true
        }
    }

    private var availableKinds: [ItemKind] {
        guard case .tool(let tool) = appState.sidebarFilter else { return [] }
        let kinds = Set(allSkills.filter { $0.toolSources.contains(tool) }.map(\.itemKind))
        return ItemKind.allCases.filter { kinds.contains($0) }
    }

    private func matchesSearch(_ skill: Skill) -> Bool {
        let searchText = appliedSearchText
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

    // MARK: - Selection

    /// Changes the list highlight without it being mistaken for a user click.
    private func setSelectionProgrammatically(_ paths: Set<String>) {
        guard paths != selectedSkillPaths else { return }
        programmaticSelection = paths
        selectedSkillPaths = paths
    }

    /// Selects `candidate` on the user's behalf (filter change, deletion).
    /// Such selections don't count as "opened".
    private func autoSelect(_ candidate: Skill?) {
        if appState.selectedSkill != candidate {
            suppressOpenedStampPath = candidate?.resolvedPath
            appState.selectedSkill = candidate
        }
        lastClickedPath = candidate?.resolvedPath
        setSelectionProgrammatically(candidate.map { [$0.resolvedPath] } ?? [])
    }

    /// Sidebar filter changed: keep the current item if it's still visible,
    /// otherwise fall back to the first row.
    private func updateSelectionForCurrentFilter() {
        let visible = filteredSkills
        if let selected = appState.selectedSkill, visible.contains(selected) {
            lastClickedPath = selected.resolvedPath
            setSelectionProgrammatically([selected.resolvedPath])
            return
        }
        autoSelect(visible.first)
    }

    /// Search, quick filter, scope, or sort changed: never hijack the detail.
    /// The highlight follows the selected item while it's visible and simply
    /// clears when the filter hides it; the detail keeps showing it.
    private func reconcileHighlightWithVisibleRows() {
        let visible = Set(filteredSkills.map(\.resolvedPath))
        var highlight = selectedSkillPaths.intersection(visible)
        if let selected = appState.selectedSkill, visible.contains(selected.resolvedPath) {
            highlight.insert(selected.resolvedPath)
        }
        setSelectionProgrammatically(highlight)
    }

    /// The library changed (Trash, rescan, bulk delete). If the item that was
    /// selected is gone, move to its neighbor rather than showing nothing.
    private func handleLibraryChange() {
        guard let previousPath = lastSelectedPath else { return }
        guard !allSkills.contains(where: { $0.resolvedPath == previousPath }) else { return }
        lastSelectedPath = nil

        let visible = filteredSkills
        guard !visible.isEmpty else {
            autoSelect(nil)
            return
        }
        let index = min(lastSelectedIndex ?? 0, visible.count - 1)
        autoSelect(visible[index])
    }

    /// Records that the user explicitly opened `skill`. Only called for
    /// deliberate selections (click, keyboard, dashboard, newly created item).
    private func markOpened(_ skill: Skill) {
        guard !skill.isDeleted else { return }
        skill.lastOpened = .now
        try? modelContext.save()
    }

    // MARK: - Empty state

    private var isSearchOrQuickFilterActive: Bool {
        !appliedSearchText.isEmpty || appState.skillQuickFilter != .all
    }

    /// Copy tailored to the current sidebar filter, so an empty Rules list
    /// doesn't say "No Skills" and an empty collection names itself.
    private var emptyStateContent: (title: String, systemImage: String, description: String) {
        let narrowed = isSearchOrQuickFilterActive

        if let kind = appState.toolKindFilter {
            return ("No \(kind.displayName)", kind.icon,
                    narrowed ? "No \(kind.displayName.lowercased()) match the current search or filter."
                             : "No \(kind.displayName.lowercased()) are installed for this tool.")
        }

        switch appState.sidebarFilter {
        case .dashboard:
            return ("Dashboard", "gauge.with.dots.needle.bottom.50percent",
                    "Select Skills or Rules to browse individual files.")
        case .discover:
            return ("Discover", "sparkle.magnifyingglass", "Discover new skills from the library.")
        case .recent:
            return ("No Recent Items", "clock.badge.checkmark",
                    narrowed ? "No recent items match the current search or filter."
                             : "Open a skill or rule to add it to Recent.")
        case .allSkills:
            return ("No Skills", "doc.text",
                    narrowed ? "No skills match the current search or filter."
                             : "Create a skill or rescan to find installed ones.")
        case .allRules:
            return ("No Rules", "list.bullet.rectangle",
                    narrowed ? "No rules match the current search or filter."
                             : "Create a rule to get started.")
        case .needsReview:
            return ("Nothing Needs Review", "checkmark.seal",
                    narrowed ? "No items needing review match the current search or filter."
                             : "All indexed skills and rules have the expected metadata.")
        case .securityReview:
            return ("No Security Findings", "checkmark.shield",
                    narrowed ? "No items with findings match the current search or filter."
                             : "Static scan found no risky patterns in this scope.")
        case .favorites:
            return ("No Favorites", "star",
                    narrowed ? "No favorites match the current search or filter."
                             : "Mark a skill or rule as a favorite to see it here.")
        case .tool(let tool):
            return ("No \(tool.displayName) Items", tool.iconName,
                    narrowed ? "No \(tool.displayName) items match the current search or filter."
                             : "No skills or rules are installed for \(tool.displayName).")
        case .customPlatform(let platformID):
            let name = PlatformOption.customPlatforms.first(where: { $0.id == platformID })?.displayName ?? "Custom Platform"
            return ("No \(name) Items", "square.grid.2x2",
                    narrowed ? "No \(name) items match the current search or filter."
                             : "No skills are installed for \(name).")
        case .collection(let name):
            return ("No Items in \(name)", "folder",
                    narrowed ? "No items in \(name) match the current search or filter."
                             : "Drag skills or rules onto \(name) in the sidebar to add them.")
        case .server:
            return ("No Remote Items", "server.rack",
                    narrowed ? "No remote items match the current search or filter."
                             : "Sync the server to load its skills and rules.")
        }
    }

    private var emptyStateView: some View {
        let content = emptyStateContent
        return ContentUnavailableView(
            content.title,
            systemImage: content.systemImage,
            description: Text(content.description)
        )
    }

    @ViewBuilder
    private func contextMenu(for skill: Skill) -> some View {
        Button(skill.isFavorite ? "Unfavorite" : "Favorite") {
            skill.isFavorite.toggle()
            try? modelContext.save()
        }
        Menu("Copy") {
            Button("Content") {
                copyToPasteboard(skill.content)
            }
            Button("File Path") {
                copyToPasteboard(skill.filePath)
            }
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
            Button("Duplicate…") {
                appState.skillToDuplicate = skill
                appState.showingDuplicateSkillSheet = true
            }
            Button("Move to Trash", role: .destructive) {
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
            var remaining = selectedSkillPaths
            remaining.remove(skill.resolvedPath)
            setSelectionProgrammatically(remaining)
            modelContext.delete(skill)
            try modelContext.save()
            // handleLibraryChange() moves the selection to a neighbor once the query updates.
        } catch {
            activeAlert = .deleteError(error.localizedDescription)
        }
    }

    private func deleteSelectedSkills() {
        let skillsToDelete = selectedLocalEditableSkills
        var remaining = selectedSkillPaths
        var failures: [String] = []

        // One skill failing must not abandon the loop: that would leave the
        // already-deleted rows pending in the context, to be committed later by
        // an unrelated save, with the list still highlighting trashed files.
        for skill in skillsToDelete {
            do {
                try skill.deleteFromDisk()
            } catch {
                failures.append("\(skill.name): \(error.localizedDescription)")
                continue
            }
            if appState.selectedSkill == skill {
                appState.selectedSkill = nil
            }
            remaining.remove(skill.resolvedPath)
            modelContext.delete(skill)
        }

        setSelectionProgrammatically(remaining)
        do {
            try modelContext.save()
        } catch {
            failures.append(error.localizedDescription)
        }

        if !failures.isEmpty {
            activeAlert = .deleteError(failures.joined(separator: "\n"))
        }
    }

    private func setFavoriteForSelection(_ isFavorite: Bool) {
        for skill in selectedSkills {
            skill.isFavorite = isFavorite
        }
        try? modelContext.save()
    }

    private func setCollection(_ collection: SkillCollection, isAssigned: Bool) {
        for skill in selectedSkills {
            let alreadyAssigned = skill.collections.contains { $0.name == collection.name }
            if isAssigned, !alreadyAssigned {
                skill.collections.append(collection)
            } else if !isAssigned, alreadyAssigned {
                skill.collections.removeAll { $0.name == collection.name }
            }
        }
        try? modelContext.save()
    }

    private func revealSelectedInFinder() {
        let urls = selectedSkills
            .filter { !$0.isRemote }
            .map { URL(fileURLWithPath: $0.filePath) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func copySelectedPaths() {
        let paths = selectedSkills
            .map(\.filePath)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        copyToPasteboard(paths.joined(separator: "\n"))
    }

    private func copySelectedSecurityReport() {
        copyToPasteboard(SecurityScanner.report(for: selectedSkills))
    }

    private func exportSelectedSkills() {
        do {
            _ = try SkillExporter.shared.export(skills: selectedSkills)
        } catch {
            activeAlert = .deleteError(error.localizedDescription)
        }
    }

    private func makeSelectedSkillsGlobal() {
        do {
            for skill in selectedGlobalizableSkills {
                try skill.makeGlobal()
            }
            try? modelContext.save()
        } catch {
            activeAlert = .makeGlobalError(error.localizedDescription)
        }
    }

    var body: some View {
        @Bindable var appState = appState

        // Filtering scans every skill's body text, so compute it once per pass
        // rather than each time the list, the count and the empty state ask.
        let visibleSkills = filteredSkills

        VStack(spacing: 0) {
            if isControlBarVisible {
                SkillListControlBar(
                    filteredCount: visibleSkills.count,
                    totalCount: scopedTotalCount
                )
                Divider()
            }

            List(selection: $selectedSkillPaths) {
                ForEach(visibleSkills) { skill in
                    SkillRow(
                        skill: skill,
                        showTypeBadge: showsTypeBadge,
                        showSecurityStatus: securityScanningEnabled,
                        onToggleFavorite: {
                            skill.isFavorite.toggle()
                            try? modelContext.save()
                        }
                    )
                        .tag(skill.resolvedPath)
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
                        .help("Filter by type")
                        .accessibilityLabel("Filter by type")
                        .accessibilityValue(appState.toolKindFilter?.displayName ?? "All")
                    }
                    Button {
                        NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("Rescan local skills")
                    .accessibilityLabel("Rescan local skills")

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
                            appState.sidebarFilter = .discover
                        } label: {
                            Label("Browse Registry", systemImage: "globe")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .help("New Skill or Rule")
                    .accessibilityLabel("New Skill or Rule")

                    if selectedSkills.count > 1 {
                        Menu {
                            Button {
                                setFavoriteForSelection(true)
                            } label: {
                                Label("Favorite Selected", systemImage: "star.fill")
                            }

                            Button {
                                setFavoriteForSelection(false)
                            } label: {
                                Label("Unfavorite Selected", systemImage: "star")
                            }

                            Divider()
                            Button {
                                copySelectedPaths()
                            } label: {
                                Label("Copy Selected Paths", systemImage: "doc.on.doc")
                            }

                            Button {
                                exportSelectedSkills()
                            } label: {
                                Label("Export Selected", systemImage: "square.and.arrow.up")
                            }

                            if securityScanningEnabled {
                                Button {
                                    copySelectedSecurityReport()
                                } label: {
                                    Label("Copy Selected Security Report", systemImage: "doc.on.clipboard")
                                }
                            }

                            if !allCollections.isEmpty {
                                Divider()
                                Menu("Collections") {
                                    ForEach(allCollections) { collection in
                                        Button {
                                            setCollection(collection, isAssigned: true)
                                        } label: {
                                            Label(collection.name, systemImage: collection.icon)
                                        }

                                        Button {
                                            setCollection(collection, isAssigned: false)
                                        } label: {
                                            Label("Remove from \(collection.name)", systemImage: "minus.circle")
                                        }
                                    }
                                }
                            }

                            if selectedSkills.contains(where: { !$0.isRemote }) {
                                Divider()
                                Button {
                                    revealSelectedInFinder()
                                } label: {
                                    Label("Reveal Selected in Finder", systemImage: "folder")
                                }
                            }

                            if !selectedGlobalizableSkills.isEmpty {
                                Button {
                                    makeSelectedSkillsGlobal()
                                } label: {
                                    Label("Make Selected Global", systemImage: "globe")
                                }
                            }

                            if !selectedLocalEditableSkills.isEmpty {
                                Divider()
                                Button(role: .destructive) {
                                    activeAlert = .confirmDeleteSelected(selectedLocalEditableSkills.count)
                                } label: {
                                    Label("Move Selected to Trash", systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "checklist")
                        }
                        .help("Bulk Actions")
                        .accessibilityLabel("Bulk Actions")
                    }
                }
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .confirmMakeGlobal(let skill):
                return Alert(
                    title: Text("Make \"\(skill.name)\" Global?"),
                    message: Text("This will move the skill to your global SkillKit library and symlink it to supported agent folders."),
                    primaryButton: .default(Text("Make Global")) {
                        makeSkillGlobal(skill)
                    },
                    secondaryButton: .cancel()
                )
            case .confirmDelete(let skill):
                return Alert(
                    title: Text("Move \"\(skill.name)\" to Trash?"),
                    message: Text("This will move the \(skill.displayTypeName.lowercased()) to the Trash."),
                    primaryButton: .destructive(Text("Move to Trash")) {
                        deleteSkill(skill)
                    },
                    secondaryButton: .cancel()
                )
            case .confirmDeleteSelected(let count):
                return Alert(
                    title: Text("Move \(count) Items to Trash?"),
                    message: Text("This will move the selected local editable items to the Trash. Remote and read-only items are skipped."),
                    primaryButton: .destructive(Text("Move to Trash")) {
                        deleteSelectedSkills()
                    },
                    secondaryButton: .cancel()
                )
            case .deleteError(let message):
                return Alert(
                    title: Text("Couldn't Complete"),
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
            if visibleSkills.isEmpty { emptyStateView }
        }
        .onAppear {
            // Arriving with a selection already made elsewhere (dashboard,
            // a newly created or duplicated item): that was an explicit choice.
            guard let selected = appState.selectedSkill else { return }
            let visible = filteredSkills
            lastSelectedPath = selected.resolvedPath
            lastSelectedIndex = visible.firstIndex(of: selected)
            if visible.contains(selected) {
                lastClickedPath = selected.resolvedPath
                setSelectionProgrammatically([selected.resolvedPath])
            }
            markOpened(selected)
        }
        .onChange(of: appState.sidebarFilter) {
            updateSelectionForCurrentFilter()
        }
        .onChange(of: selectedSkillPaths) { oldValue, newValue in
            let isProgrammatic = programmaticSelection == newValue
            programmaticSelection = nil

            // Remember what was clicked last so multi-selection shows that row.
            let added = newValue.subtracting(oldValue)
            if added.count == 1, let path = added.first {
                lastClickedPath = path
            } else if let current = lastClickedPath, !newValue.contains(current) {
                lastClickedPath = filteredSkills.first { newValue.contains($0.resolvedPath) }?.resolvedPath
            }

            guard !isProgrammatic else { return }

            let visible = filteredSkills
            guard !newValue.isEmpty else {
                // Only a click on empty space counts as a deselect. Rows that
                // vanished because a filter hid them keep the detail as-is.
                let visiblePaths = Set(visible.map(\.resolvedPath))
                guard oldValue.contains(where: { visiblePaths.contains($0) }) else { return }
                lastSelectedPath = nil
                appState.selectedSkill = nil
                return
            }

            let detailPath = lastClickedPath.flatMap { newValue.contains($0) ? $0 : nil }
                ?? visible.first { newValue.contains($0.resolvedPath) }?.resolvedPath
                ?? newValue.first
            guard let detailPath else { return }
            let skill = visible.first { $0.resolvedPath == detailPath }
                ?? allSkills.first { $0.resolvedPath == detailPath }
            if appState.selectedSkill != skill {
                appState.selectedSkill = skill
            }
        }
        .onChange(of: appState.selectedSkill?.resolvedPath) { _, newPath in
            guard let newPath else {
                setSelectionProgrammatically([])
                return
            }
            let visible = filteredSkills
            lastSelectedPath = newPath
            lastSelectedIndex = visible.firstIndex { $0.resolvedPath == newPath }

            if visible.contains(where: { $0.resolvedPath == newPath }) {
                if !selectedSkillPaths.contains(newPath) {
                    lastClickedPath = newPath
                    setSelectionProgrammatically([newPath])
                }
            } else {
                setSelectionProgrammatically([])
            }

            // Automatic selections (filter change, deletion) don't count as opening.
            if suppressOpenedStampPath == newPath {
                suppressOpenedStampPath = nil
            } else if let skill = appState.selectedSkill {
                markOpened(skill)
            }
        }
        .onChange(of: allSkills.map(\.resolvedPath)) {
            handleLibraryChange()
        }
        .onChange(of: appState.skillQuickFilter) {
            reconcileHighlightWithVisibleRows()
        }
        .onChange(of: appState.skillSearchScope) {
            reconcileHighlightWithVisibleRows()
        }
        .onChange(of: appState.skillSortOption) {
            reconcileHighlightWithVisibleRows()
        }
        .onChange(of: appState.searchText) { _, newValue in
            searchDebounceTask?.cancel()
            // Clearing the field should feel instant; narrowing can wait a beat.
            guard !newValue.isEmpty else {
                appliedSearchText = ""
                reconcileHighlightWithVisibleRows()
                return
            }
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                appliedSearchText = newValue
                reconcileHighlightWithVisibleRows()
            }
        }
        .onAppear {
            // Arriving with a query already typed (or restored) must filter.
            appliedSearchText = appState.searchText
        }
        .onChange(of: appState.toolKindFilter) {
            reconcileHighlightWithVisibleRows()
        }
        .onChange(of: securityScanningEnabled) {
            if !securityScanningEnabled {
                if appState.sidebarFilter == .securityReview {
                    appState.sidebarFilter = .allSkills
                }
                if appState.skillQuickFilter == .securityFindings {
                    appState.skillQuickFilter = .all
                }
                if appState.skillSortOption == .securityRisk {
                    appState.skillSortOption = .nameAscending
                }
            }
            reconcileHighlightWithVisibleRows()
        }
    }
}

private struct SkillListControlBar: View {
    @Environment(AppState.self) private var appState
    @AppStorage("securityScanningEnabled") private var securityScanningEnabled = true
    let filteredCount: Int
    let totalCount: Int

    private var quickFilters: [SkillQuickFilter] {
        SkillQuickFilter.allCases.filter { filter in
            securityScanningEnabled || filter != .securityFindings
        }
    }

    private var sortOptions: [SkillSortOption] {
        SkillSortOption.allCases.filter { option in
            securityScanningEnabled || option != .securityRisk
        }
    }

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
                ForEach(quickFilters) { filter in
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
                ForEach(sortOptions) { option in
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

            if !appState.recentSearches.isEmpty {
                Menu {
                    ForEach(appState.recentSearches) { search in
                        Button {
                            appState.applyRecentSearch(search)
                        } label: {
                            Label(search.query, systemImage: search.scope.icon)
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        appState.clearRecentSearches()
                    } label: {
                        Label("Clear Recent Searches", systemImage: "trash")
                    }
                } label: {
                    Label("Recent Searches", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                }
                .help("Recent Searches")
            }

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
    var showSecurityStatus: Bool = true
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
                    .accessibilityLabel(skill.itemKind.singularName)
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
            .accessibilityLabel("Favorite")
            .accessibilityValue(skill.isFavorite ? "On" : "Off")

            if skill.hasValidationWarnings {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(skill.validationIssues.map(\.title).joined(separator: "\n"))
                    .accessibilityLabel("Needs review")
                    .accessibilityValue(skill.validationIssues.map(\.title).joined(separator: ", "))
            }

            let securityScan = showSecurityStatus ? skill.securityScan : nil
            if let securityScan, !securityScan.isClean {
                Image(systemName: securityScan.topSeverity?.icon ?? "shield.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(securityScan.topSeverity?.color ?? .secondary)
                    .help("\(securityScan.rating): \(securityScan.summaryText)\n\(securityScan.categorySummaryText)")
                    .accessibilityLabel("Security findings")
                    .accessibilityValue("\(securityScan.rating): \(securityScan.summaryText)")
            }

            if skill.isReadOnly {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .help("Read-only")
                    .accessibilityLabel("Read-only")
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
                    let toolName = tool == .custom ? (skill.customPlatform?.displayName ?? tool.displayName) : tool.displayName
                    ToolIcon(tool: tool, customPlatform: tool == .custom ? skill.customPlatform : nil, size: 14)
                        .help(toolName)
                        .accessibilityLabel(toolName)
                        .opacity(0.6)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
