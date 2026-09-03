import SwiftUI
import SwiftData

/// Gives the editor a chance to write a pending autosave before the process
/// goes away: quitting inside the 1s debounce would otherwise lose the edit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: .applicationWillTerminate, object: nil)
    }
}

@main
struct SkillKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @AppStorage("AgentDebugLogging") private var debugLoggingEnabled = false
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false
    @AppStorage("appColorScheme") private var appColorScheme: AppColorScheme = .system

    init() {
        UserDefaults.standard.register(defaults: [
            "securityScanningEnabled": true
        ])
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: SchemaV1.self)

        do {
            return try StoreBootstrap.makeContainer(schema: schema)
        } catch {
            // Last resort: an in-memory store still lets the app open and
            // rescan the library from disk, which beats refusing to launch.
            // Nothing is saved, so the UI says so rather than letting the user
            // build collections that quietly vanish on quit.
            AppLogger.fileIO.fault("Falling back to an in-memory store: \(error.localizedDescription)")
            Task { @MainActor in StoreBootstrap.runningInMemoryOnly = true }

            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            if let container = try? ModelContainer(for: schema, configurations: [config]) {
                return container
            }
            // The schema itself is unusable, so no configuration of it can
            // load. An empty schema still produces a container the app can
            // launch against, in a clearly degraded state.
            AppLogger.fileIO.fault("The schema could not be loaded at all; starting with an empty store")
            return try! ModelContainer(
                for: Schema([]),
                configurations: [ModelConfiguration(schema: Schema([]), isStoredInMemoryOnly: true)]
            )
        }
    }()

    var body: some Scene {
        WindowGroup {
            if didCompleteOnboarding {
                ContentView()
                    .environment(appState)
                    .preferredColorScheme(appColorScheme.colorScheme)
            } else {
                OnboardingView(didCompleteOnboarding: $didCompleteOnboarding)
                    .preferredColorScheme(appColorScheme.colorScheme)
            }
        }
        .modelContainer(sharedModelContainer)
        .commands {
            TextEditingCommands()
            CommandGroup(after: .newItem) {
                Button("New Skill") {
                    appState.sidebarFilter = .allSkills
                    appState.newItemKind = .skill
                    appState.showingNewSkillSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Rule") {
                    appState.sidebarFilter = .allRules
                    appState.newItemKind = .rule
                    appState.showingNewSkillSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    NotificationCenter.default.post(name: .saveCurrentSkill, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appState.selectedSkill == nil || appState.selectedSkill?.isReadOnly == true)

                Button("Duplicate…") {
                    guard let skill = appState.selectedSkill else { return }
                    appState.skillToDuplicate = skill
                    appState.showingDuplicateSkillSheet = true
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(appState.selectedSkill == nil)

                Button("Move to Trash") {
                    NotificationCenter.default.post(name: .deleteCurrentSkill, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(appState.selectedSkill == nil || appState.selectedSkill?.isReadOnly == true)
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Library") {
                    NotificationCenter.default.post(name: .focusLibrarySearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
            }
            CommandMenu("Format") {
                Button("Bold") {
                    NotificationCenter.default.post(name: .applyMarkdownFormat, object: "bold")
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Italic") {
                    NotificationCenter.default.post(name: .applyMarkdownFormat, object: "italic")
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Strikethrough") {
                    NotificationCenter.default.post(name: .applyMarkdownFormat, object: "strikethrough")
                }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            }
            CommandGroup(before: .sidebar) {
                Button("Editor") {
                    NotificationCenter.default.post(name: .setDetailViewMode, object: "edit")
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("Preview") {
                    NotificationCenter.default.post(name: .setDetailViewMode, object: "preview")
                }
                .keyboardShortcut("2", modifiers: [.command, .option])

                Button("Playground") {
                    NotificationCenter.default.post(name: .setDetailViewMode, object: "playground")
                }
                .keyboardShortcut("3", modifiers: [.command, .option])

                Divider()
            }
            CommandMenu("Library") {
                Button("Dashboard") {
                    appState.sidebarFilter = .dashboard
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Skills") {
                    appState.sidebarFilter = .allSkills
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Rules") {
                    appState.sidebarFilter = .allRules
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Favorites") {
                    appState.sidebarFilter = .favorites
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("Rescan Local Skills") {
                    NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button(appState.selectedSkill?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                    toggleFavorite()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(appState.selectedSkill == nil)

                Button("Show Selected Item in Finder") {
                    revealSelectedSkill()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(appState.selectedSkill == nil || appState.selectedSkill?.isRemote == true)
            }
            CommandGroup(after: .help) {
                #if DEBUG
                Toggle("Enable Debug Logging", isOn: $debugLoggingEnabled)
                Divider()
                #endif
                Button("Export Diagnostic Log…") {
                    let context = sharedModelContainer.mainContext
                    DiagnosticExporter.export(modelContext: context)
                }
            }
        }

        MenuBarExtra("SkillKit", systemImage: "wrench.and.screwdriver") {
            MenuBarView()
                .environment(appState)
                .modelContainer(sharedModelContainer)
                .preferredColorScheme(appColorScheme.colorScheme)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(sharedModelContainer)
                .preferredColorScheme(appColorScheme.colorScheme)
        }
    }

    private func toggleFavorite() {
        guard let skill = appState.selectedSkill else { return }
        skill.isFavorite.toggle()
        do {
            try sharedModelContainer.mainContext.save()
        } catch {
            AppLogger.ui.error("Could not update favorite status: \(error.localizedDescription)")
        }
    }

    private func revealSelectedSkill() {
        guard let skill = appState.selectedSkill, !skill.isRemote else { return }
        NSWorkspace.shared.selectFile(skill.filePath, inFileViewerRootedAtPath: "")
    }
}
