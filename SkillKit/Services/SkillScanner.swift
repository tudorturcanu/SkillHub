import Foundation
import SwiftData
import os

/// Data collected from the filesystem for a single skill, before SwiftData persistence.
struct ScannedSkillData: Sendable {
    let fileURL: URL
    let resolvedPath: String
    let toolSource: ToolSource
    let isDirectory: Bool
    let isGlobal: Bool
    let name: String
    let skillDescription: String
    let content: String
    let frontmatter: [String: String]
    let modDate: Date
    let fileSize: Int
    let kind: ItemKind
}

/// Restricts a collection pass to paths that intersect a set of changed
/// directories (or files). `nil` directories = admit everything.
///
/// "Intersects" is symmetric on purpose: a root *above* a changed directory
/// must be walked to reach it, and an entry *below* a changed directory is
/// what changed.
struct ScanPathFilter: Sendable {
    let directories: [String]?

    static let all = ScanPathFilter(directories: nil)

    init(directories: [String]?) {
        guard let directories else {
            self.directories = nil
            return
        }
        var expanded = Set<String>()
        for dir in directories {
            let standardized = (dir as NSString).standardizingPath
            expanded.insert(standardized)
            expanded.insert(URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path)
        }
        self.directories = expanded.sorted()
    }

    /// `path` is a changed directory, lies under one, or is an ancestor of one.
    func admits(_ path: String) -> Bool {
        guard let directories else { return true }
        let candidates = [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
        return directories.contains { dir in
            candidates.contains { candidate in
                candidate == dir || candidate.hasPrefix(dir + "/") || dir.hasPrefix(candidate + "/")
            }
        }
    }

    /// `path` is a changed directory or lies under one (no ancestors). Use this
    /// to decide whether a *result* belongs to the changed set.
    func covers(_ path: String) -> Bool {
        guard let directories else { return true }
        let candidates = [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
        return directories.contains { dir in
            candidates.contains { $0 == dir || $0.hasPrefix(dir + "/") }
        }
    }
}

@Observable
final class SkillScanner {
    private let modelContext: ModelContext
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    private var incrementalTask: Task<Void, Never>?
    private var queuedIncrementalDirectories = Set<String>()

    /// Paths written by the app itself (editor saves, restores, lint fixes)
    /// with the time of the write. A watcher event that is fully explained by
    /// one of these within `ownWriteGracePeriod` is ignored, since the model
    /// row was already updated by whoever wrote the file.
    private var recentOwnWrites: [String: Date] = [:]
    private let ownWriteGracePeriod: TimeInterval = 3

    /// Filenames that are tool config/meta files, not skills.
    private static let ignoredFileNames: Set<String> = [
        "README.md",
        "README",
        "CLAUDE.md",
        "AGENTS.md",
        "AGENTS.override.md",
        "global_rules.md",
        "SYSTEM.md",
        "APPEND_SYSTEM.md",
        "LICENSE.md",
        "LICENSE",
        "CHANGELOG.md",
    ]

    private static func shouldIgnoreLooseMarkdownFile(named fileName: String) -> Bool {
        return ignoredFileNames.contains(fileName)
    }

    /// The scanner backing the main window, so views that write skill files can
    /// mark those writes as the app's own (`ignoreNextChange(for:)`) and avoid
    /// a redundant rescan. Set by the most recently created scanner.
    @MainActor static weak var active: SkillScanner?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Registers this scanner as the one backing the main window. Only the
    /// window's scanner should call this — short-lived scanners (e.g. a manual
    /// server sync) must not take the slot, or clearing it on deinit would
    /// leave editor saves unable to mark their own writes.
    @MainActor
    func makeActive() {
        SkillScanner.active = self
    }

    /// Project-level paths to probe inside each project directory
    private static let projectProbes: [(subpath: String, tool: ToolSource, kind: ItemKind)] = [
        (".claude/skills", .claude, .skill),
        (".claude/agents", .claude, .skill),
        (".cursor/skills", .cursor, .skill),
        (".cursor/rules", .cursor, .rule),
        (".cursor/agents", .cursor, .skill),
        (".codex/skills", .codex, .skill),
        (".codex/agents", .codex, .skill),
        (".windsurf/rules", .windsurf, .rule),
        (".github", .copilot, .skill),
        (".github/agents", .copilot, .skill),
        (".config/amp/skills", .amp, .skill),
        (".opencode/skills", .opencode, .skill),
        (".hermes/skills", .hermes, .skill),
        (".antigravity/skills", .antigravity, .skill),
    ]

    /// Full library rescan. Rewalks every configured root and reconciles
    /// every local row. Posts `.scanDidStart` / `.scanDidFinish`.
    func scanAll() {
        let start = CFAbsoluteTimeGetCurrent()
        AppLogger.scanning.notice("Scan started")

        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let customPaths = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
        let includePlugins = SkillKitSettings.includePluginSkills
        Self.postOnMain(.scanDidStart, userInfo: ["incremental": false])
        scanTask = Task.detached { [weak self] in
            let results = Self.collectAllSkills(customPaths: customPaths, includePlugins: includePlugins)
            guard !Task.isCancelled else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            AppLogger.scanning.notice("File collection done: \(results.count) skills in \(String(format: "%.2f", elapsed))s")

            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                PathExistenceCache.invalidate()
                SkillScanSourceCache.invalidate()
                self.applyResults(results)
                let total = CFAbsoluteTimeGetCurrent() - start
                AppLogger.scanning.notice("Scan complete: \(results.count) skills applied in \(String(format: "%.2f", total))s")
                NotificationCenter.default.post(
                    name: .scanDidFinish,
                    object: self,
                    userInfo: ["count": results.count, "incremental": false]
                )
            }
        }
    }

    // MARK: - Incremental scanning

    /// Records that the app itself is about to write (or just wrote) `path`, so
    /// the watcher event it causes doesn't trigger a rescan of that file. Call
    /// it right before/after saving from the editor, restoring a snapshot, or
    /// applying a lint fix. The entry expires after a few seconds.
    func ignoreNextChange(for path: String) {
        let standardized = (path as NSString).standardizingPath
        recentOwnWrites[standardized] = .now
        recentOwnWrites[URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path] = .now
    }

    /// Rescans only the skills under `directories` (which may be directories
    /// or individual skill files, as reported by `FileWatcher`): discovers new
    /// skills there, updates rows whose on-disk mtime/size changed, and drops
    /// rows whose files are gone. Rows outside those directories are untouched.
    /// Posts `.scanDidStart` / `.scanDidFinish` (userInfo `"incremental": true`).
    ///
    /// Calls that arrive while an incremental pass is running are queued and
    /// merged into one follow-up pass. Use `scanAll()` for a full reconcile.
    func rescan(directories: [String]) {
        pruneExpiredOwnWrites()
        // We deliberately do NOT skip the pass for paths we just wrote: an
        // external editor can touch the same file inside the grace window, and
        // a skipped pass would leave that edit invisible until a full rescan.
        // The pass itself is cheap for unchanged rows (mtime/size are compared
        // before anything is rewritten), so consume the own-write markers here
        // and let the scan decide whether anything actually differs.
        for directory in directories where isExplainedByOwnWrite(directory) {
            clearOwnWriteMarkers(under: directory)
        }

        queuedIncrementalDirectories.formUnion(directories)
        guard incrementalTask == nil else { return } // will run when the current pass finishes
        runQueuedIncrementalScan()
    }

    private func runQueuedIncrementalScan() {
        let directories = Array(queuedIncrementalDirectories).sorted()
        queuedIncrementalDirectories.removeAll()
        guard !directories.isEmpty else {
            incrementalTask = nil
            return
        }

        let start = CFAbsoluteTimeGetCurrent()
        AppLogger.scanning.notice("Incremental scan started for \(directories.count) path(s)")
        let filter = ScanPathFilter(directories: directories)
        let customPaths = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
        let includePlugins = SkillKitSettings.includePluginSkills
        Self.postOnMain(.scanDidStart, userInfo: ["incremental": true, "directories": directories])

        incrementalTask = Task.detached { [weak self] in
            let results = Self.collectAllSkills(customPaths: customPaths, includePlugins: includePlugins, filter: filter)
                .filter { filter.covers($0.fileURL.path) }
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                PathExistenceCache.invalidate()
                SkillScanSourceCache.invalidate()
                let touched = self.applyIncrementalResults(results, filter: filter)
                self.removeDeletedSkills(under: directories)
                let total = CFAbsoluteTimeGetCurrent() - start
                AppLogger.scanning.notice("Incremental scan complete: \(results.count) found, \(touched) row(s) updated in \(String(format: "%.2f", total))s")
                NotificationCenter.default.post(
                    name: .scanDidFinish,
                    object: self,
                    userInfo: ["count": results.count, "incremental": true, "directories": directories]
                )
                self.incrementalTask = nil
                if !self.queuedIncrementalDirectories.isEmpty {
                    self.runQueuedIncrementalScan()
                }
            }
        }
    }

