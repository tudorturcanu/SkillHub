import SwiftUI

@Observable
final class AppState {
    var selectedTool: ToolSource?
    var selectedSkill: Skill?
    var searchText: String = ""
    var showingNewSkillSheet: Bool = false
    var showingRegistrySheet: Bool = false
    var showingDuplicateSkillSheet: Bool = false
    var skillToDuplicate: Skill? = nil
    var newItemKind: ItemKind = .skill
    var sidebarFilter: SidebarFilter = .dashboard
    /// Filter by item kind within a tool view (nil = show all)
    var toolKindFilter: ItemKind?
    var skillQuickFilter: SkillQuickFilter = .all
    var skillSortOption: SkillSortOption = .nameAscending
    var skillSearchScope: SkillSearchScope = .all
}

enum SidebarFilter: Hashable {
    case dashboard
    case marketplace
    case allSkills
    case allRules
    case needsReview
    case favorites
    case tool(ToolSource)
    case collection(String)
    case server(String)
}

enum SkillQuickFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case needsReview
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
        case .editable: "pencil"
        case .readOnly: "lock"
        case .local: "macwindow"
        case .remote: "server.rack"
        }
    }
}

enum SkillSortOption: String, CaseIterable, Identifiable {
    case nameAscending
    case modifiedNewest
    case modifiedOldest
    case platform
    case warningsFirst

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nameAscending: "Name"
        case .modifiedNewest: "Newest"
        case .modifiedOldest: "Oldest"
        case .platform: "Platform"
        case .warningsFirst: "Needs Review"
        }
    }

    var icon: String {
        switch self {
        case .nameAscending: "textformat"
        case .modifiedNewest: "clock.arrow.circlepath"
        case .modifiedOldest: "clock"
        case .platform: "square.grid.2x2"
        case .warningsFirst: "exclamationmark.triangle"
        }
    }
}

enum SkillSearchScope: String, CaseIterable, Identifiable {
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
