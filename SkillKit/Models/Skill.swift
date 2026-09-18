import SwiftData
import Foundation

enum ItemKind: String, Codable, CaseIterable {
    case skill
    case rule

    var displayName: String {
        switch self {
        case .skill: "Skills"
        case .rule: "Rules"
        }
    }

    var singularName: String {
        switch self {
        case .skill: "Skill"
        case .rule: "Rule"
        }
    }

    var icon: String {
        switch self {
        case .skill: "doc.text"
        case .rule: "list.bullet.rectangle"
        }
    }
}

extension Skill {
    var isRemote: Bool { remoteServer != nil }

    var isPlugin: Bool {
        filePath.contains("/.claude/plugins/") ||
        filePath.contains("/local-agent-mode-sessions/") ||
        toolSources.contains(.claudeDesktop)
    }

    var isReadOnly: Bool {
        isPlugin || isBundledOpenClawSkill
    }

    // MARK: - Computed

    var itemKind: ItemKind {
        get { ItemKind(rawValue: kind) ?? .skill }
        set { kind = newValue.rawValue }
    }

    var displayTypeName: String {
        switch itemKind {
        case .rule: "Rule"
        case .skill: "Skill"
        }
    }

    var toolSources: [ToolSource] {
        get {
            toolSourcesRaw
                .split(separator: ",")
                .compactMap { ToolSource(rawValue: String($0)) }
        }
        set {
            let unique = Array(Set(newValue.map(\.rawValue))).sorted()
            toolSourcesRaw = unique.joined(separator: ",")
        }
    }

    /// Primary tool source (first one added)
    var toolSource: ToolSource {
        toolSources.first ?? .custom
    }

    var customPlatform: PlatformOption? {
        let path = filePath.lowercased()
        return PlatformOption.customPlatforms.first { platform in
            let platformSkills = platform.expandedSkillsPath.lowercased()
            let platformXcode = platform.expandedXcodePath?.lowercased()
            return path.hasPrefix(platformSkills) || (platformXcode != nil && path.hasPrefix(platformXcode!))
        }
    }

    var toolSourceDisplayName: String {
        if toolSource == .custom, let custom = customPlatform {
            return custom.displayName
        }
        return toolSource.displayName
    }

