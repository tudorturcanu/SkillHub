import Foundation

struct SkillVersionSnapshot: Identifiable, Codable, Hashable {
    let id: UUID
    let skillPath: String
    let createdAt: Date
    let reason: String
    let content: String

    var displayTitle: String {
        createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

enum SkillVersionHistory {
    private static var snapshotsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SkillKit", isDirectory: true)
            .appendingPathComponent("VersionHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func snapshots(for skill: Skill) -> [SkillVersionSnapshot] {
        let url = historyURL(for: skill.filePath)
        guard let data = try? Data(contentsOf: url),
              let snapshots = try? JSONDecoder().decode([SkillVersionSnapshot].self, from: data) else {
            return []
        }
        return snapshots.sorted { $0.createdAt > $1.createdAt }
    }

    /// Number of stored snapshots without materialising their contents.
    /// Still parses the JSON, so cache the answer in view state and refresh
    /// it when the skill changes or is saved — don't call it per render.
    static func snapshotCount(for skill: Skill) -> Int {
        let url = historyURL(for: skill.filePath)
        guard let data = try? Data(contentsOf: url),
              let stubs = try? JSONDecoder().decode([SnapshotStub].self, from: data) else {
            return 0
        }
        return stubs.count
    }

    private struct SnapshotStub: Decodable {
        let id: UUID
    }

    static func recordSnapshot(for skill: Skill, content: String, reason: String) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var snapshots = snapshots(for: skill)
        guard snapshots.first?.content != content else { return }

        snapshots.insert(
            SkillVersionSnapshot(
                id: UUID(),
                skillPath: skill.filePath,
                createdAt: .now,
                reason: reason,
                content: content
            ),
            at: 0
        )

        snapshots = Array(snapshots.prefix(25))
        save(snapshots, for: skill.filePath)
    }

    static func restore(_ snapshot: SkillVersionSnapshot, to skill: Skill) throws {
        try snapshot.content.write(toFile: skill.filePath, atomically: true, encoding: .utf8)
        let parsed = FrontmatterParser.parse(snapshot.content)
        if !parsed.name.isEmpty {
            skill.name = parsed.name
        }
        skill.skillDescription = parsed.description
        skill.content = parsed.content
        skill.frontmatter = parsed.frontmatter

        let attrs = try? FileManager.default.attributesOfItem(atPath: skill.filePath)
        skill.fileModifiedDate = (attrs?[.modificationDate] as? Date) ?? .now
        skill.fileSize = (attrs?[.size] as? Int) ?? snapshot.content.utf8.count
    }

    private static func save(_ snapshots: [SkillVersionSnapshot], for path: String) {
        let url = historyURL(for: path)
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func historyURL(for path: String) -> URL {
        snapshotsDirectory.appendingPathComponent(historyFileName(for: path))
    }

    private static func historyFileName(for path: String) -> String {
        let data = Data(path.utf8)
        return data.map { String(format: "%02x", $0) }.joined() + ".json"
    }
}
