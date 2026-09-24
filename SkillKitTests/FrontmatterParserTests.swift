import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class FrontmatterParserTests: XCTestCase {

    func testParseBasicFrontmatter() {
        let input = """
        ---
        name: My Custom Skill
        description: A test skill for code generation
        ---
        This is the body content.
        """

        let result = FrontmatterParser.parse(input)
        XCTAssertEqual(result.name, "My Custom Skill")
        XCTAssertEqual(result.description, "A test skill for code generation")
        XCTAssertEqual(result.content, "This is the body content.")
        XCTAssertEqual(result.frontmatter["name"], "My Custom Skill")
    }

    func testParseQuotedValues() {
        let input = """
        ---
        name: "Quoted Skill Name"
        description: 'Single quoted description'
        ---
        Body content here.
        """

        let result = FrontmatterParser.parse(input)
        XCTAssertEqual(result.name, "Quoted Skill Name")
        XCTAssertEqual(result.description, "Single quoted description")
    }

    func testParseInlineArrayTags() {
        let input = """
        ---
        name: Tagged Skill
        tags: [swift, macos, xcode]
        ---
        Content
        """

        let result = FrontmatterParser.parse(input)
        XCTAssertEqual(result.frontmatter["tags"], "swift, macos, xcode")
    }

    func testParseWithoutFrontmatter() {
        let input = "Just standard markdown content without frontmatter block."
        let result = FrontmatterParser.parse(input)

        XCTAssertTrue(result.frontmatter.isEmpty)
        XCTAssertEqual(result.name, "")
        XCTAssertEqual(result.description, "")
        XCTAssertEqual(result.content, input)
    }

    func testParseYAMLCommentsAndEmptyLines() {
        let input = """
        ---
        # This is a YAML comment
        name: Skill With Comments
        
        description: Description text
        ---
        Body
        """

        let result = FrontmatterParser.parse(input)
        XCTAssertEqual(result.name, "Skill With Comments")
        XCTAssertEqual(result.description, "Description text")
    }
}

// MARK: - Line endings and indentation

extension FrontmatterParserTests {

    func testParsesCRLFFrontmatter() {
        let result = FrontmatterParser.parse("---\r\nname: crlf\r\ndescription: Windows file\r\n---\r\nbody\r\n")
        XCTAssertEqual(result.name, "crlf")
        XCTAssertEqual(result.description, "Windows file")
        XCTAssertEqual(result.content, "body")
    }

    func testIndentedColonLinesStayInsideBlockScalar() {
        let input = """
        ---
        name: scalar
        description: |
          Use this.
          Note: careful
          https://example.com
        ---
        body
        """
        let result = FrontmatterParser.parse(input)
        XCTAssertEqual(result.description, "Use this.\n  Note: careful\n  https://example.com")
        XCTAssertNil(result.frontmatter["Note"])
        XCTAssertNil(result.frontmatter["https"])
    }

    func testNestedKeyDoesNotOverrideTopLevelName() {
        let input = """
        ---
        name: outer
        metadata:
          name: inner
        description: after nested map
        ---
        """
        let result = FrontmatterParser.parse(input)
        XCTAssertEqual(result.name, "outer")
        XCTAssertEqual(result.description, "after nested map")
    }
}
