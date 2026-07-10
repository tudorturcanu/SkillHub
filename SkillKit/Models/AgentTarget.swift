import Foundation

struct AgentTarget: Identifiable, Hashable {
    let id: String
    let displayName: String
    let globalSkillsDir: String
    let skillFileName: String

    let evidencePaths: [String]
    let appBundleName: String?
    let cliBinaryName: String?

    var isInstalled: Bool {
        // "Global" is SkillKit's own library target, not a third-party app.
        if id == "agents" { return true }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: expandedSkillsDir) { return true }
        if evidencePaths.map({ ($0 as NSString).expandingTildeInPath }).contains(where: fileManager.fileExists) {
            return true
        }
        if let appBundleName, appBundleExists(appBundleName) { return true }
        if let cliBinaryName, ToolSource.cliBinaryURL(cliBinaryName) != nil { return true }
        return false
    }

    var expandedSkillsDir: String {
        (globalSkillsDir as NSString).expandingTildeInPath
    }

    static var installed: [AgentTarget] {
        all.filter(\.isInstalled)
    }

    private func appBundleExists(_ name: String) -> Bool {
        let home = AppPaths.userHomeDirectory
        return ["/Applications/\(name).app", "\(home)/Applications/\(name).app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    static let all: [AgentTarget] = {
        let home = "/Users/\(NSUserName())"
        let configHome: String = {
            if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
                return xdg
            }
            return "\(home)/.config"
        }()

        return [
            AgentTarget(
                id: "agents",
                displayName: "Global",
                globalSkillsDir: "\(home)/.agents/skills",
                skillFileName: "SKILL.md",
                evidencePaths: ["\(home)/.agents"],
                appBundleName: nil,
                cliBinaryName: nil
            ),
            AgentTarget(
                id: "claude-code",
                displayName: "Claude Code",
                globalSkillsDir: "\(home)/.claude/skills",
                skillFileName: "SKILL.md",
                evidencePaths: ["\(home)/.claude"],
                appBundleName: nil,
                cliBinaryName: "claude"
            ),
            AgentTarget(
                id: "codex",
                displayName: "Codex",
                globalSkillsDir: "\(home)/.codex/skills",
                skillFileName: "SKILL.md",
                evidencePaths: ["\(home)/.codex"],
                appBundleName: nil,
                cliBinaryName: "codex"
            ),
            AgentTarget(
                id: "amp",
                displayName: "Amp",
                globalSkillsDir: "\(configHome)/amp/skills",
                skillFileName: "SKILL.md",
                evidencePaths: ["\(configHome)/amp"],
                appBundleName: nil,
                cliBinaryName: "amp"
            ),
            AgentTarget(
                id: "opencode",
                displayName: "OpenCode",
                globalSkillsDir: "\(configHome)/opencode/skills",
                skillFileName: "SKILL.md",
                evidencePaths: ["\(configHome)/opencode"],
                appBundleName: nil,
                cliBinaryName: "opencode"
            ),
            AgentTarget(
                id: "goose",
                displayName: "Goose",
                globalSkillsDir: "\(configHome)/goose/skills",
                skillFileName: "SKILL.md",
                evidencePaths: ["\(configHome)/goose"],
                appBundleName: nil,
                cliBinaryName: "goose"
            ),
            AgentTarget(
                id: "cursor",
                displayName: "Cursor",
                globalSkillsDir: "\(home)/.cursor/skills",
                skillFileName: "SKILL.md",
                evidencePaths: ["\(home)/.cursor"],
                appBundleName: "Cursor",
                cliBinaryName: "cursor"
            ),
            AgentTarget(
                id: "windsurf",
                displayName: "Windsurf",
                globalSkillsDir: "\(home)/.codeium/windsurf/skills",
                skillFileName: "SKILL.md",
                evidencePaths: ["\(home)/.codeium/windsurf"],
                appBundleName: "Windsurf",
                cliBinaryName: "windsurf"
            ),
            AgentTarget(
                id: "warp",
                displayName: "Warp",
                globalSkillsDir: "\(home)/.warp/skills",
                skillFileName: "SKILL.md",
                evidencePaths: ["\(home)/.warp"],
                appBundleName: "Warp",
                cliBinaryName: "warp"
            ),
        ]
    }()
}
