import Foundation

/// User-configurable source-of-truth root directory.
/// Sub-directories for skills, agents, and rules are derived from the root.
struct SkillKitSettings {
    private init() {}

    private static let sotDirKey = "sotDir"

    /// Where the library lives when the user hasn't chosen a custom root.
    static var defaultSotDir: String {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LocalLibrary", isDirectory: true).path
    }

    static var sotDir: String {
        get {
            if let dir = UserDefaults.standard.string(forKey: sotDirKey), !dir.isEmpty {
                return dir
            }
            return defaultSotDir
        }
        set { UserDefaults.standard.set(newValue, forKey: sotDirKey) }
    }

    /// True when no custom library root has been chosen.
    static var isUsingDefaultSotDir: Bool {
        guard let dir = UserDefaults.standard.string(forKey: sotDirKey), !dir.isEmpty else { return true }
        return dir == defaultSotDir
    }

    /// Clears any custom library root so `sotDir` falls back to `defaultSotDir`.
    static func resetSotDirToDefault() {
        UserDefaults.standard.removeObject(forKey: sotDirKey)
    }

    static var sotSkillsDir: String { "\(sotDir)/skills" }
    static var sotAgentsDir: String { "\(sotDir)/agents" }
    static var sotRulesDir: String { "\(sotDir)/rules" }

    /// When false (default), skills installed by CLI and Desktop plugins are excluded from the library.
    static var includePluginSkills: Bool {
        get { UserDefaults.standard.bool(forKey: "includePluginSkills") }
        set { UserDefaults.standard.set(newValue, forKey: "includePluginSkills") }
    }
}
