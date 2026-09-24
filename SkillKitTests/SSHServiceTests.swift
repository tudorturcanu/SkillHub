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

// MARK: - Remote read command, run through a real shell

extension SSHServiceTests {

    private func runLocally(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testReadCommandRoundTripsContentExactly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHReadCommand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let files: [(name: String, content: String)] = [
            ("no-newline.md", "---\nname: a\n---\nlast line without newline"),
            ("tom's notes.md", "body\n"),
            ("empty.md", ""),
            ("blank-tail.md", "x\n\n"),
        ]
        var paths: [String] = []
        for file in files {
            let url = dir.appendingPathComponent(file.name)
            try file.content.write(to: url, atomically: true, encoding: .utf8)
            paths.append(url.path)
        }

        let blocks = SSHService.parseDelimitedOutput(try runLocally(SSHService.readCommand(for: paths)))

        XCTAssertEqual(blocks.map(\.path), paths)
        XCTAssertEqual(blocks.map(\.content), files.map(\.content))
    }

    /// One unreadable file used to stop every read after it (`&&` chain), and the sync
    /// then deleted the rows for all the skills it never received.
    func testReadCommandSkipsUnreadableFilesAndKeepsGoing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHReadCommand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = dir.appendingPathComponent("a.md")
        let second = dir.appendingPathComponent("b.md")
        try "a".write(to: first, atomically: true, encoding: .utf8)
        try "b".write(to: second, atomically: true, encoding: .utf8)
        let missing = dir.appendingPathComponent("gone.md").path

        let blocks = SSHService.parseDelimitedOutput(
            try runLocally(SSHService.readCommand(for: [first.path, missing, second.path]))
        )

        XCTAssertEqual(blocks.map(\.path), [first.path, second.path])
        XCTAssertEqual(blocks.map(\.content), ["a", "b"])
    }

    func testShellQuotePathKeepsUserTextLiteral() throws {
        XCTAssertEqual(SSHService.shellQuotePath("~/.agents/skills"), "\"$HOME/.agents/skills\"")
        XCTAssertEqual(SSHService.shellQuotePath("~"), "\"$HOME\"")

        let hostile = "/srv/$(touch pwned)/`id`/a\"b\\"
        let echoed = try runLocally("printf %s \(SSHService.shellQuotePath(hostile))")
        XCTAssertEqual(echoed, hostile)
    }
}
