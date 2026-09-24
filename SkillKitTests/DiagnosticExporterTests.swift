import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class DiagnosticExporterTests: XCTestCase {

    func testRedactsHomeDirectoryInPathsAndLogLines() {
        let text = """
        - Root: /Users/al/.agents
        [12:00:00.000] [fileIO] Saved /Users/al/Library/x.md
        home is /Users/al
        """
        let redacted = DiagnosticExporter.redactingHomeDirectory(text, home: "/Users/al/")
        XCTAssertEqual(redacted, """
        - Root: ~/.agents
        [12:00:00.000] [fileIO] Saved ~/Library/x.md
        home is ~
        """)
    }

    func testLeavesOtherAccountsWithSharedPrefixAlone() {
        let text = "/Users/alice/x /Users/al-backup/y /Users/al.old"
        XCTAssertEqual(DiagnosticExporter.redactingHomeDirectory(text, home: "/Users/al"), text)
    }
}
