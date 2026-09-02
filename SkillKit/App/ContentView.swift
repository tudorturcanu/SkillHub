import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \Skill.name) private var skills: [Skill]
    @AppStorage("didShowAutosaveSnackbar") private var didShowAutosaveSnackbar = false
    @State private var scanner: SkillScanner?
    @State private var fileWatcher: FileWatcher?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingAutosaveSnackbar = false
    @State private var isSearchPresented = false
    @State private var didRestoreSession = false
    /// A file the user opened from Finder that isn't in the library yet; selected once it appears.
    @State private var pendingOpenPath: String?

    var body: some View {
        @Bindable var appState = appState

        Group {
            if appState.sidebarFilter == .dashboard {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                } detail: {
                    DashboardView()
                }
            } else if appState.sidebarFilter == .discover {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                } detail: {
                    DiscoverView()
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                } content: {
                    SkillListView()
                } detail: {
                    if let skill = appState.selectedSkill, !skill.isDeleted {
                        SkillDetailView(skill: skill)
                    } else {
                        ContentUnavailableView(
                            "Select an Item",
                            systemImage: "sidebar.left",
                            description: Text("Choose a skill or rule from the list.")
                        )
                    }
                }
                .searchable(text: $appState.searchText, isPresented: $isSearchPresented, prompt: searchPrompt)
                .onSubmit(of: .search) {
                    appState.rememberCurrentSearch()
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showingAutosaveSnackbar {
                AutosaveSnackbar()
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.28), value: showingAutosaveSnackbar)
        .onAppear {
            startScanning()
            restoreSessionIfNeeded()
            showAutosaveSnackbarIfNeeded()
        }
        .onOpenURL { url in
            open(fileURL: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusLibrarySearch)) { _ in
            if appState.sidebarFilter == .dashboard || appState.sidebarFilter == .discover {
                appState.sidebarFilter = .allSkills
            }
            isSearchPresented = true
        }
        .onChange(of: appState.selectedSkill) {
            appState.persistSession()
        }
        .sheet(isPresented: $appState.showingNewSkillSheet) {
            NewSkillSheet()
        }
        .sheet(isPresented: $appState.showingDuplicateSkillSheet) {
            DuplicateSkillSheet()
        }
        .onChange(of: appState.sidebarFilter) {
            appState.persistSession()
            appState.toolKindFilter = nil
            if appState.sidebarFilter == .recent {
                appState.skillSortOption = .lastOpened
            }
            if appState.sidebarFilter == .dashboard || appState.sidebarFilter == .discover {
                appState.selectedSkill = nil
            }
        }
        .onChange(of: skills) {
            setupFileWatcher()
            selectPendingOpenPathIfPossible()
        }
        .frame(minWidth: 900, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: .customScanPathsChanged)) { _ in
            scanner?.scanAll()
            setupFileWatcher()
        }
    }

    private var searchPrompt: String {
        switch appState.sidebarFilter {
        case .allRules: "Search rules..."
        case .collection(let name): "Search \(name)..."
        case .server: "Search remote skills..."
        default: "Search skills and rules..."
        }
    }

    // MARK: - Session restoration

    private func restoreSessionIfNeeded() {
        guard !didRestoreSession else { return }
        didRestoreSession = true

        if let filter = AppState.persistedFilter {
            appState.sidebarFilter = filter
        }
        // Runs after the startup scan has dropped rows whose files are gone,
        // so a skill deleted while the app was closed is never selected.
        if let path = AppState.persistedSkillPath,
           let skill = skills.first(where: { $0.filePath == path }),
           !skill.isDeleted {
            appState.selectedSkill = skill
        }
    }

    // MARK: - Opening files from Finder

    private func open(fileURL url: URL) {
        guard url.isFileURL else { return }
        let resolved = url.resolvingSymlinksInPath().path

        if let existing = skills.first(where: { $0.filePath == resolved || $0.resolvedPath == resolved || $0.filePath == url.path }) {
            select(existing)
            return
        }

        // Grant sandbox access to the containing folder and add it to the scan paths.
        let directory = url.deletingLastPathComponent()
        let scanDirectory = directory.lastPathComponent.lowercased() == "skills"
            ? directory
            : directory.deletingLastPathComponent().lastPathComponent.lowercased() == "skills"
                ? directory.deletingLastPathComponent()
                : directory
        SandboxBookmarkManager.saveBookmark(for: scanDirectory)

        var customPaths = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
        if !customPaths.contains(scanDirectory.path) {
            customPaths.append(scanDirectory.path)
            UserDefaults.standard.set(customPaths, forKey: "customScanPaths")
        }

        pendingOpenPath = resolved
        AppLogger.ui.notice("Opened \(url.path) from Finder; scanning \(scanDirectory.path)")
        NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)
    }

    private func selectPendingOpenPathIfPossible() {
        guard let pending = pendingOpenPath else { return }
        guard let skill = skills.first(where: {
            $0.filePath == pending || $0.resolvedPath == pending ||
            URL(fileURLWithPath: $0.filePath).resolvingSymlinksInPath().path == pending
        }) else { return }
        pendingOpenPath = nil
        select(skill)
    }

    private func select(_ skill: Skill) {
        appState.sidebarFilter = skill.itemKind == .rule ? .allRules : .allSkills
        appState.selectedSkill = skill
    }

    private func showAutosaveSnackbarIfNeeded() {
        guard !didShowAutosaveSnackbar else { return }
        didShowAutosaveSnackbar = true
        showingAutosaveSnackbar = true

        Task {
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                showingAutosaveSnackbar = false
            }
        }
    }

    private func startScanning() {
        AppLogger.ui.notice("App started, beginning initial scan")
        let scanner = SkillScanner(modelContext: modelContext)
        self.scanner = scanner
        scanner.makeActive()
        scanner.removeDeletedSkills()
        scanner.scanAll()

        setupFileWatcher()

        // Sync remote servers in the background
        Task {
            await scanner.syncAllRemoteServers()
        }
    }

    private func setupFileWatcher() {
        guard let scanner = self.scanner else { return }

        var allPaths: [String] = []
        for tool in ToolSource.allCases {
            allPaths.append(contentsOf: tool.globalPaths)
            allPaths.append(contentsOf: tool.globalAgentPaths)
            allPaths.append(contentsOf: tool.globalRulePaths)
        }

        // Include user authorized directories
        let customPaths = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
        allPaths.append(contentsOf: customPaths)

        // Include parent directories of all existing local skills
        for skill in skills {
            if !skill.isRemote {
                let url = URL(fileURLWithPath: skill.filePath)
                let watchPath = skill.isDirectory ? url.path : url.deletingLastPathComponent().path
                allPaths.append(watchPath)
            }
        }

        let fm = FileManager.default
        let home = AppPaths.userHomeDirectory
        let claudePlugins = "\(home)/.claude/plugins"
        let claudePluginCache = "\(claudePlugins)/cache"
        let claudePluginManifest = "\(claudePlugins)/installed_plugins.json"
        for path in [claudePlugins, claudePluginCache, claudePluginManifest] where fm.fileExists(atPath: path) {
            allPaths.append(path)
        }
        let claudeDesktopSessions = "\(home)/Library/Application Support/Claude/local-agent-mode-sessions"
        if fm.fileExists(atPath: claudeDesktopSessions) {
            allPaths.append(claudeDesktopSessions)
        }
        allPaths = Array(Set(allPaths)).sorted()

        // Reuse the existing watcher so it only opens/closes the descriptors that
        // actually changed, and so a rescan mid-edit doesn't tear down every watch.
        let watcher = self.fileWatcher ?? FileWatcher(coalesceInterval: 0.3) { changedPaths in
            scanner.rescan(directories: Array(changedPaths))
        }
        watcher.watchDirectories(allPaths)
        self.fileWatcher = watcher
        AppLogger.ui.notice("File watchers active on \(allPaths.count) directories")
    }
}

private struct AutosaveSnackbar: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 1) {
                Text("Autosave is on")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Changes save automatically after you stop typing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
    }
}
