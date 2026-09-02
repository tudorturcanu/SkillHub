import Foundation
import Observation

/// Per-skill "ignore this finding" store.
///
/// Keyed by the skill's file path; values are the security rule IDs the user
/// chose to ignore for that skill. Persisted in `UserDefaults` so it survives
/// rescans (which rewrite the SwiftData row but never touch this store).
///
/// The singleton is `@Observable`, so any view that reads `ruleIDs(for:)` while
/// building its body is refreshed when the user ignores or un-ignores a rule.
@Observable
final class SecurityFindingSuppressions {
    static let shared = SecurityFindingSuppressions()

    static let defaultsKey = "securityFindingSuppressions"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var entries: [String: Set<String>]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] ?? [:]
        self.entries = raw.reduce(into: [:]) { partial, pair in
            let ids = Set(pair.value)
            if !ids.isEmpty { partial[pair.key] = ids }
        }
    }

    /// Rule IDs ignored for the skill at `path`.
    func ruleIDs(for path: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return entries[path] ?? []
    }

    func isSuppressed(_ ruleID: String, for path: String) -> Bool {
        ruleIDs(for: path).contains(ruleID)
    }

    func suppress(_ ruleID: String, for path: String) {
        lock.lock()
        var ids = entries[path] ?? []
        ids.insert(ruleID)
        entries[path] = ids
        lock.unlock()
        persist()
    }

    func unsuppress(_ ruleID: String, for path: String) {
        lock.lock()
        var ids = entries[path] ?? []
        ids.remove(ruleID)
        if ids.isEmpty {
            entries.removeValue(forKey: path)
        } else {
            entries[path] = ids
        }
        lock.unlock()
        persist()
    }

    func clear(for path: String) {
        lock.lock()
        entries.removeValue(forKey: path)
        lock.unlock()
        persist()
    }

    /// Carries suppressions across a rename / move so they follow the skill.
    func move(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        lock.lock()
        if let ids = entries.removeValue(forKey: oldPath) {
            entries[newPath] = (entries[newPath] ?? []).union(ids)
        }
        lock.unlock()
        persist()
    }

    private func persist() {
        lock.lock()
        let snapshot = entries.mapValues { Array($0).sorted() }
        lock.unlock()
        if snapshot.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(snapshot, forKey: Self.defaultsKey)
        }
    }
}
