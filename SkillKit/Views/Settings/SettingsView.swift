import SwiftUI
import SwiftData

extension Notification.Name {
    static let customScanPathsChanged = Notification.Name("customScanPathsChanged")
}

// MARK: - Settings Tab Definition

enum SettingsTab: String, CaseIterable, Identifiable {
    case platforms, scanDirs, release, appearance, data, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .platforms: "Platforms"
        case .scanDirs: "Scan Directories"
        case .release: "Release"
        case .appearance: "Appearance"
        case .data: "Data Management"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .platforms: "checkmark.rectangle.stack"
        case .scanDirs: "folder.badge.gearshape"
        case .release: "shippingbox"
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
    @Environment(\.modelContext) private var modelContext
    @Query private var skills: [Skill]
    @State private var selectedTab: SettingsTab = .platforms
    @State private var customPaths: [String] = []
    @State private var bookmarkRefreshTrigger = false
    @State private var showingPlatformSheet = false
    @State private var editingPlatform: PlatformOption? = nil

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
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            loadCustomPaths()
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
                }
                PlatformOption.customPlatforms = list
                saveCustomPaths()
                bookmarkRefreshTrigger.toggle()
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .platforms:
            platformSettings
        case .scanDirs:
            scanSettings
        case .release:
            ReleaseReadinessView()
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
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Rescan Now") {
                    saveCustomPaths()
                }

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
        }
        .padding()
        .id(bookmarkRefreshTrigger)
    }

    private var scanSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Scan Directories")
                .font(.headline)

            Text("Add a parent directory (e.g. ~/Development) and SkillKit will scan each project inside it for tool-specific skills and agents.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !customPaths.isEmpty {
                VStack(spacing: 0) {
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

                            Button {
                                UserDefaults.standard.set(true, forKey: "dismissed_\(path)")
                                customPaths.removeAll { $0 == path }
                                saveCustomPaths()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)

                        if path != customPaths.last {
                            Divider()
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("No custom directories added.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            HStack {
                Button("Rescan Now") {
                    saveCustomPaths()
                }

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
        }
        .padding()
        .id(bookmarkRefreshTrigger)
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
            
            Text("Export or import all your skills to a JSON file.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 16) {
                Button("Export Data...") {
                    try? SkillExporter.shared.export(skills: skills)
                }
                
                Button("Import Data...") {
                    try? SkillExporter.shared.importData(modelContext: modelContext)
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
        let saved = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
        var currentPaths = saved
        
        // Automatically suggest the onboarding platform directories.
        let defaultPaths = PlatformOption.onboarding.map(\.expandedSkillsPath)
        var addedNew = false
        
        for path in defaultPaths {
            if !currentPaths.contains(path) && !UserDefaults.standard.bool(forKey: "dismissed_\(path)") {
                currentPaths.append(path)
                addedNew = true
            }
        }
        
        customPaths = currentPaths
        if addedNew {
            saveCustomPaths()
        }
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
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
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
                
                Button {
                    onDelete?()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Delete custom platform")
            }

            Button {
                onAuthorize()
            } label: {
                Image(systemName: "lock.open")
            }
            .buttonStyle(.plain)
            .help("Grant folder access")
            .disabled(!isEnabled)

            Button {
                onReveal()
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
            .disabled(!isEnabled)

            Button {
                onRescan()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .help("Rescan this platform")
            .disabled(!isEnabled)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }
}