    var installedPaths: [String] {
        get {
            guard let data = installedPathsData else { return [filePath] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? [filePath]
        }
        set {
            do {
                installedPathsData = try JSONEncoder().encode(Array(Set(newValue)))
            } catch {
                AppLogger.fileIO.fault("Failed to encode installedPaths: \(error.localizedDescription)")
            }
        }
    }

    var frontmatter: [String: String] {
        get {
            guard let data = frontmatterData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            do {
                frontmatterData = try JSONEncoder().encode(newValue)
            } catch {
                AppLogger.fileIO.fault("Failed to encode frontmatter: \(error.localizedDescription)")
            }
        }
    }

    /// How many tools this skill is installed for
    var installCount: Int { toolSources.count }

    private var isBundledOpenClawSkill: Bool {
        filePath.hasPrefix("/opt/homebrew/lib/node_modules/openclaw/skills/")
            || filePath.hasPrefix("/usr/local/lib/node_modules/openclaw/skills/")
    }

    /// For project-level skills, extracts the project name from the path.
    /// e.g. ~/Development/every-expert/.claude/skills/foo/SKILL.md → "every-expert"
    var projectName: String? {
        guard !isGlobal else { return nil }
        let components = filePath.components(separatedBy: "/")
        // Find the component before a dotfile directory (.claude, .cursor, .codex, etc.)
        for (i, component) in components.enumerated() {
            if component.hasPrefix(".") && i > 0 {
                return components[i - 1]
            }
        }
        return nil
    }

    // MARK: - Merge

    /// Merge another location/tool into this skill
    func addInstallation(path: String, tool: ToolSource) {
        var paths = installedPaths
        if !paths.contains(path) {
            paths.append(path)
            installedPaths = paths
        }
        var tools = toolSources
        if !tools.contains(tool) {
            tools.append(tool)
            toolSources = tools
        }
    }

    private var linkedAgentSkillDirectories: [String] {
        guard isDirectory else { return [] }

        let fm = FileManager.default
        let skillDirectoryName = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .lastPathComponent

        guard !skillDirectoryName.isEmpty else { return [] }

        let canonicalDirectories = Set(
            ([filePath] + installedPaths).map {
                URL(fileURLWithPath: $0)
                    .deletingLastPathComponent()
                    .resolvingSymlinksInPath()
                    .path
            }
        )

        return AgentTarget.all.compactMap { agent in
            let candidate = "\(agent.expandedSkillsDir)/\(skillDirectoryName)"
            guard fm.fileExists(atPath: candidate) else { return nil }
            let resolvedCandidate = URL(fileURLWithPath: candidate)
                .resolvingSymlinksInPath()
                .path
            return canonicalDirectories.contains(resolvedCandidate) ? candidate : nil
        }
    }

    var deletionTargets: [String] {
        var targets = Set(
            ([filePath] + installedPaths).map { path in
                if isDirectory {
                    return (path as NSString).deletingLastPathComponent
                }
                return path
            }
        )

        targets.formUnion(linkedAgentSkillDirectories)
        return Array(targets).sorted()
    }

    var canMakeGlobal: Bool {
        itemKind == .skill
            && isDirectory
            && !isRemote
            && !isReadOnly
            && !toolSources.contains(.agents)
    }

    func makeGlobal() throws {
        let fm = FileManager.default

        let currentSkillDir = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
        let skillDirName = currentSkillDir.lastPathComponent

        let sotDir = SkillKitSettings.sotDir
        let agentsSkillsDir = sotDir.hasSuffix(".agents")
            ? "\(sotDir)/skills"
            : "\(sotDir)/agents/skills"
        let canonicalDir = "\(agentsSkillsDir)/\(skillDirName)"
        let canonicalFile = "\(canonicalDir)/SKILL.md"

        guard !fm.fileExists(atPath: canonicalDir) else {
            throw MakeGlobalError.alreadyExists(skillDirName)
        }

        try fm.createDirectory(atPath: agentsSkillsDir, withIntermediateDirectories: true)

        // Move original directory to canonical location
        let originalDir = currentSkillDir.path
        try fm.moveItem(atPath: originalDir, toPath: canonicalDir)

        // Replace original with symlink to canonical
        try fm.createSymbolicLink(atPath: originalDir, withDestinationPath: canonicalDir)

        // Create symlinks from all installed agents
        var newInstalledPaths = [canonicalFile, "\(originalDir)/SKILL.md"]
        var newToolSources: [ToolSource] = [.agents]

        if let originalTool = toolSources.first, originalTool != .agents {
            newToolSources.append(originalTool)
        }

        for agent in AgentTarget.installed {
            let agentDir = "\(agent.expandedSkillsDir)/\(skillDirName)"
            if !fm.fileExists(atPath: agentDir) {
                try fm.createDirectory(atPath: agent.expandedSkillsDir, withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: agentDir, withDestinationPath: canonicalDir)
            }
            let agentFilePath = "\(agentDir)/SKILL.md"
            if !newInstalledPaths.contains(agentFilePath) {
                newInstalledPaths.append(agentFilePath)
            }
            if let toolSource = ToolSource.allCases.first(where: { $0.globalPaths.contains(agent.expandedSkillsDir) }) {
                if !newToolSources.contains(toolSource) {
                    newToolSources.append(toolSource)
                }
            }
        }

        resolvedPath = canonicalFile
        filePath = canonicalFile
        installedPaths = newInstalledPaths
        toolSources = newToolSources
        isGlobal = true
    }

    /// Moves the skill and every path it is installed at to the Trash.
    /// Returns where each item landed, so the caller can log or offer an undo
    /// hint; the result is safe to ignore.
    @discardableResult
    func deleteFromDisk() throws -> [URL] {
        let fm = FileManager.default
        var trashedURLs: [URL] = []

        // Symlinks first, then real items, so trashing the canonical directory
        // never turns a not-yet-processed link into a dangling one.
        let targets = deletionTargets.sorted { lhs, rhs in
            let lhsLink = Self.isSymbolicLink(atPath: lhs)
            let rhsLink = Self.isSymbolicLink(atPath: rhs)
            if lhsLink != rhsLink { return lhsLink }
            return lhs < rhs
        }

        for path in targets {
            try SandboxBookmarkManager.resolveAndAccessParent(for: path) { url in
                guard Self.itemExists(atPath: url.path) else { return }
                guard fm.isDeletableFile(atPath: url.path) else {
                    throw SkillDeletionError.notDeletable(path)
                }
            }
        }

        for path in targets {
            try SandboxBookmarkManager.resolveAndAccessParent(for: path) { url in
                guard Self.itemExists(atPath: url.path) else { return }
                do {
                    var resultingURL: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &resultingURL)
                    if let trashed = resultingURL as URL? {
                        trashedURLs.append(trashed)
                    }
                } catch {
                    if Self.isSymbolicLink(atPath: url.path) {
                        // A symlink into a folder we can't trash (a read-only
                        // mount, say) is still worth unlinking: it points at
                        // something we just removed.
                        try fm.removeItem(at: url)
                    } else {
                        throw SkillDeletionError.trashFailed(path, error)
                    }
                }
            }
        }

        if !trashedURLs.isEmpty {
            AppLogger.fileIO.notice("Moved \(trashedURLs.count) item(s) to the Trash for \(self.name)")
        }
        return trashedURLs
    }

