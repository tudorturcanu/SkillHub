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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let importedSkills = try decoder.decode([ExportSkill].self, from: data)
        
        let existingSkills = try modelContext.fetch(FetchDescriptor<Skill>())
        var existingPaths = Set(existingSkills.map(\.filePath))
        var importedCount = 0
        var skippedCount = 0

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

            let skill = Skill(
                filePath: filePath,
                toolSource: imported.toolSource,
                isDirectory: imported.isDirectory,
                name: imported.name,
                skillDescription: imported.skillDescription,
                content: imported.content,
                frontmatter: imported.frontmatter,
                fileModifiedDate: imported.fileModifiedDate,
                fileSize: imported.fileSize,
                isGlobal: imported.isGlobal,
                resolvedPath: imported.resolvedPath,
                kind: imported.kind
            )
            modelContext.insert(skill)
            existingPaths.insert(filePath)
            importedCount += 1
        }
        try modelContext.save()
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
        }
    }
}
