import Foundation

/// A saved query, evaluated against the current library rather than stored membership.
struct SmartCollection: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var query: String
    var scope: SkillSearchScope = .all

    func matchingSkills(in skills: [Skill]) -> [Skill] {
        let parsed = SkillSearchQuery(query)
        return skills.filter { $0.matches(parsed, in: scope) }
    }
}

enum SmartCollectionStore {
    private static let key = "smartCollections"

    static func load(defaults: UserDefaults = .standard) -> [SmartCollection] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SmartCollection].self, from: data)) ?? []
    }

    static func save(_ collections: [SmartCollection], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        defaults.set(data, forKey: key)
    }
}