    /// `fileExists(atPath:)` follows symlinks and reports a dangling link as
    /// missing; this checks the link entry itself.
    private static func itemExists(atPath path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    private static func isSymbolicLink(atPath path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}

enum MakeGlobalError: LocalizedError {
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            return "A global skill named \"\(name)\" already exists."
        }
    }
}

enum SkillDeletionError: LocalizedError {
    case notDeletable(String)
    case trashFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .notDeletable(let path):
            let displayPath = path.replacingOccurrences(of: AppPaths.userHomeDirectory, with: "~")
            return "Couldn't move \(displayPath) to the Trash. Check permissions and try again."
        case .trashFailed(let path, let underlying):
            let displayPath = path.replacingOccurrences(of: AppPaths.userHomeDirectory, with: "~")
            return "Couldn't move \(displayPath) to the Trash: \(underlying.localizedDescription)"
        }
    }
}

enum SkillRenamer {
    private struct Location {
        let source: URL
        let destination: URL
        let isSymbolicLink: Bool
        let linkDestination: String?
    }

    static func identifier(from name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    static func destinationPath(for skill: Skill, identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        let current = URL(fileURLWithPath: skill.filePath)
        if skill.isDirectory {
            return current.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(identifier, isDirectory: true)
                .appendingPathComponent(current.lastPathComponent)
                .path
        }
        let fileName = identifier + (current.pathExtension.isEmpty ? "" : ".\(current.pathExtension)")
        return current.deletingLastPathComponent().appendingPathComponent(fileName).path
    }

    static func rename(_ skill: Skill, to displayName: String) throws {
        guard !skill.isRemote, !skill.isReadOnly else { throw SkillRenameError.readOnly }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newIdentifier = identifier(from: trimmedName)
        guard !newIdentifier.isEmpty else { throw SkillRenameError.invalidName }

        let oldFilePaths = Array(Set([skill.filePath] + skill.installedPaths)).sorted()
        try withSecurityScopedAccess(to: oldFilePaths[...]) {
            try renameWithAccess(
                skill,
                displayName: trimmedName,
                identifier: newIdentifier,
                oldFilePaths: oldFilePaths
            )
        }
    }

    /// Keeps every source location accessible for the whole transaction. This
    /// matters in App Store builds, where a custom scan path may otherwise be
    /// readable by the scanner but unavailable when the user tries to rename it.
    private static func withSecurityScopedAccess<T>(
        to paths: ArraySlice<String>,
        action: () throws -> T
    ) rethrows -> T {
        guard let path = paths.first else { return try action() }
        return try SandboxBookmarkManager.resolveAndAccessParent(for: path) { _ in
            try withSecurityScopedAccess(to: paths.dropFirst(), action: action)
        }
    }

    private static func renameWithAccess(
        _ skill: Skill,
        displayName trimmedName: String,
        identifier newIdentifier: String,
        oldFilePaths: [String]
    ) throws {

        let fm = FileManager.default
        let locations = try makeLocations(
            filePaths: oldFilePaths,
            isDirectory: skill.isDirectory,
            identifier: newIdentifier,
            fileManager: fm
        )

        for location in locations where location.source.path != location.destination.path {
            guard !itemExists(at: location.destination, fileManager: fm) else {
                throw SkillRenameError.alreadyExists(location.destination.path)
            }
        }

        let realMoves = locations.filter { !$0.isSymbolicLink && $0.source.path != $0.destination.path }
        let linkMoves = locations.filter { $0.isSymbolicLink && $0.source.path != $0.destination.path }
        var movedRealLocations: [Location] = []
        var createdLinkLocations: [Location] = []

        do {
            for location in realMoves {
                try fm.moveItem(at: location.source, to: location.destination)
                movedRealLocations.append(location)
            }

            let realDestinationBySource = Dictionary(
                uniqueKeysWithValues: realMoves.map { ($0.source.standardizedFileURL.path, $0.destination.path) }
            )
            for location in linkMoves {
                try fm.removeItem(at: location.source)
                let oldTarget = absoluteLinkDestination(for: location)
                let target = realDestinationBySource[oldTarget.standardizedFileURL.path] ?? oldTarget.path
                try fm.createSymbolicLink(atPath: location.destination.path, withDestinationPath: target)
                createdLinkLocations.append(location)
            }
        } catch {
            rollbackMoves(
                realMoves: movedRealLocations,
                linkMoves: linkMoves,
                createdLinks: createdLinkLocations,
                fileManager: fm
            )
            throw SkillRenameError.moveFailed(error)
        }

        let pathMap = Dictionary(uniqueKeysWithValues: locations.map { location in
            let oldFile = skill.isDirectory
                ? location.source.appendingPathComponent(fileName(for: oldFilePaths, under: location.source))
                : location.source
            let newFile = skill.isDirectory
                ? location.destination.appendingPathComponent(oldFile.lastPathComponent)
                : location.destination
            return (oldFile.path, newFile.path)
        })
        let newFilePaths = oldFilePaths.map { oldPath in pathMap[oldPath] ?? oldPath }
        let oldPrimaryPath = skill.filePath
        let newPrimaryPath = pathMap[oldPrimaryPath] ?? oldPrimaryPath

        do {
            let uniqueFiles = Set(newFilePaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
            for path in uniqueFiles {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                let updated = renamedContent(
                    content,
                    oldDisplayName: skill.name,
                    newDisplayName: trimmedName,
                    identifier: newIdentifier
                )
                if updated != content {
                    try updated.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            // The paths were renamed successfully, so keep the model pointed at
            // reality and report that only the document metadata update failed.
            skill.filePath = newPrimaryPath
            skill.installedPaths = newFilePaths
            skill.resolvedPath = URL(fileURLWithPath: newPrimaryPath).resolvingSymlinksInPath().path
            throw SkillRenameError.contentUpdateFailed(error)
        }

        let currentContent = try String(contentsOfFile: newPrimaryPath, encoding: .utf8)
        let parsed = SkillParser.parse(fileURL: URL(fileURLWithPath: newPrimaryPath), toolSource: skill.toolSource)
        skill.filePath = newPrimaryPath
        skill.installedPaths = newFilePaths
        skill.resolvedPath = URL(fileURLWithPath: newPrimaryPath).resolvingSymlinksInPath().path
        skill.name = trimmedName
        skill.content = parsed?.content ?? currentContent
        skill.skillDescription = parsed?.description ?? skill.skillDescription
        skill.frontmatter = parsed?.frontmatter ?? skill.frontmatter
        let attributes = try? fm.attributesOfItem(atPath: newPrimaryPath)
        skill.fileModifiedDate = (attributes?[.modificationDate] as? Date) ?? .now
        skill.fileSize = (attributes?[.size] as? Int) ?? currentContent.utf8.count
    }

    private static func makeLocations(
        filePaths: [String],
        isDirectory: Bool,
        identifier: String,
        fileManager: FileManager
    ) throws -> [Location] {
        var seen = Set<String>()
        return try filePaths.compactMap { filePath in
            let fileURL = URL(fileURLWithPath: filePath)
            let source = isDirectory ? fileURL.deletingLastPathComponent() : fileURL
            guard seen.insert(source.path).inserted else { return nil }
            guard itemExists(at: source, fileManager: fileManager) else {
                throw SkillRenameError.missingSource(source.path)
            }

            let destination: URL
            if isDirectory {
                destination = source.deletingLastPathComponent().appendingPathComponent(identifier, isDirectory: true)
            } else {
                let suffix = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
                destination = source.deletingLastPathComponent().appendingPathComponent(identifier + suffix)
            }
            let attributes = try fileManager.attributesOfItem(atPath: source.path)
            let isLink = (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
            let linkDestination = isLink ? try fileManager.destinationOfSymbolicLink(atPath: source.path) : nil
            return Location(
                source: source,
                destination: destination,
                isSymbolicLink: isLink,
                linkDestination: linkDestination
            )
        }
    }

    private static func fileName(for paths: [String], under directory: URL) -> String {
        paths.first { URL(fileURLWithPath: $0).deletingLastPathComponent().path == directory.path }
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "SKILL.md"
    }

    private static func absoluteLinkDestination(for location: Location) -> URL {
        let raw = location.linkDestination ?? ""
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        return location.source.deletingLastPathComponent().appendingPathComponent(raw).standardizedFileURL
    }

    private static func rollbackMoves(
        realMoves: [Location],
        linkMoves: [Location],
        createdLinks: [Location],
        fileManager: FileManager
    ) {
        for location in createdLinks.reversed() {
            try? fileManager.removeItem(at: location.destination)
        }
        for location in realMoves.reversed() where itemExists(at: location.destination, fileManager: fileManager) {
            try? fileManager.moveItem(at: location.destination, to: location.source)
        }
        for location in linkMoves where !itemExists(at: location.source, fileManager: fileManager) {
            if let target = location.linkDestination {
                try? fileManager.createSymbolicLink(atPath: location.source.path, withDestinationPath: target)
            }
        }
    }

    private static func itemExists(at url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private static func renamedContent(
        _ content: String,
        oldDisplayName: String,
        newDisplayName: String,
        identifier: String
    ) -> String {
        var lines = content.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            if let nameIndex = lines[1..<end].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("name:")
            }) {
                let indentation = String(lines[nameIndex].prefix { $0 == " " || $0 == "\t" })
                lines[nameIndex] = "\(indentation)name: \(yamlScalar(identifier))"
            } else {
                lines.insert("name: \(yamlScalar(identifier))", at: 1)
            }
        }

        if let headingIndex = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            let heading = String(lines[headingIndex].dropFirst(2))
            if heading.hasPrefix(oldDisplayName) {
                lines[headingIndex] = "# \(newDisplayName)" + heading.dropFirst(oldDisplayName.count)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func yamlScalar(_ value: String) -> String {
        let needsQuotes = value.contains(":") || value.contains("#") || value.contains("\"")
            || value.first.map { "[]{}&*!|>'%@`-?".contains($0) } == true
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum SkillRenameError: LocalizedError {
    case invalidName
    case readOnly
    case missingSource(String)
    case alreadyExists(String)
    case moveFailed(Error)
    case contentUpdateFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a name containing at least one letter or number."
        case .readOnly:
            return "This item is read-only and can't be renamed."
        case .missingSource(let path):
            return "The item at \(displayPath(path)) is no longer available. Rescan the library and try again."
        case .alreadyExists(let path):
            return "An item already exists at \(displayPath(path)). Choose another name."
        case .moveFailed(let error):
            return "The item couldn't be renamed: \(error.localizedDescription)"
        case .contentUpdateFailed(let error):
            return "The item was moved, but its name metadata couldn't be updated: \(error.localizedDescription)"
        }
    }

    private func displayPath(_ path: String) -> String {
        path.replacingOccurrences(of: AppPaths.userHomeDirectory, with: "~")
    }
}
