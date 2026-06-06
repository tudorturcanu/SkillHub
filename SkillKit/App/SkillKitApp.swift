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
            "sotDir": AppPaths.agentsDirectory
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
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    NotificationCenter.default.post(name: .saveCurrentSkill, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(appState.selectedSkill == nil)
            }
            CommandGroup(after: .help) {
                Toggle("Enable Debug Logging", isOn: $debugLoggingEnabled)
                Divider()
                Button("Export Diagnostic Log…") {
                    let context = sharedModelContainer.mainContext
                    DiagnosticExporter.export(modelContext: context)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(sharedModelContainer)
        }
    }
}
