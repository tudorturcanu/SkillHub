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

    var body: some View {
        @Bindable var appState = appState

        Group {
            if appState.sidebarFilter == .dashboard {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                } detail: {
                    DashboardView()
                }
            } else if appState.sidebarFilter == .marketplace {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                } detail: {
                    MarketplaceView()
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                } content: {
                    SkillListView()
                } detail: {
                    if let skill = appState.selectedSkill {
                        SkillDetailView(skill: skill)
                    } else {
                        ContentUnavailableView(
                            "Select an Item",
                            systemImage: "sidebar.left",
                            description: Text("Choose a skill or rule from the list.")
                        )
                    }
                }
                .searchable(text: $appState.searchText, prompt: "Search skills...")
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
            showAutosaveSnackbarIfNeeded()
        }
        .sheet(isPresented: $appState.showingNewSkillSheet) {
            NewSkillSheet()
        }
        .sheet(isPresented: $appState.showingRegistrySheet) {
            RegistrySheet()
        }
        .onChange(of: appState.sidebarFilter) {
            appState.toolKindFilter = nil
            if appState.sidebarFilter == .dashboard || appState.sidebarFilter == .marketplace {
                appState.selectedSkill = nil
            }
        }
        .onChange(of: skills) {
            setupFileWatcher()
        }
        .frame(minWidth: 900, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: .customScanPathsChanged)) { _ in
            scanner?.scanAll()
            setupFileWatcher()
        }
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

        // Stop existing watcher first
        self.fileWatcher?.stopAll()

        let watcher = FileWatcher { _ in
            scanner.scanAll()
            scanner.removeDeletedSkills()
        }
        watcher.watchDirectories(allPaths)
        self.fileWatcher = watcher
        AppLogger.ui.notice("File watchers active on \(allPaths.count) directories: \(allPaths)")
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
