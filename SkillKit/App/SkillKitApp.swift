import SwiftUI
import SwiftData

@main
struct SkillKitApp: App {
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
            let config = try StoreBootstrap.makeConfiguration(schema: schema)
            return try ModelContainer(
                for: schema,
                migrationPlan: SkillKitMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
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
                .disabled(appState.selectedSkill == nil)
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
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(sharedModelContainer)
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
