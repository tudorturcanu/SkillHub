import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class OneShotResponseParserTests: XCTestCase {

    private let original = "---\nname: tools\ndescription: d\n---\n# Tools\n\nUse Bash.\n"

    func testFullFileReplyBecomesTheProposal() {
        let reply = "Tightened the wording.\n\n```markdown\n---\nname: tools\ndescription: d\n---\n# Tools\n\nUse Bash carefully.\n```\n"
        let result = OneShotResponseParser.parse(reply, originalContent: original)
        XCTAssertEqual(result.summary, "Tightened the wording.")
        XCTAssertEqual(result.newContent, "---\nname: tools\ndescription: d\n---\n# Tools\n\nUse Bash carefully.\n")
    }

    /// A question answered with a snippet used to replace the whole file with the snippet.
    func testSnippetInAnAnswerIsNotAnEdit() {
        let reply = "Add this to the frontmatter:\n\n```yaml\nallowed-tools: Bash\n```\n\nThen restart the agent."
        XCTAssertNil(OneShotResponseParser.parse(reply, originalContent: original).newContent)
    }

    func testTrailingSnippetWithoutFrontmatterIsRejectedWithANote() {
        let reply = "Here you go:\n```yaml\nallowed-tools: Bash\n```"
        let result = OneShotResponseParser.parse(reply, originalContent: original)
        XCTAssertNil(result.newContent)
        XCTAssertTrue(result.summary.contains("doesn't look like the complete file"))
    }

    /// A four-backtick wrapper around a file with its own ``` block used to yield the inner block.
    func testLongerFenceWrapsFileWithInnerCodeBlocks() {
        let file = "---\nname: tools\ndescription: d\n---\n# Tools\n\n```bash\nls\n```\n"
        let reply = "Added an example.\n\n````markdown\n\(file)````"
        XCTAssertEqual(OneShotResponseParser.parse(reply, originalContent: original).newContent, file)
    }

    func testUnclosedFenceIsNotProposed() {
        let reply = "Updated.\n```\n---\nname: tools\n---\n# Tools\n\nUse Ba"
        XCTAssertNil(OneShotResponseParser.parse(reply, originalContent: original).newContent)
    }

    func testFailedStructuredEditIsReported() {
        let reply = #"{"summary": "Updated tools", "edits": [{"find": "not in file", "replace": "x"}]}"#
        let result = OneShotResponseParser.parse(reply, originalContent: original)
        XCTAssertNil(result.newContent)
        XCTAssertTrue(result.summary.hasPrefix("Updated tools\n\n(The edit couldn't be applied: edit #1"), result.summary)
    }

    func testStructuredEditApplies() {
        let reply = #"{"summary": "s", "edits": [{"find": "Use Bash.", "replace": "Use Bash carefully."}]}"#
        XCTAssertEqual(
            OneShotResponseParser.parse(reply, originalContent: original).newContent,
            original.replacingOccurrences(of: "Use Bash.", with: "Use Bash carefully.")
        )
    }
}
