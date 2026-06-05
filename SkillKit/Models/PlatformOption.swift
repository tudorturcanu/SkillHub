import Foundation

struct PlatformOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let detail: String
    let skillsPath: String
    let xcodePath: String?

    var expandedSkillsPath: String {
        (skillsPath as NSString).expandingTildeInPath
    }

    var expandedXcodePath: String? {
        xcodePath.map { ($0 as NSString).expandingTildeInPath }
    }

    var shortSkillsPath: String {
        expandedSkillsPath.replacingOccurrences(of: AppPaths.userHomeDirectory, with: "~")
    }

    static let onboarding: [PlatformOption] = [
        PlatformOption(
            id: "codex",
            displayName: "Codex",
            detail: "~/.codex/skills and Xcode Codex",
            skillsPath: "\(AppPaths.userHomeDirectory)/.codex/skills",
            xcodePath: "\(AppPaths.userHomeDirectory)/Library/Developer/Xcode/UserData/Codex/skills"
        ),
        PlatformOption(
            id: "claude",
            displayName: "Claude",
            detail: "~/.claude/skills and Xcode Claude",
            skillsPath: "\(AppPaths.userHomeDirectory)/.claude/skills",
            xcodePath: "\(AppPaths.userHomeDirectory)/Library/Developer/Xcode/UserData/Claude/skills"
        ),
        PlatformOption(
            id: "gemini",
            displayName: "Gemini",
            detail: "~/.gemini/skills",
            skillsPath: "\(AppPaths.userHomeDirectory)/.gemini/skills",
            xcodePath: nil
        ),
        PlatformOption(
            id: "copilot",
            displayName: "GitHub Copilot",
            detail: "~/.copilot/skills",
            skillsPath: "\(AppPaths.userHomeDirectory)/.copilot/skills",
            xcodePath: nil
        )
    ]
}
