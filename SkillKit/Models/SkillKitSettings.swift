import Foundation

/// User-configurable source-of-truth root directory.
/// Sub-directories for skills, agents, and rules are derived from the root.
struct SkillKitSettings {
    private init() {}

    static var sotDir: String {
        get {
            if let dir = UserDefaults.standard.string(forKey: "sotDir") {
                return dir
            }
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let sot = appSupport.appendingPathComponent("LocalLibrary", isDirectory: true).path
            return sot
        }
        set { UserDefaults.standard.set(newValue, forKey: "sotDir") }
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
