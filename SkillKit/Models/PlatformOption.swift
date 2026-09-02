import Foundation
import SwiftUI

struct PlatformOption: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let detail: String
    let skillsPath: String
    let xcodePath: String?
    let iconName: String
    let iconColorName: String

    var expandedSkillsPath: String {
        (skillsPath as NSString).expandingTildeInPath
    }

    var expandedXcodePath: String? {
        xcodePath.map { ($0 as NSString).expandingTildeInPath }
    }

    var shortSkillsPath: String {
        expandedSkillsPath.replacingOccurrences(of: AppPaths.userHomeDirectory, with: "~")
    }

    var color: Color {
        switch iconColorName {
        case "purple": return .purple
        case "orange": return .orange
        case "blue": return .blue
        case "green": return .green
        case "cyan": return .cyan
        case "red": return .red
        case "pink": return .pink
        case "teal": return .teal
        case "indigo": return .indigo
        case "mint": return .mint
        case "brown": return .brown
        case "yellow": return .yellow
        default: return .gray
        }
    }

    /// The scanner tool this built-in platform corresponds to, if any. Built-in option ids
    /// match `ToolSource.rawValue`; custom platforms return nil.
    var toolSource: ToolSource? {
        ToolSource(rawValue: id)
    }

    /// Asset-catalog logo for built-in platforms (`tool-*` imagesets), nil for SF-symbol-only ones.
    var logoAssetName: String? {
        switch id {
        case "claude": "tool-claude"
        case "codex": "tool-codex"
        case "copilot": "tool-copilot"
        case "cursor": "tool-cursor"
        case "windsurf": "tool-windsurf"
        case "amp": "tool-amp"
        case "opencode": "tool-opencode"
        case "antigravity": "tool-antigravity"
        case "augment": "tool-augment"
        case "openclaw": "tool-openclaw"
        default: nil
        }
    }

    /// True when the tool appears to be installed: its skills folder, its Xcode folder, or the
    /// tool's configuration directory (the skills folder's parent) exists on disk.
    var isDetected: Bool {
        let fm = FileManager.default
        var candidates = [expandedSkillsPath]
        if let expandedXcodePath { candidates.append(expandedXcodePath) }
        let parent = URL(fileURLWithPath: expandedSkillsPath).deletingLastPathComponent().path
        if parent != AppPaths.userHomeDirectory, parent != "/" {
            candidates.append(parent)
        }
        return candidates.contains { fm.fileExists(atPath: $0) }
    }

    private static let home = AppPaths.userHomeDirectory

    private static var xdgConfigHome: String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return xdg
        }
        return "\(home)/.config"
    }

    /// Built-in platforms offered during onboarding and in Settings → Platforms. Ids match
    /// `ToolSource.rawValue` so the scanner can tag folders with the right tool.
    static let onboarding: [PlatformOption] = [
        PlatformOption(
            id: "claude",
            displayName: "Claude Code",
            detail: "~/.claude/skills and Xcode Claude",
            skillsPath: "\(home)/.claude/skills",
            xcodePath: "\(home)/Library/Developer/Xcode/UserData/Claude/skills",
            iconName: "brain.head.profile",
            iconColorName: "orange"
        ),
        PlatformOption(
            id: "codex",
            displayName: "Codex",
            detail: "~/.codex/skills and Xcode Codex",
            skillsPath: "\(home)/.codex/skills",
            xcodePath: "\(home)/Library/Developer/Xcode/UserData/Codex/skills",
            iconName: "book.closed",
            iconColorName: "purple"
        ),
        PlatformOption(
            id: "copilot",
            displayName: "GitHub Copilot",
            detail: "~/.copilot/skills",
            skillsPath: "\(home)/.copilot/skills",
            xcodePath: nil,
            iconName: "airplane",
            iconColorName: "green"
        ),
        PlatformOption(
            id: "agents",
            displayName: "Global (.agents)",
            detail: "~/.agents/skills — shared across agents",
            skillsPath: "\(home)/.agents/skills",
            xcodePath: nil,
            iconName: "globe",
            iconColorName: "mint"
        ),
        PlatformOption(
            id: "cursor",
            displayName: "Cursor",
            detail: "~/.cursor/skills",
            skillsPath: "\(home)/.cursor/skills",
            xcodePath: nil,
            iconName: "cursorarrow.rays",
            iconColorName: "blue"
        ),
        PlatformOption(
            id: "windsurf",
            displayName: "Windsurf",
            detail: "~/.codeium/windsurf/skills",
            skillsPath: "\(home)/.codeium/windsurf/skills",
            xcodePath: nil,
            iconName: "wind",
            iconColorName: "teal"
        ),
        PlatformOption(
            id: "amp",
            displayName: "Amp",
            detail: "~/.config/amp/skills",
            skillsPath: "\(xdgConfigHome)/amp/skills",
            xcodePath: nil,
            iconName: "bolt.fill",
            iconColorName: "pink"
        ),
        PlatformOption(
            id: "opencode",
            displayName: "OpenCode",
            detail: "~/.config/opencode/skills",
            skillsPath: "\(xdgConfigHome)/opencode/skills",
            xcodePath: nil,
            iconName: "terminal",
            iconColorName: "red"
        ),
        PlatformOption(
            id: "hermes",
            displayName: "Hermes",
            detail: "~/.hermes/skills",
            skillsPath: "\(home)/.hermes/skills",
            xcodePath: nil,
            iconName: "bolt.horizontal.circle",
            iconColorName: "brown"
        ),
        PlatformOption(
            id: "antigravity",
            displayName: "Antigravity",
            detail: "~/.antigravity/skills",
            skillsPath: "\(home)/.antigravity/skills",
            xcodePath: nil,
            iconName: "arrow.up.circle",
            iconColorName: "red"
        ),
        PlatformOption(
            id: "augment",
            displayName: "Auggie",
            detail: "~/.augment/skills",
            skillsPath: "\(home)/.augment/skills",
            xcodePath: nil,
            iconName: "wand.and.sparkles",
            iconColorName: "cyan"
        ),
        PlatformOption(
            id: "pi",
            displayName: "Pi",
            detail: "~/.pi/agent/skills",
            skillsPath: "\(home)/.pi/agent/skills",
            xcodePath: nil,
            iconName: "sparkles",
            iconColorName: "cyan"
        ),
        PlatformOption(
            id: "openclaw",
            displayName: "OpenClaw",
            detail: "~/.openclaw/skills",
            skillsPath: "\(home)/.openclaw/skills",
            xcodePath: nil,
            iconName: "server.rack",
            iconColorName: "indigo"
        )
    ]

    static var customPlatforms: [PlatformOption] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "customPlatforms") else { return [] }
            return (try? JSONDecoder().decode([PlatformOption].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "customPlatforms")
            }
        }
    }

    static var allPlatforms: [PlatformOption] {
        onboarding + customPlatforms
    }
}
