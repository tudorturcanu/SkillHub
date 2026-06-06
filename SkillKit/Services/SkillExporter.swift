import Foundation
import SwiftData
import SwiftUI

@MainActor
final class SkillExporter {
    static let shared = SkillExporter()
    private init() {}

    func export(skills: [Skill]) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SkillKit_Export.json"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        
        // Use an array of Codable structures matching the Skill properties we want to export
        let exportData = skills.map { ExportSkill(from: $0) }
        let data = try encoder.encode(exportData)
        try data.write(to: url, options: .atomic)
    }
    
    func importData(modelContext: ModelContext) throws {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let importedSkills = try decoder.decode([ExportSkill].self, from: data)
        
        for imported in importedSkills {
            // Very naive import: just recreate the models and write to the same paths
            // Realistically we might want to ask where to import or merge.
            let boilerplate = imported.content
            let skill = Skill(
                filePath: imported.filePath,
                toolSource: imported.toolSource,
                isDirectory: imported.isDirectory,
                name: imported.name,
                skillDescription: imported.skillDescription,
                content: boilerplate,
                frontmatter: imported.frontmatter,
                fileModifiedDate: imported.fileModifiedDate,
                fileSize: imported.fileSize,
                isGlobal: imported.isGlobal,
                resolvedPath: imported.resolvedPath,
                kind: imported.kind
            )
            modelContext.insert(skill)
            
            // Re-write file to disk
            if let dir = URL(string: skill.filePath)?.deletingLastPathComponent() {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let fullContent = "---\n" + skill.frontmatter.map { "\($0.key): \($0.value)" }.joined(separator: "\n") + "\n---\n\n" + skill.content
                try? fullContent.write(toFile: skill.filePath, atomically: true, encoding: .utf8)
            }
        }
        try modelContext.save()
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
