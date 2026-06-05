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
        return true
    }

    var expandedSkillsDir: String {
        (globalSkillsDir as NSString).expandingTildeInPath
    }

    static var installed: [AgentTarget] {
        all.filter(\.isInstalled)
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
                evidencePaths: [],
                appBundleName: nil,
                cliBinaryName: nil
            ),
            AgentTarget(
                id: "claude-code",
                displayName: "Claude Code",
                globalSkillsDir: "\(home)/.claude/skills",
                skillFileName: "SKILL.md",
                evidencePaths: [],
                appBundleName: nil,
                cliBinaryName: nil
            ),
            AgentTarget(
                id: "codex",
                displayName: "Codex",
                globalSkillsDir: "\(home)/.codex/skills",
                skillFileName: "SKILL.md",
                evidencePaths: [],
                appBundleName: nil,
                cliBinaryName: nil
            ),
            AgentTarget(
                id: "amp",
                displayName: "Amp",
                globalSkillsDir: "\(configHome)/amp/skills",
                skillFileName: "SKILL.md",
                evidencePaths: [],
                appBundleName: nil,
                cliBinaryName: nil
            ),
            AgentTarget(
                id: "opencode",
                displayName: "OpenCode",
                globalSkillsDir: "\(configHome)/opencode/skills",
                skillFileName: "SKILL.md",
                evidencePaths: [],
                appBundleName: nil,
                cliBinaryName: nil
            ),
            AgentTarget(
                id: "goose",
                displayName: "Goose",
                globalSkillsDir: "\(configHome)/goose/skills",
                skillFileName: "SKILL.md",
                evidencePaths: [],
                appBundleName: nil,
                cliBinaryName: nil
            ),
            AgentTarget(
                id: "cursor",
                displayName: "Cursor",
                globalSkillsDir: "\(home)/.cursor/skills",
                skillFileName: "SKILL.md",
                evidencePaths: [],
                appBundleName: nil,
                cliBinaryName: nil
            ),
            AgentTarget(
                id: "windsurf",
                displayName: "Windsurf",
                globalSkillsDir: "\(home)/.codeium/windsurf/skills",
                skillFileName: "SKILL.md",
                evidencePaths: [],
                appBundleName: nil,
                cliBinaryName: nil
            ),
            AgentTarget(
                id: "warp",
                displayName: "Warp",
                globalSkillsDir: "\(home)/.warp/skills",
                skillFileName: "SKILL.md",
                evidencePaths: [],
                appBundleName: nil,
                cliBinaryName: nil
            ),
        ]
    }()
}
