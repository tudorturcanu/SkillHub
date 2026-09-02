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

    func testUnterminatedFrontmatterIsWarnedNotFixed() {
        let skill = makeSkill()
        let content = "---\nname: Broken\ndescription: never closed\n\nBody text\n"

        let report = SkillLinter.lint(content, skill: skill)

        XCTAssertFalse(report.fixes.contains { $0.id == "add-frontmatter" }, "Must not wrap an open block in a second one")
        XCTAssertTrue(report.warnings.contains { $0.id == SkillLinter.unterminatedFrontmatterWarningID })
        XCTAssertEqual(report.warnings.first?.title, "Unterminated frontmatter")
        XCTAssertTrue(SkillLinter.hasUnterminatedFrontmatter(content))
        XCTAssertFalse(SkillLinter.hasUnterminatedFrontmatter("---\nname: ok\n---\nBody\n"))
        XCTAssertFalse(SkillLinter.hasUnterminatedFrontmatter("No frontmatter at all\n"))
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

    func testTrailingWhitespaceFixPreservesIndentationAndSkipsFences() {
        let skill = makeSkill()
        let content = """
        - outer
          - nested item\u{0020}\u{0020}\u{0020}
        ```swift
            let indented = true\u{0020}
        ```
        Tail\u{0020}

        """

        let fixes = SkillLinter.fixes(for: content, skill: skill)
        guard let fix = fixes.first(where: { $0.id == "trim-trailing-whitespace" }) else {
            return XCTFail("Expected a trailing-whitespace fix")
        }
        let updated = fix.apply(content, skill)

        XCTAssertTrue(updated.contains("  - nested item\n"), "List indentation must survive; three trailing spaces are not a hard break")
        XCTAssertTrue(updated.contains("    let indented = true \n"), "Lines inside fenced code blocks are left alone")
        XCTAssertTrue(updated.contains("Tail\n"))
    }

    func testTrailingWhitespaceFixKeepsMarkdownHardBreaks() {
        let skill = makeSkill()
        let content = "Roses are red\u{0020}\u{0020}\nViolets are blue\u{0020}\u{0020}\u{0020}\nDone\n"

        let fixes = SkillLinter.fixes(for: content, skill: skill)
        guard let fix = fixes.first(where: { $0.id == "trim-trailing-whitespace" }) else {
            return XCTFail("Expected a trailing-whitespace fix (three spaces on line 2)")
        }

        XCTAssertEqual(fix.apply(content, skill), "Roses are red\u{0020}\u{0020}\nViolets are blue\nDone\n")
    }

    func testTrailingWhitespaceFixNotOfferedWhenOnlyFencesAndHardBreaks() {
        let skill = makeSkill()
        let content = "Break here\u{0020}\u{0020}\n~~~\ncode\u{0020}\u{0020}\u{0020}\n~~~\n"

        let fixes = SkillLinter.fixes(for: content, skill: skill)

        XCTAssertFalse(fixes.contains { $0.id == "trim-trailing-whitespace" })
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
        let content = "First line\r\nSecond line\r\n```\ncode\r\n```\r\n"

        let fixes = SkillLinter.fixes(for: content, skill: skill)
        guard let fix = fixes.first(where: { $0.id == "trim-trailing-whitespace" }) else {
            return XCTFail("Expected a trailing-whitespace fix")
        }

        XCTAssertEqual(fix.apply(content, skill), "First line\nSecond line\n```\ncode\n```\n")
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

    func testPreviewReturnsProposedTextWithoutMutatingInput() {
        let skill = makeSkill()
        let content = "Body without newline"

        guard let fix = SkillLinter.fixes(for: content, skill: skill).first(where: { $0.id == "add-final-newline" }) else {
            return XCTFail("Expected an add-final-newline fix")
        }
        let preview = SkillLinter.preview(fix, content: content, skill: skill)

        XCTAssertEqual(preview.original, content)
        XCTAssertEqual(preview.proposed, content + "\n")
        XCTAssertTrue(preview.hasChanges)
        XCTAssertEqual(preview.id, fix.id)

        let noop = fix.preview(content + "\n", skill: skill)
        XCTAssertFalse(noop.hasChanges)
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
