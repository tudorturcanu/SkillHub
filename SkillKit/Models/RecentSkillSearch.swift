import Foundation

struct RecentSkillSearch: Codable, Hashable, Identifiable {
    var query: String
    var scope: SkillSearchScope
    var lastUsed: Date

    var id: String {
        "\(scope.rawValue):\(query.lowercased())"
    }
}

enum RecentSkillSearchStore {
    private static let key = "recentSkillSearches"
    private static let limit = 8

    static func load() -> [RecentSkillSearch] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RecentSkillSearch].self, from: data)) ?? []
    }

    static func save(_ searches: [RecentSkillSearch]) {
        guard let data = try? JSONEncoder().encode(Array(searches.prefix(limit))) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