    /// Consumes the own-write markers covering `changedPath`, so a *second*
    /// change to the same file is never attributed to us.
    private func clearOwnWriteMarkers(under changedPath: String) {
        let standardized = (changedPath as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        recentOwnWrites = recentOwnWrites.filter { written, _ in
            !(written == standardized || written == resolved
                || (written as NSString).deletingLastPathComponent == standardized
                || (written as NSString).deletingLastPathComponent == resolved)
        }
    }

    private func pruneExpiredOwnWrites() {
        let cutoff = Date.now.addingTimeInterval(-ownWriteGracePeriod)
        recentOwnWrites = recentOwnWrites.filter { $0.value > cutoff }
    }

    /// A changed path is "ours" when we recently wrote that exact file, or a
    /// file directly inside it (an atomic save touches the parent directory).
    private func isExplainedByOwnWrite(_ changedPath: String) -> Bool {
        let standardized = (changedPath as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        return recentOwnWrites.keys.contains { written in
            written == standardized || written == resolved
                || (written as NSString).deletingLastPathComponent == standardized
                || (written as NSString).deletingLastPathComponent == resolved
        }
    }

    private static func postOnMain(_ name: Notification.Name, userInfo: [String: Any]) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
            }
        }
    }

    /// Pure filesystem I/O — safe to run off main thread. `filter` narrows the
    /// walk to roots that intersect the changed directories.
    private static func collectAllSkills(customPaths: [String], includePlugins: Bool, filter: ScanPathFilter = .all) -> [ScannedSkillData] {
        var results: [ScannedSkillData] = []
        let sotDir = SkillKitSettings.sotDir

        AppLogger.scanning.notice("Starting collectAllSkills. sotDir: \(sotDir), customPaths count: \(customPaths.count)")

        SandboxBookmarkManager.resolveAndAccess(path: sotDir) { url in
            AppLogger.scanning.notice("Successfully accessed sotDir: \(url.path)")
            for tool in ToolSource.allCases where tool != .custom {
                guard !Task.isCancelled else { return }
                guard tool.isInstalled else {
                    continue
                }
                for path in tool.globalPaths where filter.admits(path) {
                    let url = URL(fileURLWithPath: path)
                    collectFromDirectory(url, toolSource: tool, isGlobal: true, kind: .skill, filter: filter, into: &results)
                }
                for path in tool.globalAgentPaths where filter.admits(path) {
                    let url = URL(fileURLWithPath: path)
                    collectFromDirectory(url, toolSource: tool, isGlobal: true, kind: .skill, filter: filter, into: &results)
                }
                for path in tool.globalRulePaths where filter.admits(path) {
                    let url = URL(fileURLWithPath: path)
                    collectFromDirectory(url, toolSource: tool, isGlobal: true, kind: .rule, filter: filter, into: &results)
                }
            }

            if includePlugins {
                let home = AppPaths.userHomeDirectory
                // CLI plugins (installed_plugins.json)
                if ToolSource.claude.isInstalled, filter.admits("\(home)/.claude/plugins") {
                    collectFromCLIPlugins(filter: filter, into: &results)
                }
                // Claude Desktop/Cowork plugin skills
                if ToolSource.claudeDesktop.isInstalled,
                   filter.admits("\(home)/Library/Application Support/Claude/local-agent-mode-sessions") {
                    collectClaudeDesktopSkills(filter: filter, into: &results)
                }
            }
        }

        for path in customPaths where filter.admits(path) {
            guard !Task.isCancelled else { return results }
            SandboxBookmarkManager.resolveAndAccess(path: path) { url in
                if let toolSource = toolSource(forAuthorizedPlatformPath: path) {
                    collectFromDirectory(url, toolSource: toolSource, isGlobal: true, filter: filter, into: &results)
                } else {
                    collectFromCustomDirectory(url, filter: filter, into: &results)
                }
            }
        }

        return results
    }

    /// Onboarding folders are first-class platform libraries, not generic custom
    /// directories. Preserve their platform identity so filtering and creation flows
    /// continue to behave as users expect.
    private static func toolSource(forAuthorizedPlatformPath path: String) -> ToolSource? {
        guard let platform = PlatformOption.onboarding.first(where: { option in
            path == option.expandedSkillsPath || path == option.expandedXcodePath
        }) else {
            return nil
        }

        return platform.toolSource
    }

    private static func collectFromCustomDirectory(_ directory: URL, filter: ScanPathFilter = .all, into results: inout [ScannedSkillData]) {
        let fm = FileManager.default

        collectDirectSkillsFromCustomDirectory(directory, filter: filter, into: &results)

        guard let projects = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for project in projects {
            guard !Task.isCancelled else { return }
            guard filter.admits(project.path) else { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: project.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }

            for probe in projectProbes {
                let probePath = project.appendingPathComponent(probe.subpath)
                guard filter.admits(probePath.path) else { continue }
                guard fm.fileExists(atPath: probePath.path) else { continue }

                if probe.tool == .copilot && probe.kind == .skill {
                    let file = probePath.appendingPathComponent("copilot-instructions.md")
                    if fm.fileExists(atPath: file.path) {
                        if let data = collectSkillData(at: file, toolSource: .copilot, isDirectory: false, isGlobal: false, kind: probe.kind) {
                            results.append(data)
                        }
                    }
                } else {
                    collectFromDirectory(probePath, toolSource: probe.tool, isGlobal: false, kind: probe.kind, filter: filter, into: &results)
                }
            }
        }
    }

    /// Custom scan paths serve two different jobs:
    /// - parent dirs like ~/Development that contain projects with tool-specific folders
    /// - library dirs that contain skills directly as child folders/files
    ///
    /// Only scan direct skill-style entries here so repo-level AGENTS.md files do not become
    /// bogus custom skills when the user adds a generic project parent directory.
    private static func collectDirectSkillsFromCustomDirectory(_ directory: URL, filter: ScanPathFilter = .all, into results: inout [ScannedSkillData]) {
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in contents {
            guard !Task.isCancelled else { return }
            guard filter.admits(item.path) else { continue }

            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                let skillFile = item.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: skillFile.path) else { continue }
                if let data = collectSkillData(
                    at: skillFile,
                    toolSource: .custom,
                    isDirectory: true,
                    isGlobal: false,
                    kind: .skill
                ) {
                    results.append(data)
                }
            } else {
                guard ["md", "mdc", "toml"].contains(item.pathExtension) else { continue }
                guard !shouldIgnoreLooseMarkdownFile(named: item.lastPathComponent) else { continue }
                if let data = collectSkillData(
                    at: item,
                    toolSource: .custom,
                    isDirectory: false,
                    isGlobal: false,
                    kind: .skill
                ) {
                    results.append(data)
                }
            }
        }
    }

    private static func collectFromDirectory(_ directory: URL, toolSource: ToolSource, isGlobal: Bool, kind: ItemKind = .skill, filter: ScanPathFilter = .all, into results: inout [ScannedSkillData]) {
        let fm = FileManager.default

        guard filter.admits(directory.path) else { return }
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: directory.path, isDirectory: &isDir)
        AppLogger.scanning.notice("Probing directory: \(directory.path), exists: \(exists), isDir: \(isDir.boolValue)")
        guard exists, isDir.boolValue else { return }

        // Enumerate through the resolved directory so symlinked directories are traversed.
        let resolvedDirectory = directory.resolvingSymlinksInPath()

        guard let contents = try? fm.contentsOfDirectory(
            at: resolvedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Track both bases so each entry can be remapped back to the canonical path for storage.
        let originalBase = directory.path
        let resolvedBase = resolvedDirectory.path

        for rawItem in contents {
            guard !Task.isCancelled else { return }
            // Remap to canonical path for storage; use rawItem for filesystem operations.
            let item: URL
            if originalBase != resolvedBase, rawItem.path.hasPrefix(resolvedBase + "/") {
                let suffix = String(rawItem.path.dropFirst(resolvedBase.count))
                item = URL(fileURLWithPath: originalBase + suffix)
            } else {
                item = rawItem
            }
            guard filter.admits(item.path) || filter.admits(rawItem.path) else { continue }
            var itemIsDir: ObjCBool = false
            fm.fileExists(atPath: rawItem.path, isDirectory: &itemIsDir)

            if itemIsDir.boolValue {
                let skillFile = item.appendingPathComponent("SKILL.md")
                let agentsFile = item.appendingPathComponent("AGENTS.md")
                let rawSkillFile = rawItem.appendingPathComponent("SKILL.md")
                let rawAgentsFile = rawItem.appendingPathComponent("AGENTS.md")

                if fm.fileExists(atPath: rawSkillFile.path) {
                    if let data = collectSkillData(at: skillFile, toolSource: toolSource, isDirectory: true, isGlobal: isGlobal, kind: kind) {
                        results.append(data)
                    }
                } else if fm.fileExists(atPath: rawAgentsFile.path) {
                    if let data = collectSkillData(at: agentsFile, toolSource: toolSource, isDirectory: true, isGlobal: isGlobal, kind: kind) {
                        results.append(data)
                    }
                } else if let fallbackFile = preferredAgentFile(in: rawItem) {
                    let remappedAgentFile = item.appendingPathComponent(fallbackFile.lastPathComponent)
                    if let data = collectSkillData(at: remappedAgentFile, toolSource: toolSource, isDirectory: true, isGlobal: isGlobal, kind: kind) {
                        results.append(data)
                    }
                } else if toolSource == .hermes, kind == .skill {
                    // Hermes nests skills as ~/.hermes/skills/<category>/<skill>/SKILL.md (agentskills.io layout).
                    collectFromDirectory(item, toolSource: toolSource, isGlobal: isGlobal, kind: kind, filter: filter, into: &results)
                }
            } else if item.pathExtension == "md" || item.pathExtension == "mdc" || item.pathExtension == "toml" {
                guard !shouldIgnoreLooseMarkdownFile(named: item.lastPathComponent) else { continue }
                if let data = collectSkillData(at: item, toolSource: toolSource, isDirectory: false, isGlobal: isGlobal, kind: kind) {
                    results.append(data)
                }
            }
        }
    }

    private static func preferredAgentFile(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = contents.filter { item in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &isDir)
            guard !isDir.boolValue else { return false }
            guard ["md", "mdc", "toml"].contains(item.pathExtension) else { return false }
            return !shouldIgnoreLooseMarkdownFile(named: item.lastPathComponent)
        }

        let directoryName = directory.lastPathComponent.lowercased()
        if let matchingFile = candidates.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == directoryName }) {
            return matchingFile
        }

        if candidates.count == 1 {
            return candidates[0]
        }

        return nil
    }

    /// For Claude Desktop plugin paths, produce a canonical identity that strips volatile
    /// components (session IDs, version numbers). For all other tools, returns the normal
    /// symlink-resolved path. Same pattern as remote skills using `remote://` prefixes.
    private static func canonicalResolvedPath(for fileURL: URL, toolSource: ToolSource) -> String {
        let resolved = fileURL.resolvingSymlinksInPath().path
        let path = fileURL.path

        // CLI plugins: .../.claude/plugins/cache/<publisher>/<plugin>/<version>/skills/<skill>/SKILL.md
        if toolSource == .claude, let range = path.range(of: ".claude/plugins/cache/") {
            let after = String(path[range.upperBound...])
            let parts = after.components(separatedBy: "/")
            // parts: [publisher, plugin, version, "skills", skill, "SKILL.md"]
            guard parts.count >= 6, parts[3] == "skills" else { return resolved }
            return "claude-plugin:\(parts[0])/\(parts[1])/\(parts[4])"
        }

        guard toolSource == .claudeDesktop else { return resolved }

        // Local plugins: .../cowork_plugins/cache/<marketplace>/<plugin>/<version>/skills/<skill>/SKILL.md
        if let range = path.range(of: "cowork_plugins/cache/") {
            let after = String(path[range.upperBound...])
            let parts = after.components(separatedBy: "/")
            // parts: [marketplace, plugin, version, "skills", skill, "SKILL.md"]
            guard parts.count >= 6, parts[3] == "skills" else { return resolved }
            return "claude-desktop:cowork_plugins/\(parts[0])/\(parts[1])/\(parts[4])"
        }

        // Remote plugins: .../remote_cowork_plugins/<plugin-id>/skills/<skill>/SKILL.md
        if let range = path.range(of: "remote_cowork_plugins/") {
            let after = String(path[range.upperBound...])
            let parts = after.components(separatedBy: "/")
            // parts: [plugin-id, "skills", skill, "SKILL.md"]
            guard parts.count >= 4, parts[1] == "skills" else { return resolved }
            return "claude-desktop:remote_cowork_plugins/\(parts[0])/\(parts[2])"
        }

        return resolved
    }

    private static func isSyntheticLocalResolvedPath(_ resolvedPath: String) -> Bool {
        resolvedPath.hasPrefix("claude-plugin:") || resolvedPath.hasPrefix("claude-desktop:")
    }

    /// Read and parse a single skill file. Pure I/O, no SwiftData.
    private static func collectSkillData(at fileURL: URL, toolSource: ToolSource, isDirectory: Bool, isGlobal: Bool, kind: ItemKind = .skill) -> ScannedSkillData? {
        let fm = FileManager.default
        let resolved = canonicalResolvedPath(for: fileURL, toolSource: toolSource)

        // Resolve symlinks for the actual read — fileURL may be a remapped canonical path
        // that does not physically exist when a parent directory is a symlink.
        let physicalURL = fileURL.resolvingSymlinksInPath()
        guard let parsed = SkillParser.parse(fileURL: physicalURL, toolSource: toolSource) else {
            AppLogger.scanning.warning("Failed to parse: \(fileURL.path)")
            return nil
        }

        let attrs = try? fm.attributesOfItem(atPath: physicalURL.path)
        let modDate  = (attrs?[.modificationDate] as? Date) ?? .now
        let fileSize = (attrs?[.size] as? Int) ?? 0

        let name: String
        if !parsed.name.isEmpty {
            name = parsed.name
        } else if isDirectory {
            name = fileURL.deletingLastPathComponent().lastPathComponent
        } else {
            name = fileURL.deletingPathExtension().lastPathComponent
        }

        return ScannedSkillData(
            fileURL: fileURL,
            resolvedPath: resolved,
            toolSource: toolSource,
            isDirectory: isDirectory,
            isGlobal: isGlobal,
            name: name,
            skillDescription: parsed.description,
            content: parsed.content,
            frontmatter: parsed.frontmatter,
            modDate: modDate,
            fileSize: fileSize,
            kind: kind
        )
    }

    // MARK: - Claude Plugin Scanning

    /// Scan CLI plugins from ~/.claude/plugins/installed_plugins.json
    private static func collectFromCLIPlugins(filter: ScanPathFilter = .all, into results: inout [ScannedSkillData]) {
        let fm = FileManager.default
        let home = AppPaths.userHomeDirectory
        let jsonPath = "\(home)/.claude/plugins/installed_plugins.json"

        guard let data = fm.contents(atPath: jsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: [[String: Any]]] else { return }

        for (_, installations) in plugins {
            guard !Task.isCancelled else { return }
            for installation in installations {
                guard let installPath = installation["installPath"] as? String else { continue }
                let skillsDir = URL(fileURLWithPath: installPath).appendingPathComponent("skills")
                collectFromDirectory(skillsDir, toolSource: .claude, isGlobal: true, filter: filter, into: &results)
            }
        }
    }

    /// Scan Claude Desktop/Cowork plugin skills using manifests as source of truth.
    /// Only scans explicitly installed plugins — skips built-in Anthropic skills (skills-plugin/).
    private static func collectClaudeDesktopSkills(filter: ScanPathFilter = .all, into results: inout [ScannedSkillData]) {
        let fm = FileManager.default
        let home = AppPaths.userHomeDirectory
        let sessionsRoot = "\(home)/Library/Application Support/Claude/local-agent-mode-sessions"

        guard fm.fileExists(atPath: sessionsRoot) else { return }
        guard let sessionDirs = try? fm.contentsOfDirectory(atPath: sessionsRoot) else { return }

        for sessionDir in sessionDirs {
            guard !Task.isCancelled else { return }
            // Skip skills-plugin (Anthropic built-in skills, not user-installed)
            if sessionDir == "skills-plugin" { continue }

            let sessionPath = "\(sessionsRoot)/\(sessionDir)"
            guard let subDirs = try? fm.contentsOfDirectory(atPath: sessionPath) else { continue }

            for subDir in subDirs {
                guard !Task.isCancelled else { return }
                let subPath = "\(sessionPath)/\(subDir)"

                // Local cowork plugins: use installed_plugins.json as source of truth
                let installedJson = "\(subPath)/cowork_plugins/installed_plugins.json"
                if let data = fm.contents(atPath: installedJson),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let plugins = json["plugins"] as? [String: [[String: Any]]] {
                    for (_, installations) in plugins {
                        guard !Task.isCancelled else { return }
                        for installation in installations {
                            guard let installPath = installation["installPath"] as? String else { continue }
                            let skillsDir = URL(fileURLWithPath: installPath).appendingPathComponent("skills")
                            collectFromDirectory(skillsDir, toolSource: .claudeDesktop, isGlobal: true, filter: filter, into: &results)
                        }
                    }
                }

                // Remote cowork plugins: use manifest.json as source of truth
                let remoteDir = "\(subPath)/remote_cowork_plugins"
                let manifestPath = "\(remoteDir)/manifest.json"
                if let data = fm.contents(atPath: manifestPath),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let plugins = json["plugins"] as? [[String: Any]] {
                    for plugin in plugins {
                        guard !Task.isCancelled else { return }
                        guard let pluginId = plugin["id"] as? String else { continue }
                        let skillsDir = "\(remoteDir)/\(pluginId)/skills"
                        guard fm.fileExists(atPath: skillsDir) else { continue }
                        collectFromDirectory(
                            URL(fileURLWithPath: skillsDir),
                            toolSource: .claudeDesktop,
                            isGlobal: true,
                            filter: filter,
                            into: &results
                        )
                    }
                }
            }
        }
    }

    /// Apply collected results to SwiftData. Must be called on main thread.
    @MainActor
    private func applyResults(_ results: [ScannedSkillData]) {
        AppLogger.scanning.notice("applyResults called with \(results.count) results")
        let groupedResults = Dictionary(grouping: results, by: \.resolvedPath)
        let descriptor = FetchDescriptor<Skill>()
        let allSkills = (try? modelContext.fetch(descriptor)) ?? []
        let localSkills = allSkills.filter { !$0.isRemote }
        let existingByResolved = Dictionary(uniqueKeysWithValues: localSkills.map { ($0.resolvedPath, $0) })
        let scannedResolvedPaths = Set(groupedResults.keys)

        for (resolvedPath, installations) in groupedResults {
            guard let primary = installations.first else { continue }

            let installedPaths = Array(Set(installations.map(\.fileURL.path))).sorted()
            let toolSources = ToolSource.allCases.filter { tool in
                installations.contains { $0.toolSource == tool }
            }

            if let existing = existingByResolved[resolvedPath] {
                let preferredPath = installedPaths.contains(existing.filePath) ? existing.filePath : primary.fileURL.path
                let preferredData = installations.first(where: { $0.fileURL.path == preferredPath }) ?? primary

                existing.filePath = preferredPath
                existing.isDirectory = preferredData.isDirectory
                existing.name = preferredData.name
                existing.skillDescription = preferredData.skillDescription
                existing.content = preferredData.content
                existing.frontmatter = preferredData.frontmatter
                existing.fileModifiedDate = preferredData.modDate
                existing.fileSize = preferredData.fileSize
                existing.isGlobal = preferredData.isGlobal
                existing.installedPaths = installedPaths
                existing.toolSources = toolSources
                existing.itemKind = preferredData.kind
            } else {
                let skill = Skill(
                    filePath: primary.fileURL.path,
                    toolSource: primary.toolSource,
                    isDirectory: primary.isDirectory,
                    name: primary.name,
                    skillDescription: primary.skillDescription,
                    content: primary.content,
                    frontmatter: primary.frontmatter,
                    fileModifiedDate: primary.modDate,
                    fileSize: primary.fileSize,
                    isGlobal: primary.isGlobal,
                    resolvedPath: primary.resolvedPath,
                    kind: primary.kind
                )
                skill.installedPaths = installedPaths
                skill.toolSources = toolSources
                modelContext.insert(skill)
            }
        }

        for skill in localSkills where !scannedResolvedPaths.contains(skill.resolvedPath) {
            modelContext.delete(skill)
        }

        do { try modelContext.save() } catch {
            AppLogger.scanning.error("SwiftData save failed: \(error.localizedDescription)")
        }
    }

    /// Applies a partial collection (only skills under the changed
    /// directories). Existing rows are rewritten only when the on-disk
    /// mtime/size differ from what is stored; installations outside the
    /// changed directories are preserved since they were not rescanned.
    /// Returns the number of rows inserted or modified.
    @MainActor
    private func applyIncrementalResults(_ results: [ScannedSkillData], filter: ScanPathFilter) -> Int {
        guard !results.isEmpty else { return 0 }

        let groupedResults = Dictionary(grouping: results, by: \.resolvedPath)
        let descriptor = FetchDescriptor<Skill>()
        let allSkills = (try? modelContext.fetch(descriptor)) ?? []
        let existingByResolved = Dictionary(
            allSkills.filter { !$0.isRemote }.map { ($0.resolvedPath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var touched = 0

        for (resolvedPath, installations) in groupedResults {
            guard let primary = installations.first else { continue }

            let rescannedPaths = Set(installations.map(\.fileURL.path))
            let newTools = ToolSource.allCases.filter { tool in
                installations.contains { $0.toolSource == tool }
            }

            guard let existing = existingByResolved[resolvedPath] else {
                let skill = Skill(
                    filePath: primary.fileURL.path,
                    toolSource: primary.toolSource,
                    isDirectory: primary.isDirectory,
                    name: primary.name,
                    skillDescription: primary.skillDescription,
                    content: primary.content,
                    frontmatter: primary.frontmatter,
                    fileModifiedDate: primary.modDate,
                    fileSize: primary.fileSize,
                    isGlobal: primary.isGlobal,
                    resolvedPath: primary.resolvedPath,
                    kind: primary.kind
                )
                skill.installedPaths = rescannedPaths.sorted()
                skill.toolSources = newTools
                modelContext.insert(skill)
                touched += 1
                continue
            }

            // Installations outside the changed set weren't rescanned — keep them.
            let keptPaths = existing.installedPaths.filter { !filter.covers($0) }
            let mergedPaths = Set(keptPaths).union(rescannedPaths).sorted()
            let preferredPath = mergedPaths.contains(existing.filePath) ? existing.filePath : primary.fileURL.path
            let preferredData = installations.first { $0.fileURL.path == preferredPath }

            var changed = false

            if let data = preferredData, Self.differsOnDisk(existing, from: data) {
                existing.isDirectory = data.isDirectory
                existing.name = data.name
                existing.skillDescription = data.skillDescription
                existing.content = data.content
                existing.frontmatter = data.frontmatter
                existing.fileModifiedDate = data.modDate
                existing.fileSize = data.fileSize
                existing.isGlobal = data.isGlobal
                existing.itemKind = data.kind
                changed = true
            }

            if existing.filePath != preferredPath {
                existing.filePath = preferredPath
                changed = true
            }
            // Capture what dropped away BEFORE overwriting, otherwise the
            // filter below always sees the new list and never prunes a tool.
            let removedPaths = existing.installedPaths.filter { !mergedPaths.contains($0) }
            if existing.installedPaths != mergedPaths {
                existing.installedPaths = mergedPaths
                changed = true
            }

            let keptTools = Self.toolSources(existing.toolSources, removedPaths: removedPaths, remainingPaths: mergedPaths)
            let mergedTools = ToolSource.allCases.filter { keptTools.contains($0) || newTools.contains($0) }
            if Set(existing.toolSources) != Set(mergedTools) {
                existing.toolSources = mergedTools
                changed = true
            }

            if changed { touched += 1 }
        }

        if touched > 0 {
            do { try modelContext.save() } catch {
                AppLogger.scanning.error("SwiftData save failed: \(error.localizedDescription)")
            }
        }
        return touched
    }

    /// Keeps a tool only while at least one of `paths` still lives under one
    /// of its known directories. Tools we can't map to a directory (custom
    /// paths, plugins) are always kept.
    private static func toolSources(_ tools: [ToolSource], removedPaths: [String], remainingPaths: [String]) -> [ToolSource] {
        guard !removedPaths.isEmpty else { return tools }
        return tools.filter { tool in
            let toolDirs = tool.globalPaths + tool.globalAgentPaths + tool.globalRulePaths
            guard !toolDirs.isEmpty else { return true }
            let lostOne = removedPaths.contains { path in toolDirs.contains { path.hasPrefix($0 + "/") } }
            guard lostOne else { return true } // project-level / custom paths aren't mapped
            return remainingPaths.contains { path in toolDirs.contains { path.hasPrefix($0 + "/") } }
        }
    }

    private static func differsOnDisk(_ skill: Skill, from data: ScannedSkillData) -> Bool {
        if skill.fileSize != data.fileSize { return true }
        if abs(skill.fileModifiedDate.timeIntervalSince(data.modDate)) > 0.001 { return true }
        // Same stamp but a different kind/dir flag (e.g. file → folder move).
        return skill.isDirectory != data.isDirectory || skill.itemKind != data.kind
    }

    // MARK: - Remote Server Scanning

    @MainActor
    func syncAllRemoteServers() async {
        let descriptor = FetchDescriptor<RemoteServer>()
        guard let servers = try? modelContext.fetch(descriptor) else { return }
        for server in servers {
            await scanRemoteServer(server)
        }
    }

    /// Scans a remote server for skills. Sets lastSyncError on failure.
    @MainActor
    func scanRemoteServer(_ server: RemoteServer) async {
        do {
            let remoteSkills = try await SSHService.findSkills(server)
            var foundPaths = Set<String>()

            for (path, content) in remoteSkills {
                let resolvedPath = "remote://\(server.id)/\(path)"
                foundPaths.insert(resolvedPath)

                // Rows written before the delimiter-parsing fix stored the path
                // with a stray "IM:" prefix. Migrate them in place so favorites,
                // collections and suppressions survive the upgrade instead of
                // being deleted and re-created below.
                let legacyResolvedPath = "remote://\(server.id)/IM:\(path)"
                if legacyResolvedPath != resolvedPath {
                    let legacyDescriptor = FetchDescriptor<Skill>(
                        predicate: #Predicate<Skill> { $0.resolvedPath == legacyResolvedPath }
                    )
                    if let legacy = try? modelContext.fetch(legacyDescriptor).first {
                        legacy.resolvedPath = resolvedPath
                        legacy.filePath = resolvedPath
                        legacy.remotePath = path
                        AppLogger.scanning.notice("Migrated legacy remote skill path for \(path)")
                    }
                }

                let parsed = FrontmatterParser.parse(content)
                let name: String
                if !parsed.name.isEmpty {
                    name = parsed.name
                } else {
                    // Derive name from parent directory
                    let components = path.components(separatedBy: "/")
                    if let fileIndex = components.lastIndex(of: "SKILL.md"), fileIndex > 0 {
                        name = components[fileIndex - 1]
                    } else {
                        name = "Unknown"
                    }
                }

                let predicate = #Predicate<Skill> { $0.resolvedPath == resolvedPath }
                let fetchDescriptor = FetchDescriptor<Skill>(predicate: predicate)

                if let existing = try? modelContext.fetch(fetchDescriptor).first {
                    existing.remotePath = path
                    existing.content = parsed.content
                    existing.name = name
                    existing.skillDescription = parsed.description
                    existing.frontmatter = parsed.frontmatter
                } else {
                    let skill = Skill(
                        filePath: resolvedPath,
                        toolSource: server.inferredRemoteToolSource,
                        isDirectory: true,
                        name: name,
                        skillDescription: parsed.description,
                        content: parsed.content,
                        frontmatter: parsed.frontmatter,
                        isGlobal: true,
                        resolvedPath: resolvedPath
                    )
                    skill.remoteServer = server
                    skill.remotePath = path
                    modelContext.insert(skill)
                }
            }

            // Remove skills that no longer exist on the server
            let serverID = server.id
            let remotePredicate = #Predicate<Skill> { $0.resolvedPath.starts(with: "remote://") }
            if let existingRemoteSkills = try? modelContext.fetch(FetchDescriptor<Skill>(predicate: remotePredicate)) {
                for skill in existingRemoteSkills {
                    guard skill.remoteServer?.id == serverID else { continue }
                    if !foundPaths.contains(skill.resolvedPath) {
                        modelContext.delete(skill)
                    }
                }
            }

            server.lastSyncDate = .now
            server.lastSyncError = nil
            do { try modelContext.save() } catch {
                AppLogger.scanning.error("SwiftData save failed after sync: \(error.localizedDescription)")
            }
        } catch {
            server.lastSyncError = error.localizedDescription
            do { try modelContext.save() } catch {
                AppLogger.scanning.error("SwiftData save failed after sync error: \(error.localizedDescription)")
            }
        }
    }

    /// Drops rows whose files no longer exist.
    ///
    /// - Parameter directories: when given (incremental mode), only skills with
    ///   an installation under one of these paths are stat'ed; everything else
    ///   is left alone. `nil` checks the whole library.
    @MainActor
    func removeDeletedSkills(under directories: [String]? = nil) {
        let descriptor = FetchDescriptor<Skill>()
        guard let skills = try? modelContext.fetch(descriptor) else { return }
        let fm = FileManager.default
        let filter = ScanPathFilter(directories: directories)
        let incremental = directories != nil
        var changed = false

        for skill in skills {
            // Remove orphaned remote skills (server was deleted)
            if !incremental, skill.resolvedPath.hasPrefix("remote://") && skill.remoteServer == nil {
                modelContext.delete(skill)
                changed = true
                continue
            }

            // Remote skills are managed by scanRemoteServer(), skip here
            if skill.isRemote { continue }

            // Plugin skills use canonical IDs, not filesystem paths. Let applyResults()
            // handle their lifecycle so updates don't delete and recreate user metadata.
            if Self.isSyntheticLocalResolvedPath(skill.resolvedPath) { continue }

            if incremental {
                let paths = [skill.filePath] + skill.installedPaths
                guard paths.contains(where: filter.covers) else { continue }
            }

            // Remove previously-scanned loose markdown files that are now filtered out.
            let fileName = URL(fileURLWithPath: skill.filePath).lastPathComponent
            if !skill.isDirectory, Self.shouldIgnoreLooseMarkdownFile(named: fileName) {
                modelContext.delete(skill)
                changed = true
                continue
            }

            let validPaths = skill.installedPaths.filter { fm.fileExists(atPath: $0) }
            if validPaths.isEmpty {
                modelContext.delete(skill)
                changed = true
            } else {
                if validPaths != skill.installedPaths {
                    let removedPaths = skill.installedPaths.filter { !validPaths.contains($0) }
                    skill.installedPaths = validPaths
                    let prunedTools = Self.toolSources(skill.toolSources, removedPaths: removedPaths, remainingPaths: validPaths)
                    if Set(prunedTools) != Set(skill.toolSources) {
                        skill.toolSources = prunedTools
                    }
                    changed = true
                }
                if !fm.fileExists(atPath: skill.filePath), let first = validPaths.first {
                    skill.filePath = first
                    changed = true
                }
            }
        }
        guard changed || !incremental else { return }
        do { try modelContext.save() } catch {
            AppLogger.scanning.error("SwiftData save failed: \(error.localizedDescription)")
        }
    }

    deinit {
        scanTask?.cancel()
        incrementalTask?.cancel()
    }
}
