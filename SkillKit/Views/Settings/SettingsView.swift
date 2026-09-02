import SwiftUI
import SwiftData

extension Notification.Name {
    static let customScanPathsChanged = Notification.Name("customScanPathsChanged")
}

// MARK: - Settings Tab Definition

enum SettingsTab: String, CaseIterable, Identifiable {
    case platforms, scanDirs, servers, agents, security
    #if DEBUG
    case release
    #endif
    case appearance, data, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .platforms: "Platforms"
        case .scanDirs: "Folders"
        case .servers: "Servers"
        case .agents: "Agents"
        case .security: "Security"
        #if DEBUG
        case .release: "Release"
        #endif
        case .appearance: "Appearance"
        case .data: "Data"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .platforms: "checkmark.rectangle.stack"
        case .scanDirs: "folder.badge.gearshape"
        case .servers: "server.rack"
        case .agents: "terminal"
        case .security: "shield.lefthalf.filled"
        #if DEBUG
        case .release: "shippingbox"
        #endif
        case .appearance: "paintpalette"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    private static let logger = AppLogger.settings

    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = true
    @AppStorage("appColorScheme") private var appColorScheme: AppColorScheme = .system
    @AppStorage("securityScanningEnabled") private var securityScanningEnabled = true
    @Environment(\.modelContext) private var modelContext
    @Query private var skills: [Skill]
    @State private var selectedTab: SettingsTab = .platforms
    @State private var customPaths: [String] = []
    @State private var bookmarkRefreshTrigger = false
    @State private var showingPlatformSheet = false
    @State private var editingPlatform: PlatformOption? = nil
    @State private var dataOperationMessage: String?
    @State private var isScanning = false
    @State private var lastScanDate: Date?
    @State private var lastScanCount: Int?
    @State private var includePluginSkills = SkillKitSettings.includePluginSkills
    @State private var libraryRoot = SkillKitSettings.sotDir

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 1) {
                ForEach(SettingsTab.allCases) { tab in
                    SettingsTabButton(tab: tab, isSelected: selectedTab == tab) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // Tab content — each pane sizes itself, no outer ScrollView
            tabContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 680)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loadCustomPaths()
            includePluginSkills = SkillKitSettings.includePluginSkills
            libraryRoot = SkillKitSettings.sotDir
        }
        .onReceive(NotificationCenter.default.publisher(for: .scanDidStart)) { _ in
            isScanning = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .scanDidFinish)) { note in
            isScanning = false
            lastScanDate = .now
            lastScanCount = note.userInfo?["count"] as? Int
        }
        .sheet(isPresented: $showingPlatformSheet) {
            CustomPlatformSheet(platformToEdit: editingPlatform) { platform in
                var list = PlatformOption.customPlatforms
                if let index = list.firstIndex(where: { $0.id == platform.id }) {
                    let oldPlatform = list[index]
                    if isPlatformEnabled(oldPlatform) {
                        let oldPaths = [oldPlatform.expandedSkillsPath, oldPlatform.expandedXcodePath].compactMap(\.self)
                        for path in oldPaths {
                            customPaths.removeAll { $0 == path }
                        }
                        let newPaths = [platform.expandedSkillsPath, platform.expandedXcodePath].compactMap(\.self)
                        for path in newPaths {
                            if !customPaths.contains(path) {
                                customPaths.append(path)
                            }
                        }
                    }
                    list[index] = platform
                } else {
                    list.append(platform)
                    for path in [platform.expandedSkillsPath, platform.expandedXcodePath].compactMap(\.self)
                    where !customPaths.contains(path) {
                        customPaths.append(path)
                    }
                }
                PlatformOption.customPlatforms = list
                saveCustomPaths()
                bookmarkRefreshTrigger.toggle()
            }
        }
        .alert("Data Management", isPresented: Binding(
            get: { dataOperationMessage != nil },
            set: { if !$0 { dataOperationMessage = nil } }
        )) {
            Button("OK", role: .cancel) { dataOperationMessage = nil }
        } message: {
            Text(dataOperationMessage ?? "")
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .platforms:
            platformSettings
        case .scanDirs:
            scanSettings
        case .servers:
            ServersSettingsView()
        case .agents:
            AgentsSettingsView()
        case .security:
            securitySettings
        #if DEBUG
        case .release:
            ReleaseReadinessView()
        #endif
        case .appearance:
            appearanceSettings
        case .data:
            dataSettings
        case .about:
            aboutView
        }
    }

    private var platformSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Platforms")
                .font(.headline)

            Text("Choose which platform folders SkillKit watches. You can reveal folders, grant access, or rescan immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
              VStack(spacing: 0) {
                ForEach(PlatformOption.allPlatforms) { option in
                    PlatformSettingsRow(
                        option: option,
                        isEnabled: isPlatformEnabled(option),
                        hasAccess: hasAccess(option.expandedSkillsPath),
                        isCustom: PlatformOption.customPlatforms.contains(where: { $0.id == option.id }),
                        onToggle: { enabled in
                            setPlatform(option, enabled: enabled)
                        },
                        onAuthorize: {
                            authorizeDirectory(path: option.expandedSkillsPath)
                        },
                        onReveal: {
                            revealPath(option.expandedSkillsPath)
                        },
                        onRescan: {
                            saveCustomPaths()
                        },
                        onEdit: {
                            editingPlatform = option
                            showingPlatformSheet = true
                        },
                        onDelete: {
                            deletePlatform(option)
                        }
                    )

                    if option.id != PlatformOption.allPlatforms.last?.id {
                        Divider()
                            .padding(.leading, 36)
                    }
                }
              }
            }
            .frame(maxHeight: 380)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                rescanButton

                Button {
                    editingPlatform = nil
                    showingPlatformSheet = true
                } label: {
                    Label("Add Custom Platform...", systemImage: "plus.circle")
                }

                Spacer()

                Button("Run Onboarding Again") {
                    didCompleteOnboarding = false
                }
            }

            scanStatusView
        }
        .padding()
        .id(bookmarkRefreshTrigger)
    }

    /// Triggers a full rescan and shows progress. All rescan entry points rescan every
    /// enabled platform and folder; there is no per-platform scan.
    private var rescanButton: some View {
        Button {
            saveCustomPaths()
        } label: {
            if isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…")
                }
            } else {
                Text("Rescan Now")
            }
        }
        .disabled(isScanning)
        .accessibilityLabel("Rescan all platforms")
        .accessibilityValue(isScanning ? "Scanning" : "")
    }

    @ViewBuilder
    private var scanStatusView: some View {
        if isScanning {
            Label("Scanning all platforms and folders…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let lastScanDate {
            let time = lastScanDate.formatted(date: .omitted, time: .shortened)
            let count = lastScanCount.map { " — \($0) item\($0 == 1 ? "" : "s")" } ?? ""
            Label("Last scan: \(time)\(count)", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Library root & plugin skills

    private var librarySettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Library")
                .font(.headline)

            Text("SkillKit keeps the skills, agents, and rules it manages under this root. Changing it triggers a rescan.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "books.vertical")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Library root")
                            .font(.body.weight(.semibold))
                        Text(libraryRoot)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(libraryRoot)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        revealPath(libraryRoot)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal library root in Finder")
                    Button("Choose…") {
                        chooseLibraryRoot()
                    }
                    Button("Reset to Default") {
                        SkillKitSettings.resetSotDirToDefault()
                        libraryRoot = SkillKitSettings.sotDir
                        saveCustomPaths()
                    }
                    .disabled(SkillKitSettings.isUsingDefaultSotDir)
                }

                Divider()

                Toggle(isOn: $includePluginSkills) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Include plugin-installed skills")
                            .font(.body.weight(.semibold))
                        Text("Show skills installed by Claude Code plugins and Claude Desktop. They are read-only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .onChange(of: includePluginSkills) { _, newValue in
                    guard newValue != SkillKitSettings.includePluginSkills else { return }
                    SkillKitSettings.includePluginSkills = newValue
                    saveCustomPaths()
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func chooseLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use as Library Root"
        panel.directoryURL = URL(fileURLWithPath: SkillKitSettings.sotDir)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                SandboxBookmarkManager.saveBookmark(for: url)
                SkillKitSettings.sotDir = url.path
                libraryRoot = url.path
                Self.logger.info("Library root changed to \(url.path)")
                saveCustomPaths()
            }
        }
    }

    private var scanSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            librarySettings

            Divider()
                .padding(.vertical, 4)

            Text("Custom Scan Directories")
                .font(.headline)

            Text("Add a parent directory (e.g. ~/Development) and SkillKit will scan each project inside it for tool-specific skills and agents.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !customPaths.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(customPaths, id: \.self) { path in
                            HStack {
                                Image(systemName: "folder")
                                Text(path)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                let _ = bookmarkRefreshTrigger
                                let hasBookmark = UserDefaults.standard.data(forKey: "bookmark_\(path)") != nil
                                if !hasBookmark {
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.yellow)
                                        Button {
                                            authorizeDirectory(path: path)
                                        } label: {
                                            Text("Authorize")
                                                .foregroundStyle(.blue)
                                                .underline()
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.leading, 8)
                                }

                                Spacer()
                                Button {
                                    revealPath(path)
                                } label: {
                                    Image(systemName: "arrow.up.forward.square")
                                }
                                .buttonStyle(.plain)
                                .help("Reveal in Finder")
                                .accessibilityLabel("Reveal \(path) in Finder")

                                Button {
                                    UserDefaults.standard.set(true, forKey: "dismissed_\(path)")
                                    customPaths.removeAll { $0 == path }
                                    saveCustomPaths()
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Remove directory")
                                .accessibilityLabel("Remove \(path)")
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)

                            if path != customPaths.last {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("No custom directories added.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            HStack {
                rescanButton

                Spacer()
                Button("Add Directory...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        let path = url.path
                        DispatchQueue.main.async {
                            if !customPaths.contains(path) {
                                SandboxBookmarkManager.saveBookmark(for: url)
                                customPaths.append(path)
                                saveCustomPaths()
                            }
                        }
                    }
                }
            }

            scanStatusView
        }
        .padding()
        .id(bookmarkRefreshTrigger)
    }

    private var securitySettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Security")
                .font(.headline)

            Text("Control the static review that flags risky skill and rule patterns.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $securityScanningEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Enable Security Review")
                            .font(.body.weight(.semibold))
                        Text("Shows security findings in the sidebar, dashboard, list rows, and skill detail popover.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                if !securityScanningEnabled {
                    Label("Security review is hidden while disabled. Existing skills are not changed.", systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding()
    }

    private func authorizeDirectory(path: String) {
        Self.logger.info("Authorizing path: \(path)")
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Authorize"
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { 
                Self.logger.info("Authorization cancelled for path: \(path)")
                return 
            }
            Self.logger.info("Panel returned URL: \(url.path)")
            DispatchQueue.main.async {
                SandboxBookmarkManager.saveBookmark(for: url, customKey: path)
                saveCustomPaths()
                bookmarkRefreshTrigger.toggle()
                Self.logger.info("Refresh trigger toggled.")
            }
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance")
                .font(.headline)
            
            Text("Customize the look and feel of SkillKit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Form {
                Picker("Theme", selection: $appColorScheme) {
                    ForEach(AppColorScheme.allCases) { scheme in
                        Text(scheme.rawValue).tag(scheme)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding()
    }

    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Data Management")
                .font(.headline)
            
            Text("Export or import all your skills to a JSON file. " + SkillExporter.exportContentsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            HStack(spacing: 16) {
                Button("Export Data...") {
                    do {
                        if try SkillExporter.shared.export(skills: skills) {
                            dataOperationMessage = "Export completed."
                        }
                    } catch {
                        dataOperationMessage = "Export failed: \(error.localizedDescription)"
                    }
                }
                
                Button("Import Data...") {
                    do {
                        let result = try SkillExporter.shared.importData(modelContext: modelContext)
                        guard !result.wasCancelled else { return }
                        var message = "Imported \(result.importedCount) item\(result.importedCount == 1 ? "" : "s")."
                        if result.skippedCount > 0 {
                            message += " Skipped \(result.skippedCount) duplicate or unsupported item\(result.skippedCount == 1 ? "" : "s")."
                        }
                        dataOperationMessage = message
                    } catch {
                        dataOperationMessage = "Import failed: \(error.localizedDescription)"
                    }
                }
            }
        }
        .padding()
    }

    private var aboutView: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
            }

            Text("SkillKit")
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(appVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Run Onboarding Again") {
                didCompleteOnboarding = false
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func loadCustomPaths() {
        customPaths = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
    }

    private func saveCustomPaths() {
        UserDefaults.standard.set(customPaths, forKey: "customScanPaths")
        NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)
    }

    private func isPlatformEnabled(_ option: PlatformOption) -> Bool {
        customPaths.contains(option.expandedSkillsPath)
    }

    private func hasAccess(_ path: String) -> Bool {
        UserDefaults.standard.data(forKey: "bookmark_\(path)") != nil
    }

    private func setPlatform(_ option: PlatformOption, enabled: Bool) {
        let paths = [option.expandedSkillsPath, option.expandedXcodePath].compactMap(\.self)

        if enabled {
            for path in paths where !customPaths.contains(path) {
                customPaths.append(path)
                UserDefaults.standard.set(false, forKey: "dismissed_\(path)")
            }
        } else {
            for path in paths {
                customPaths.removeAll { $0 == path }
                UserDefaults.standard.set(true, forKey: "dismissed_\(path)")
            }
        }

        customPaths.sort()
        saveCustomPaths()
        bookmarkRefreshTrigger.toggle()
    }

    private func revealPath(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    private func deletePlatform(_ option: PlatformOption) {
        setPlatform(option, enabled: false)
        var list = PlatformOption.customPlatforms
        list.removeAll { $0.id == option.id }
        PlatformOption.customPlatforms = list
        UserDefaults.standard.removeObject(forKey: "bookmark_\(option.expandedSkillsPath)")
        if let xcode = option.expandedXcodePath {
            UserDefaults.standard.removeObject(forKey: "bookmark_\(xcode)")
        }
        bookmarkRefreshTrigger.toggle()
    }
}

// MARK: - Tab Button

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16))
                    .frame(height: 20)
                Text(tab.title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct PlatformSettingsRow: View {
    let option: PlatformOption
    let isEnabled: Bool
    let hasAccess: Bool
    let isCustom: Bool
    let onToggle: (Bool) -> Void
    let onAuthorize: () -> Void
    let onReveal: () -> Void
    let onRescan: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: onToggle
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(option.displayName)
                            .font(.body.weight(.semibold))

                        Text(hasAccess ? "Granted" : "Needs Access")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(hasAccess ? .green : .orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background((hasAccess ? Color.green : Color.orange).opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text(option.shortSkillsPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)

            Spacer()

            if isCustom {
                Button {
                    onEdit?()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Edit custom platform")
                .accessibilityLabel("Edit \(option.displayName)")
                
                Button {
                    onDelete?()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Delete custom platform")
                .accessibilityLabel("Delete \(option.displayName)")
            }

            Button {
                onAuthorize()
            } label: {
                Image(systemName: "lock.open")
            }
            .buttonStyle(.plain)
            .help("Grant folder access")
            .accessibilityLabel("Grant access to \(option.displayName)")
            .disabled(!isEnabled)

            Button {
                onReveal()
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(option.displayName) in Finder")
            .disabled(!isEnabled)

            Button {
                onRescan()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .help("Rescan all platforms")
            .accessibilityLabel("Rescan all platforms")
            .disabled(!isEnabled)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }
}
