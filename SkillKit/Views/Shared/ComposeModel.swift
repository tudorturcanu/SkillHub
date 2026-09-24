import Foundation

// MARK: - Chat Model

enum ChatRole: String, Codable, Sendable { case user, assistant }

enum DiffStatus: String, Codable, Sendable { case pending, accepted, rejected }

struct ChatDiff: Sendable, Codable {
    let path: String
    /// Pre-edit content. `nil` means the file did not exist before the agent wrote it.
    let original: String?
    let originalData: Data?
    let existedBefore: Bool
    let proposed: String
    /// True when the agent already performed the disk write (e.g. Claude direct CLI). On
    /// reject we must restore from `originalData`.
    let agentDidWrite: Bool
    var status: DiffStatus = .pending

    init(
        path: String,
        original: String?,
        originalData: Data?,
        existedBefore: Bool,
        proposed: String,
        agentDidWrite: Bool = false,
        status: DiffStatus = .pending
    ) {
        self.path = path
        self.original = original
        self.originalData = originalData
        self.existedBefore = existedBefore
        self.proposed = proposed
        self.agentDidWrite = agentDidWrite
        self.status = status
    }
}

struct ChatMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: ChatRole
    var text: String
    var thoughtText: String
    var isError: Bool
    var diffs: [ChatDiff]

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        thoughtText: String = "",
        isError: Bool = false,
        diffs: [ChatDiff] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.thoughtText = thoughtText
        self.isError = isError
        self.diffs = diffs
    }
}

// MARK: - Layout Constants

enum ComposeConstants {
    static let defaultPanelHeight: CGFloat = 400
    static let bubbleWidthRatio: CGFloat = 0.80
}

// MARK: - Applying an edit to text that moved on

/// Applies an agent's edit (`original` → `proposed`) to the editor's `current` text, which
/// may have changed since the prompt was sent. Accepting used to write `proposed` over the
/// whole file, discarding anything typed while the agent was thinking.
///
/// Deliberately conservative: each changed region of the edit is applied only when the lines
/// it replaces — and the lines on either side of it — are exactly as they were in
/// `original`. Anything less certain returns `nil`, and the caller asks for a fresh edit.
enum EditRebase {
    static func apply(original: String, proposed: String, onto current: String) -> String? {
        if current == original { return proposed }
        let a = original.components(separatedBy: "\n")
        let b = proposed.components(separatedBy: "\n")
        let c = current.components(separatedBy: "\n")

        let userMap = unchangedLineMap(from: a, to: c)
        var result = c

        // Apply from the bottom up so earlier positions in `result` stay valid.
        for hunk in hunks(from: a, to: b).reversed() {
            guard let position = position(of: hunk, in: userMap, originalCount: a.count, currentCount: c.count) else {
                return nil
            }
            result.replaceSubrange(position..<(position + hunk.range.count), with: hunk.replacement)
        }
        return result.joined(separator: "\n")
    }

    struct Hunk {
        /// Lines of `original` being replaced (empty for a pure insertion).
        let range: Range<Int>
        let replacement: [String]
    }

    static func hunks(from a: [String], to b: [String]) -> [Hunk] {
        let difference = b.difference(from: a)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, !removed.contains(i), !inserted.contains(j) {
                i += 1; j += 1
                continue
            }
            let start = i
            var replacement: [String] = []
            while (i < a.count && removed.contains(i)) || (j < b.count && inserted.contains(j)) {
                if i < a.count, removed.contains(i) { i += 1 }
                if j < b.count, inserted.contains(j) { replacement.append(b[j]); j += 1 }
            }
            hunks.append(Hunk(range: start..<i, replacement: replacement))
        }
        return hunks
    }

    /// For each line of `a` that survives unchanged into `c`, its index in `c`.
    private static func unchangedLineMap(from a: [String], to c: [String]) -> [Int: Int] {
        let difference = c.difference(from: a)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var map: [Int: Int] = [:]
        var i = 0, j = 0
        while i < a.count, j < c.count {
            if removed.contains(i) { i += 1; continue }
            if inserted.contains(j) { j += 1; continue }
            map[i] = j
            i += 1; j += 1
        }
        return map
    }

    /// Where `hunk` starts in the current text, or nil if the user touched its lines or
    /// their immediate neighbours.
    private static func position(of hunk: Hunk, in map: [Int: Int], originalCount: Int, currentCount: Int) -> Int? {
        let s = hunk.range.lowerBound, e = hunk.range.upperBound
        // The replaced lines must be untouched and still contiguous.
        for k in hunk.range {
            guard let mapped = map[k] else { return nil }
            if k > s, map[k - 1].map({ $0 + 1 }) != mapped { return nil }
        }
        // The neighbours must still sit right next to the region.
        let before = s > 0 ? map[s - 1] : -1
        let after = e < originalCount ? map[e] : currentCount
        guard let before, let after else { return nil }
        let start = before + 1
        guard after == start + hunk.range.count else { return nil }
        return start
    }
}
