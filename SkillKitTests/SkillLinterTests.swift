import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class SkillLinterTests: XCTestCase {

    func testFixesForMissingFrontmatter() {
        let skill = Skill(
            filePath: "/tmp/test.md",
            toolSource: .claude,
            isDirectory: false,
            name: "Test Skill",
            skillDescription: "Description",
            content: "Content",
            frontmatter: [:],
            fileModifiedDate: .now,
            fileSize: 100,
            isGlobal: true,
            resolvedPath: "/tmp/test.md",
            kind: .skill
        )

        let content = "Just content without frontmatter"
        let fixes = SkillLinter.fixes(for: content, skill: skill)

        XCTAssertTrue(fixes.contains { $0.id == "add-frontmatter" })
        if let fix = fixes.first(where: { $0.id == "add-frontmatter" }) {
            let updated = fix.apply(content, skill)
            XCTAssertTrue(updated.hasPrefix("---\nname: Test Skill"))
        }
    }

    func testFixTrailingWhitespace() {
        let skill = Skill(
            filePath: "/tmp/test.md",
            toolSource: .cursor,
            isDirectory: false,
            name: "Test",
            skillDescription: "Desc",
            content: "Line with space   \nLine 2",
            frontmatter: ["name": "Test"],
            fileModifiedDate: .now,
            fileSize: 100,
            isGlobal: true,
            resolvedPath: "/tmp/test.md",
            kind: .skill
        )

        let content = "Line with space   \nLine 2\n"
        let fixes = SkillLinter.fixes(for: content, skill: skill)

        XCTAssertTrue(fixes.contains { $0.id == "trim-trailing-whitespace" })
        if let fix = fixes.first(where: { $0.id == "trim-trailing-whitespace" }) {
            let updated = fix.apply(content, skill)
            XCTAssertFalse(updated.contains("space   \n"))
        }
    }

    func testFixDeceptiveUnicode() {
        let skill = Skill(
            filePath: "/tmp/test.md",
            toolSource: .claude,
            isDirectory: false,
            name: "Test",
            skillDescription: "Desc",
            content: "Test\u{200B}Unicode",
            frontmatter: ["name": "Test"],
            fileModifiedDate: .now,
            fileSize: 100,
            isGlobal: true,
            resolvedPath: "/tmp/test.md",
            kind: .skill
        )

        let content = "Test\u{200B}Unicode\n"
        let fixes = SkillLinter.fixes(for: content, skill: skill)

        XCTAssertTrue(fixes.contains { $0.id == "remove-deceptive-unicode" })
        if let fix = fixes.first(where: { $0.id == "remove-deceptive-unicode" }) {
            let updated = fix.apply(content, skill)
            XCTAssertEqual(updated, "TestUnicode\n")
        }
    }
}
