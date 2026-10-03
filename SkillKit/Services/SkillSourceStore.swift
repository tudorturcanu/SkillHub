import CryptoKit
import Foundation

/// Kept outside the indexed library so rescans and cache recovery retain provenance.
enum SkillSourceStore {
    static func load(for filePath: String) throws -> SkillSourceRevision? {
        let url = storageURL(for: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SkillSourceRevision.self, from: Data(contentsOf: url))
    }

    static func save(_ source: SkillSourceRevision, for filePath: String) throws {
        let url = storageURL(for: filePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(source).write(to: url, options: .atomic)
    }

    static func storageURL(for filePath: String) -> URL {
        let resolved = URL(fileURLWithPath: filePath).resolvingSymlinksInPath().path
        let key = SHA256.hash(data: Data(resolved.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SkillKit/SkillSources", isDirectory: true)
            .appendingPathComponent(key + ".json")
    }
}
