import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class SSHServiceTests: XCTestCase {

    func testParseDelimitedOutputExtractsFullPathsAndContent() {
        let output = """
        ---SKILLKIT_DELIM:/home/deploy/.agents/skills/git-flow/SKILL.md---
        ---
        name: git-flow
        description: Branching helper
        ---

        # Git Flow

        Use feature branches.
        ---SKILLKIT_DELIM:/home/deploy/.agents/skills/deploy notes/SKILL.md---
        ---
        name: deploy-notes
        ---
        Second body line 1
        Second body line 2
        ---SKILLKIT_DELIM:/opt/shared/skills/empty/SKILL.md---
        """

        let blocks = SSHService.parseDelimitedOutput(output)

        XCTAssertEqual(blocks.count, 3)

        // Regression: the old parser sliced the delimiter at offset 15 (three short of the
        // 18-character prefix) and produced paths like "IM:/home/...".
        XCTAssertEqual(blocks[0].path, "/home/deploy/.agents/skills/git-flow/SKILL.md")
        XCTAssertFalse(blocks[0].path.hasPrefix("IM:"))
        XCTAssertTrue(blocks[0].content.hasPrefix("---\nname: git-flow"))
        XCTAssertTrue(blocks[0].content.contains("Use feature branches."))

        XCTAssertEqual(blocks[1].path, "/home/deploy/.agents/skills/deploy notes/SKILL.md")
        XCTAssertEqual(blocks[1].content, "---\nname: deploy-notes\n---\nSecond body line 1\nSecond body line 2")

        XCTAssertEqual(blocks[2].path, "/opt/shared/skills/empty/SKILL.md")
        XCTAssertEqual(blocks[2].content, "")
    }

    func testParseDelimitedOutputIgnoresLeadingNoise() {
        let output = "Warning: Permanently added 'host' to known hosts.\n---SKILLKIT_DELIM:/a/SKILL.md---\nbody"
        let blocks = SSHService.parseDelimitedOutput(output)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].path, "/a/SKILL.md")
        XCTAssertEqual(blocks[0].content, "body")
    }

    func testParseDelimitedOutputEmptyInput() {
        XCTAssertTrue(SSHService.parseDelimitedOutput("").isEmpty)
    }

    func testRepairLegacyRemotePath() {
        XCTAssertEqual(SSHService.repairLegacyRemotePath("IM:/home/x/SKILL.md"), "/home/x/SKILL.md")
        XCTAssertEqual(SSHService.repairLegacyRemotePath("/home/x/SKILL.md"), "/home/x/SKILL.md")
        XCTAssertEqual(SSHService.repairLegacyRemotePath("IM:"), "")
    }

    func testAuthenticationFailureDetection() {
        XCTAssertTrue(SSHService.isAuthenticationFailure("deploy@host: Permission denied (publickey,password)."))
        XCTAssertTrue(SSHService.isAuthenticationFailure("SSH connection failed: Permission denied"))
        XCTAssertFalse(SSHService.isAuthenticationFailure("ssh: connect to host 10.0.0.1 port 22: Connection refused"))
    }
}

// MARK: - Regression tests for review findings

extension SSHServiceTests {

    /// A path containing a single quote used to break out of the `echo '...'`
    /// argument, turning the whole remote command into a syntax error that read
    /// back as "this server has no skills" — and then deleted every synced row.
    func testPathWithQuoteRoundTripsThroughDelimiter() {
        let awkwardPath = "/home/tom/.agents/skills/tom's-notes/SKILL.md"
        let output = """
        ---SKILLKIT_DELIM:\(awkwardPath)---
        # Notes
        body
        """

        let blocks = SSHService.parseDelimitedOutput(output)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.path, awkwardPath)
        XCTAssertTrue(blocks.first?.content.contains("# Notes") == true)
    }

    /// The old parser sliced 15 characters off an 18-character delimiter,
    /// leaving "IM:" glued to every path.
    func testRepairLegacyRemotePathStripsOnlyTheStrayPrefix() {
        XCTAssertEqual(
            SSHService.repairLegacyRemotePath("IM:/home/u/.agents/skills/a/SKILL.md"),
            "/home/u/.agents/skills/a/SKILL.md"
        )
        // A legitimate path must never be altered.
        let legitimate = "/home/u/.agents/skills/IMPORTANT/SKILL.md"
        XCTAssertEqual(SSHService.repairLegacyRemotePath(legitimate), legitimate)
        XCTAssertEqual(SSHService.repairLegacyRemotePath(""), "")
    }
}
