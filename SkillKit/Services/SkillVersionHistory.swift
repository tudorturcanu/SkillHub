import CryptoKit
import Foundation

struct SkillVersionSnapshot: Identifiable, Codable, Hashable {
    let id: UUID
    let skillPath: String
    let createdAt: Date
    let reason: String
    let content: String
    var sourceRevision: SkillSourceRevision? = nil

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

    /// Updating an installed skill requires a durable rollback point. Unlike routine
    /// autosave history, failure to write this snapshot must stop the update.
    static func recordRequiredSnapshot(for skill: Skill, content: String, reason: String) throws {
        let url = historyURL(for: skill.filePath)
        var history: [SkillVersionSnapshot] = []
        if FileManager.default.fileExists(atPath: url.path) {
            history = try JSONDecoder().decode([SkillVersionSnapshot].self, from: Data(contentsOf: url))
        }
        history.insert(SkillVersionSnapshot(id: UUID(), skillPath: skill.filePath, createdAt: .now,
                                           reason: reason, content: content,
                                           sourceRevision: try SkillSourceStore.load(for: skill.filePath)), at: 0)
        try JSONEncoder().encode(Array(history.prefix(25))).write(to: url, options: .atomic)
    }

    static func restore(_ snapshot: SkillVersionSnapshot, to skill: Skill) throws {
        // Through any symlink: an atomic write would replace the link with a copy.
        let target = URL(fileURLWithPath: skill.filePath).resolvingSymlinksInPath().path
        try snapshot.content.write(toFile: target, atomically: true, encoding: .utf8)
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
        if let source = snapshot.sourceRevision {
            try SkillSourceStore.save(source, for: skill.filePath)
        }
    }

    private static func save(_ snapshots: [SkillVersionSnapshot], for path: String) {
        let url = historyURL(for: path)
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func historyURL(for path: String) -> URL {
        snapshotsDirectory.appendingPathComponent(historyFileName(for: path))
    }

    /// Hex-encodes the path, which keeps every existing history file readable. That name
    /// doubles the path's length, so from 126 bytes up it would exceed the 255-byte
    /// filename limit and every save would fail silently; those paths use a SHA-256 name.
    static func historyFileName(for path: String) -> String {
        let data = Data(path.utf8)
        let hexName = data.map { String(format: "%02x", $0) }.joined() + ".json"
        if hexName.utf8.count <= 255 { return hexName }
        return "sha256-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".json"
    }
}
