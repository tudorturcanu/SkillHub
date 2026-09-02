import Foundation
import SwiftData
import SwiftUI

@MainActor
final class SkillExporter {
    struct ImportResult {
        let importedCount: Int
        let skippedCount: Int
        let wasCancelled: Bool
    }

    static let shared = SkillExporter()
    private init() {}

    /// Human-readable summary of what an export contains, for Settings copy.
    static let exportContentsDescription =
        "Includes each item's content, frontmatter, tool, kind, favorite flag, last-opened date, and collection membership. Absolute file paths are recorded for reference but items are imported into this Mac's configured library folders."

    func export(skills: [Skill]) throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SkillKit_Export.json"

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601

        // Use an array of Codable structures matching the Skill properties we want to export
        let exportData = skills.map { ExportSkill(from: $0) }
        let data = try encoder.encode(exportData)
        try data.write(to: url, options: .atomic)
        return true
    }

    func importData(modelContext: ModelContext) throws -> ImportResult {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return ImportResult(importedCount: 0, skippedCount: 0, wasCancelled: true)
        }

        let data = try Data(contentsOf: url)
        return try importData(from: data, modelContext: modelContext)
    }

    /// Imports the given export JSON. Split from the panel-driven entry point so it can be tested.
    func importData(from data: Data, modelContext: ModelContext) throws -> ImportResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let importedSkills = try decoder.decode([ExportSkill].self, from: data)

        let existingSkills = try modelContext.fetch(FetchDescriptor<Skill>())
        var existingPaths = Set(existingSkills.map(\.filePath))
        var collectionsByName = Dictionary(
            try modelContext.fetch(FetchDescriptor<SkillCollection>()).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var importedCount = 0
        var skippedCount = 0
        var writtenURLs: [URL] = []

        do {
            for imported in importedSkills {
                guard let destination = destination(for: imported) else {
                    skippedCount += 1
                    continue
                }

                let filePath = destination.path
                guard !existingPaths.contains(filePath), !FileManager.default.fileExists(atPath: filePath) else {
                    skippedCount += 1
                    continue
                }

                let fullContent = serializedContent(for: imported)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fullContent.write(to: destination, atomically: true, encoding: .utf8)
                writtenURLs.append(destination)

                let skill = Skill(
                    filePath: filePath,
                    toolSource: imported.toolSource,
                    isDirectory: imported.isDirectory,
                    name: imported.name,
                    skillDescription: imported.skillDescription,
                    content: imported.content,
                    frontmatter: imported.frontmatter,
                    isFavorite: imported.isFavorite ?? false,
                    lastOpened: imported.lastOpened,
                    fileModifiedDate: imported.fileModifiedDate,
                    fileSize: fullContent.utf8.count,
                    isGlobal: true,
                    resolvedPath: filePath,
                    kind: imported.kind
                )
                modelContext.insert(skill)

                // Restore collection membership by name, creating any collections the
                // export references that don't exist here yet.
                for name in imported.collections ?? [] {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let collection: SkillCollection
                    if let existing = collectionsByName[trimmed] {
                        collection = existing
                    } else {
                        collection = SkillCollection(name: trimmed, sortOrder: collectionsByName.count)
                        modelContext.insert(collection)
                        collectionsByName[trimmed] = collection
                    }
                    if !skill.collections.contains(where: { $0.name == trimmed }) {
                        skill.collections.append(collection)
                    }
                }

                existingPaths.insert(filePath)
                importedCount += 1
            }
            try modelContext.save()
        } catch {
            for url in writtenURLs {
                try? FileManager.default.removeItem(at: url)
            }
            modelContext.rollback()
            throw error
        }
        return ImportResult(importedCount: importedCount, skippedCount: skippedCount, wasCancelled: false)
    }

    /// Imports into the current machine's configured SkillKit locations, never the
    /// absolute paths exported from another machine.
    private func destination(for skill: ExportSkill) -> URL? {
        let sanitizedName = skill.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !sanitizedName.isEmpty else { return nil }

        switch skill.kind {
        case .skill:
            guard let root = skill.toolSource.globalPaths.first else { return nil }
            return URL(fileURLWithPath: root)
                .appendingPathComponent(sanitizedName, isDirectory: true)
                .appendingPathComponent("SKILL.md")
        case .rule:
            guard let root = skill.toolSource.globalRulePaths.first else { return nil }
            return URL(fileURLWithPath: root)
                .appendingPathComponent("\(sanitizedName).md")
        }
    }

    private func serializedContent(for skill: ExportSkill) -> String {
        guard !skill.frontmatter.isEmpty else { return skill.content }
        let frontmatter = skill.frontmatter
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        return "---\n\(frontmatter)\n---\n\n\(skill.content)"
    }

    struct ExportSkill: Codable {
        var filePath: String
        var toolSource: ToolSource
        var isDirectory: Bool
        var name: String
        var skillDescription: String
        var content: String
        var frontmatter: [String: String]
        var fileModifiedDate: Date
        var fileSize: Int
        var isGlobal: Bool
        var resolvedPath: String
        var kind: ItemKind
        // Added later; optional so exports written by earlier versions still decode.
        var isFavorite: Bool?
        var lastOpened: Date?
        /// Collection names this item belonged to.
        var collections: [String]?

        init(from skill: Skill) {
            self.filePath = skill.filePath
            self.toolSource = skill.toolSource
            self.isDirectory = skill.isDirectory
            self.name = skill.name
            self.skillDescription = skill.skillDescription
            self.content = skill.content
            self.frontmatter = skill.frontmatter
            self.fileModifiedDate = skill.fileModifiedDate
            self.fileSize = skill.fileSize
            self.isGlobal = skill.isGlobal
            self.resolvedPath = skill.resolvedPath
            self.kind = skill.itemKind
            self.isFavorite = skill.isFavorite
            self.lastOpened = skill.lastOpened
            self.collections = skill.collections.map(\.name).sorted()
        }
    }
}
