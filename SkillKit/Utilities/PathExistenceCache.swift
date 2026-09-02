import Foundation

/// Short-lived cache over `FileManager.fileExists`.
///
/// `Skill.validationIssues` stats the skill's path to report a missing file,
/// and the sidebar badge, the list filters, and the sort comparators all read
/// it while building a single frame — so one redraw issued a `stat` per skill
/// several times over, on the main thread. The TTL is short enough that a
/// deleted file is still reported promptly, and `SkillScanner` clears the cache
/// whenever a rescan lands.
enum PathExistenceCache {
    private static let ttl: TimeInterval = 2
    private static let lock = NSLock()
    private static var entries: [String: (exists: Bool, checkedAt: Date)] = [:]

    static func fileExists(atPath path: String) -> Bool {
        let now = Date()

        lock.lock()
        let cached = entries[path]
        lock.unlock()

        if let cached, now.timeIntervalSince(cached.checkedAt) < ttl {
            return cached.exists
        }

        let exists = FileManager.default.fileExists(atPath: path)

        lock.lock()
        entries[path] = (exists, now)
        lock.unlock()

        return exists
    }

    /// Drops every cached answer. Call when the library has been rescanned.
    static func invalidate() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
