import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class SkillExporterTests: XCTestCase {

    func testExportSkillSerialization() throws {
        let skill = Skill(
            filePath: "/tmp/my-skill/SKILL.md",
            toolSource: .claude,
            isDirectory: true,
            name: "Export Test Skill",
            skillDescription: "Testing skill export serialization",
            content: "Skill content body",
            frontmatter: ["name": "Export Test Skill", "description": "Testing skill export serialization"],
            fileModifiedDate: .now,
            fileSize: 200,
            isGlobal: true,
            resolvedPath: "/tmp/my-skill/SKILL.md",
            kind: .skill
        )

        let exportSkill = SkillExporter.ExportSkill(from: skill)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode([exportSkill])
        XCTAssertFalse(data.isEmpty)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([SkillExporter.ExportSkill].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.name, "Export Test Skill")
        XCTAssertEqual(decoded.first?.toolSource, .claude)
    }
}
