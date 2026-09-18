import SwiftUI

@Observable
final class AppState {
    var selectedTool: ToolSource?
    var selectedSkill: Skill?
    var searchText: String = ""
    var showingNewSkillSheet: Bool = false
    var showingDuplicateSkillSheet: Bool = false
    var skillToDuplicate: Skill? = nil
    var skillToRename: Skill? = nil
    var newItemKind: ItemKind = .skill
    var sidebarFilter: SidebarFilter = .dashboard
    /// Filter by item kind within a tool view (nil = show all)
    var toolKindFilter: ItemKind?
    var skillQuickFilter: SkillQuickFilter = .all
    var skillSortOption: SkillSortOption = .nameAscending
    var skillSearchScope: SkillSearchScope = .all
    var recentSearches: [RecentSkillSearch] = RecentSkillSearchStore.load()

    // MARK: - Session restoration

    private static let lastFilterKey = "lastSidebarFilter"
    private static let lastSkillPathKey = "lastSelectedSkillPath"

    /// Persists the current filter and selection so the next launch can restore them.
    func persistSession() {
        let defaults = UserDefaults.standard
        defaults.set(sidebarFilter.persistedValue, forKey: Self.lastFilterKey)
        if let path = selectedSkill?.filePath {
            defaults.set(path, forKey: Self.lastSkillPathKey)
        } else {
            defaults.removeObject(forKey: Self.lastSkillPathKey)
        }
    }

    /// The filter saved by the previous session, if any.
    static var persistedFilter: SidebarFilter? {
        guard let raw = UserDefaults.standard.string(forKey: lastFilterKey) else { return nil }
        return SidebarFilter(persistedValue: raw)
    }

    /// The selected skill path saved by the previous session, if any.
    static var persistedSkillPath: String? {
        UserDefaults.standard.string(forKey: lastSkillPathKey)
    }

    func rememberCurrentSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return }

        let search = RecentSkillSearch(query: query, scope: skillSearchScope, lastUsed: .now)
        recentSearches.removeAll { $0.id == search.id }
        recentSearches.insert(search, at: 0)
        RecentSkillSearchStore.save(recentSearches)
    }

    func applyRecentSearch(_ search: RecentSkillSearch) {
        searchText = search.query
        skillSearchScope = search.scope
        rememberCurrentSearch()
    }

    func clearRecentSearches() {
        recentSearches = []
        RecentSkillSearchStore.save([])
    }
}

enum SidebarFilter: Hashable {
    case dashboard
    case discover
    case recent
    case allSkills
    case allRules
    case needsReview
    case securityReview
    case favorites
    case tool(ToolSource)
    case customPlatform(id: String)
    case collection(String)
    case server(String)
}

extension SidebarFilter {
    /// Stable string form used to restore the sidebar selection across launches.
    var persistedValue: String {
        switch self {
        case .dashboard: "dashboard"
        case .discover: "discover"
        case .recent: "recent"
        case .allSkills: "allSkills"
        case .allRules: "allRules"
        case .needsReview: "needsReview"
        case .securityReview: "securityReview"
        case .favorites: "favorites"
        case .tool(let tool): "tool:\(tool.rawValue)"
        case .customPlatform(let id): "customPlatform:\(id)"
        case .collection(let name): "collection:\(name)"
        case .server(let id): "server:\(id)"
        }
    }

    init?(persistedValue: String) {
        switch persistedValue {
        case "dashboard": self = .dashboard
        case "discover": self = .discover
        case "recent": self = .recent
        case "allSkills": self = .allSkills
        case "allRules": self = .allRules
        case "needsReview": self = .needsReview
        case "securityReview": self = .securityReview
        case "favorites": self = .favorites
        default:
            guard let separator = persistedValue.firstIndex(of: ":") else { return nil }
            let kind = persistedValue[..<separator]
            let payload = String(persistedValue[persistedValue.index(after: separator)...])
            switch kind {
            case "tool":
                guard let tool = ToolSource(rawValue: payload) else { return nil }
                self = .tool(tool)
            case "customPlatform": self = .customPlatform(id: payload)
            case "collection": self = .collection(payload)
            case "server": self = .server(payload)
            default: return nil
            }
        }
    }
}

enum SkillQuickFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case needsReview
    case securityFindings
    case editable
    case readOnly
    case local
    case remote

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .needsReview: "Needs Review"
        case .securityFindings: "Security"
        case .editable: "Editable"
        case .readOnly: "Read-only"
        case .local: "Local"
        case .remote: "Remote"
        }
    }

    var icon: String {
        switch self {
        case .all: "line.3.horizontal.decrease.circle"
        case .favorites: "star"
        case .needsReview: "exclamationmark.triangle"
        case .securityFindings: "shield.lefthalf.filled"
        case .editable: "pencil"
        case .readOnly: "lock"
        case .local: "macwindow"
        case .remote: "server.rack"
        }
    }
}

enum SkillSortOption: String, CaseIterable, Identifiable {
    case nameAscending
    case lastOpened
    case modifiedNewest
    case modifiedOldest
    case platform
    case warningsFirst
    case securityRisk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nameAscending: "Name"
        case .lastOpened: "Last Opened"
        case .modifiedNewest: "Newest"
        case .modifiedOldest: "Oldest"
        case .platform: "Platform"
        case .warningsFirst: "Needs Review"
        case .securityRisk: "Security Risk"
        }
    }

    var icon: String {
        switch self {
        case .nameAscending: "textformat"
        case .lastOpened: "clock.badge.checkmark"
        case .modifiedNewest: "clock.arrow.circlepath"
        case .modifiedOldest: "clock"
        case .platform: "square.grid.2x2"
        case .warningsFirst: "exclamationmark.triangle"
        case .securityRisk: "shield.lefthalf.filled"
        }
    }
}

enum SkillSearchScope: String, CaseIterable, Identifiable, Codable {
    case all
    case title
    case description
    case content
    case path
    case metadata

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All Fields"
        case .title: "Title"
        case .description: "Description"
        case .content: "Content"
        case .path: "Path"
        case .metadata: "Metadata"
        }
    }

    var icon: String {
        switch self {
        case .all: "magnifyingglass"
        case .title: "textformat"
        case .description: "text.alignleft"
        case .content: "doc.text"
        case .path: "folder"
        case .metadata: "tag"
        }
    }
}
