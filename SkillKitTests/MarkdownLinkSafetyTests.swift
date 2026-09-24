import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class MarkdownLinkSafetyTests: XCTestCase {

    func testBrowserAndMailLinksMayOpen() {
        for link in ["https://example.com", "http://example.com/a?b=c", "mailto:a@b.co", "HTTPS://EXAMPLE.COM"] {
            XCTAssertTrue(URL(string: link)!.isSafeToOpenFromRenderedMarkdown, link)
        }
    }

    func testAppSchemesAndLocalFilesAreRefused() {
        for link in ["vscode://extension/install", "x-apple.systempreferences:com.apple.preference",
                     "file:///tmp/run.command", "ssh://host", "javascript:alert(1)", "relative/path"] {
            XCTAssertFalse(URL(string: link)!.isSafeToOpenFromRenderedMarkdown, link)
        }
    }
}
