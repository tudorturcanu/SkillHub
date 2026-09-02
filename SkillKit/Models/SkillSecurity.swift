import Foundation

extension Skill {
    /// The text the scanner runs over: the full on-disk file (frontmatter
    /// included) so finding line numbers line up with the editor gutter.
    /// Falls back to a reconstruction from the stored frontmatter + body for
    /// remote skills or unreadable files.
    var securityScanSourceText: String {
        SkillScanSourceCache.text(for: self)
    }

    /// Fast, in-memory security scan of the skill's main file with the user's
    /// per-skill suppressions applied. Cheap enough to call from a list row
    /// or the dashboard (results are memoized by text).
    var securityScan: SecurityScanResult {
        SecurityScanner.scan(text: securityScanSourceText)
            .excluding(ruleIDs: SecurityFindingSuppressions.shared.ruleIDs(for: filePath))
    }

    var hasSecurityRisk: Bool {
        securityScan.findings.contains { $0.severity >= .high }
    }

    /// Deep scan that also reads code files bundled alongside a directory
    /// skill (scripts/, *.py, *.sh, *.js…). Each file is scanned separately so
    /// line numbers restart per file and every finding carries its
    /// skill-relative `file`. Requires sandbox access to the skill's parent
    /// folder, so it goes through SandboxBookmarkManager and is intended for
    /// an explicit "Scan" action, not passive list rendering.
    ///
    /// - Parameter applyingSuppressions: pass `false` to get the raw result and
    ///   apply `excluding(ruleIDs:)` yourself (the metadata bar does this so
    ///   ignoring/un-ignoring a rule doesn't require a re-scan).
    func deepSecurityScan(applyingSuppressions: Bool = true) -> SecurityScanResult {
        var results = [SecurityScanner.scan(text: securityScanSourceText)]

        if isDirectory, !isRemote {
            let dir = (filePath as NSString).deletingLastPathComponent
            let mainFile = URL(fileURLWithPath: filePath).resolvingSymlinksInPath().path
            let scannable: Set<String> = ["py", "sh", "zsh", "bash", "js", "mjs", "ts", "rb", "pl", "ps1", "txt", "md", "json", "yaml", "yml"]

            SandboxBookmarkManager.resolveAndAccessParent(for: filePath) { _ in
                let fm = FileManager.default
                let root = URL(fileURLWithPath: dir)
                guard let walker = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { return }

                let rootPath = root.resolvingSymlinksInPath().path
                for case let url as URL in walker {
                    guard scannable.contains(url.pathExtension.lowercased()) else { continue }
                    let physical = url.resolvingSymlinksInPath().path
                    guard physical != mainFile else { continue } // already scanned above
                    guard let data = try? Data(contentsOf: url),
                          data.count < 2_000_000, // skip large/binary blobs
                          let body = String(data: data, encoding: .utf8)
                    else { continue }

                    let relative: String
                    if physical.hasPrefix(rootPath + "/") {
                        relative = String(physical.dropFirst(rootPath.count + 1))
                    } else if url.path.hasPrefix(dir + "/") {
                        relative = String(url.path.dropFirst(dir.count + 1))
                    } else {
                        relative = url.lastPathComponent
                    }
                    results.append(SecurityScanner.scan(text: body, file: relative))
                }
            }
        }

        let combined = SecurityScanResult.combining(results)
        guard applyingSuppressions else { return combined }
        return combined.excluding(ruleIDs: SecurityFindingSuppressions.shared.ruleIDs(for: filePath))
    }
}

/// Caches the full file text used for scanning, keyed by the skill's stored
/// path + mtime + size. Those fields are refreshed by the scanner and the
/// editor whenever the file changes, so the cache invalidates itself without
/// a `stat` per list row.
enum SkillScanSourceCache {
    private final class Entry {
        let text: String
        init(_ text: String) { self.text = text }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 512
        return cache
    }()

    static func text(for skill: Skill) -> String {
        guard !skill.isRemote else { return reconstructedText(for: skill) }

        let key = "\(skill.filePath)|\(skill.fileModifiedDate.timeIntervalSinceReferenceDate)|\(skill.fileSize)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.text
        }

        let text = readFullText(at: skill.filePath) ?? reconstructedText(for: skill)
        cache.setObject(Entry(text), forKey: key)
        return text
    }

    /// Drops every cached text (e.g. after a library rescan).
    static func invalidate() {
        cache.removeAllObjects()
    }

    private static func readFullText(at path: String) -> String? {
        SandboxBookmarkManager.resolveAndAccessParent(for: path) { url in
            guard let data = try? Data(contentsOf: url), data.count < 4_000_000 else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// Best-effort full text when the file can't be read: a frontmatter block
    /// rebuilt from the stored keys, one blank line, then the body — the same
    /// shape the editor shows for remote skills.
    static func reconstructedText(for skill: Skill) -> String {
        let frontmatter = skill.frontmatter
        guard !frontmatter.isEmpty else { return skill.content }
        var lines = ["---"]
        for (key, value) in frontmatter.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }
        lines.append("---")
        lines.append("")
        return lines.joined(separator: "\n") + "\n" + skill.content
    }
}
