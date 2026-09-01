import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class ToolSourceTests: XCTestCase {

    func testToolSourceDisplayNames() {
        XCTAssertEqual(ToolSource.claude.displayName, "Claude Code")
        XCTAssertEqual(ToolSource.cursor.displayName, "Cursor")
        XCTAssertEqual(ToolSource.codex.displayName, "Codex")
        XCTAssertEqual(ToolSource.windsurf.displayName, "Windsurf")
        XCTAssertEqual(ToolSource.copilot.displayName, "Copilot")
        XCTAssertEqual(ToolSource.antigravity.displayName, "Antigravity")
    }

    func testToolSourceListable() {
        XCTAssertTrue(ToolSource.claude.listable)
        XCTAssertTrue(ToolSource.cursor.listable)
        XCTAssertFalse(ToolSource.custom.listable)
    }

    func testGlobalPathsExist() {
        for tool in ToolSource.allCases {
            if tool != .custom && tool != .claudeDesktop && tool != .aider && tool != .windsurf {
                XCTAssertFalse(tool.globalPaths.isEmpty, "Global paths should not be empty for \(tool)")
            }
        }
    }

    func testPATHResolution() {
        let env = ToolSource.envWithResolvedPATH()
        let path = env["PATH"] ?? ""
        XCTAssertTrue(path.contains("/usr/bin"))
        XCTAssertTrue(path.contains("/bin"))
    }
}
