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

    func testTrailingWhitespaceFixPreservesIndentation() {
        let skill = makeSkill()
        let content = """
        - outer
          - nested item\u{0020}\u{0020}
        ```swift
            let indented = true\u{0020}
        ```

        """

        let fixes = SkillLinter.fixes(for: content, skill: skill)
        guard let fix = fixes.first(where: { $0.id == "trim-trailing-whitespace" }) else {
            return XCTFail("Expected a trailing-whitespace fix")
        }
        let updated = fix.apply(content, skill)

        XCTAssertTrue(updated.contains("  - nested item\n"), "List indentation must survive the fix")
        XCTAssertTrue(updated.contains("    let indented = true\n"), "Code-block indentation must survive the fix")
        XCTAssertFalse(updated.contains(" \n"), "No line may keep trailing whitespace")
    }

    func testTrailingWhitespaceFixNotOfferedForIndentationAlone() {
        let skill = makeSkill()
        let content = "- outer\n  - nested\n"

        let fixes = SkillLinter.fixes(for: content, skill: skill)

        XCTAssertFalse(
            fixes.contains { $0.id == "trim-trailing-whitespace" },
            "Leading indentation is not trailing whitespace"
        )
    }

    func testTrailingWhitespaceFixNormalizesCRLFWithoutAddingBlankLines() {
        let skill = makeSkill()
        let content = "First line\r\nSecond line\r\n"

        let fixes = SkillLinter.fixes(for: content, skill: skill)
        guard let fix = fixes.first(where: { $0.id == "trim-trailing-whitespace" }) else {
            return XCTFail("Expected a trailing-whitespace fix")
        }

        XCTAssertEqual(fix.apply(content, skill), "First line\nSecond line\n")
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

    private func makeSkill() -> Skill {
        Skill(
            filePath: "/tmp/test.md",
            toolSource: .cursor,
            isDirectory: false,
            name: "Test",
            skillDescription: "Desc",
            content: "",
            frontmatter: ["name": "Test"],
            fileModifiedDate: .now,
            fileSize: 100,
            isGlobal: true,
            resolvedPath: "/tmp/test.md",
            kind: .skill
        )
    }
}
