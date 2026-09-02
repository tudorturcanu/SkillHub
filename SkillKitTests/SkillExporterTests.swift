import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class SkillExporterTests: XCTestCase {

    private func makeSkill() -> Skill {
        Skill(
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
    }

    func testExportSkillSerialization() throws {
        let exportSkill = SkillExporter.ExportSkill(from: makeSkill())
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

    func testExportIncludesFavoriteLastOpenedAndCollections() throws {
        let skill = makeSkill()
        skill.isFavorite = true
        let opened = Date(timeIntervalSince1970: 1_700_000_000)
        skill.lastOpened = opened
        skill.collections = [
            SkillCollection(name: "Zeta"),
            SkillCollection(name: "Alpha"),
        ]

        let exportSkill = SkillExporter.ExportSkill(from: skill)
        XCTAssertEqual(exportSkill.isFavorite, true)
        XCTAssertEqual(exportSkill.lastOpened, opened)
        XCTAssertEqual(exportSkill.collections, ["Alpha", "Zeta"])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([exportSkill])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try XCTUnwrap(decoder.decode([SkillExporter.ExportSkill].self, from: data).first)
        XCTAssertEqual(decoded.isFavorite, true)
        XCTAssertEqual(decoded.lastOpened?.timeIntervalSince1970 ?? 0, opened.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(decoded.collections, ["Alpha", "Zeta"])
    }

    /// Exports written before favorites/lastOpened/collections were included must still decode.
    func testLegacyExportWithoutNewFieldsDecodes() throws {
        let legacyJSON = """
        [
          {
            "filePath": "/Users/old/.claude/skills/legacy/SKILL.md",
            "toolSource": "claude",
            "isDirectory": true,
            "name": "Legacy",
            "skillDescription": "Old export",
            "content": "Body",
            "frontmatter": {"name": "Legacy"},
            "fileModifiedDate": "2024-01-02T03:04:05Z",
            "fileSize": 4,
            "isGlobal": true,
            "resolvedPath": "/Users/old/.claude/skills/legacy/SKILL.md",
            "kind": "skill"
          }
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([SkillExporter.ExportSkill].self, from: Data(legacyJSON.utf8))
        let item = try XCTUnwrap(decoded.first)
        XCTAssertEqual(item.name, "Legacy")
        XCTAssertNil(item.isFavorite)
        XCTAssertNil(item.lastOpened)
        XCTAssertNil(item.collections)
    }
}
