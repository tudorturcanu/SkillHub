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
        default: return .gray
        }
    }

    static let onboarding: [PlatformOption] = [
        PlatformOption(
            id: "codex",
            displayName: "Codex",
            detail: "~/.codex/skills and Xcode Codex",
            skillsPath: "\(AppPaths.userHomeDirectory)/.codex/skills",
            xcodePath: "\(AppPaths.userHomeDirectory)/Library/Developer/Xcode/UserData/Codex/skills",
            iconName: "book.closed",
            iconColorName: "purple"
        ),
        PlatformOption(
            id: "claude",
            displayName: "Claude",
            detail: "~/.claude/skills and Xcode Claude",
            skillsPath: "\(AppPaths.userHomeDirectory)/.claude/skills",
            xcodePath: "\(AppPaths.userHomeDirectory)/Library/Developer/Xcode/UserData/Claude/skills",
            iconName: "brain.head.profile",
            iconColorName: "orange"
        ),
        PlatformOption(
            id: "gemini",
            displayName: "Gemini",
            detail: "~/.gemini/skills",
            skillsPath: "\(AppPaths.userHomeDirectory)/.gemini/skills",
            xcodePath: nil,
            iconName: "sparkles",
            iconColorName: "blue"
        ),
        PlatformOption(
            id: "copilot",
            displayName: "GitHub Copilot",
            detail: "~/.copilot/skills",
            skillsPath: "\(AppPaths.userHomeDirectory)/.copilot/skills",
            xcodePath: nil,
            iconName: "airplane",
            iconColorName: "green"
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

