import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class SkillRegistryAndHistoryTests: XCTestCase {

    func testSearchURLEscapesQuerySeparators() {
        let url = SkillRegistry.searchURL(query: "c++ a&b=c")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        XCTAssertTrue(query.hasPrefix("q=c%2B%2B%20a%26b%3Dc&"), query)
        XCTAssertTrue(query.hasSuffix("limit=30"))
    }

    func testShortPathsKeepTheirExistingHexHistoryName() {
        XCTAssertEqual(SkillVersionHistory.historyFileName(for: "/a"), "2f61.json")
    }

    func testLongPathsGetAFilenameWithinTheLimit() {
        let longPath = "/Users/me/Library/Application Support/Claude/local-agent-mode-sessions/"
            + String(repeating: "0123456789abcdef/", count: 8) + "SKILL.md"
        let name = SkillVersionHistory.historyFileName(for: longPath)
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertTrue(name.hasPrefix("sha256-"))
        XCTAssertEqual(name, SkillVersionHistory.historyFileName(for: longPath), "must be stable")
        XCTAssertNotEqual(name, SkillVersionHistory.historyFileName(for: longPath + "x"))
    }
}

// MARK: - Install into temporary agent folders

extension SkillRegistryAndHistoryTests {

    private func makeTarget(_ id: String, in root: URL) -> AgentTarget {
        AgentTarget(
            id: id, displayName: id,
            globalSkillsDir: root.appendingPathComponent(id).path,
            skillFileName: "SKILL.md", evidencePaths: [], appBundleName: nil, cliBinaryName: nil
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RegistryInstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private var original: String { "---\nname: pdf\ndescription: Work with PDFs\n---\nBody" }

    func testRefusesToLinkAgentsToADifferentSkillWithTheSameFolder() throws {
        let root = try makeRoot()
        let primary = makeTarget("primary", in: root)
        let registry = SkillRegistry()
        try registry.install(content: original, skillName: "pdf", agents: [primary])

        let other = "---\nname: pdf\ndescription: Someone else's PDF tool\n---\nOther body"
        XCTAssertThrowsError(
            try registry.install(content: other, skillName: "pdf", agents: [primary, makeTarget("second", in: root)])
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("second/pdf").path))
    }

    func testLinksAnotherAgentToAnEditedCopyOfTheSameSkill() throws {
        let root = try makeRoot()
        let primary = makeTarget("primary", in: root)
        let registry = SkillRegistry()
        try registry.install(content: original, skillName: "pdf", agents: [primary])
        let installed = root.appendingPathComponent("primary/pdf/SKILL.md")
        try (original + "\nMy local notes").write(to: installed, atomically: true, encoding: .utf8)

        try registry.install(content: original, skillName: "pdf", agents: [primary, makeTarget("second", in: root)])

        let linked = try String(contentsOfFile: root.appendingPathComponent("second/pdf/SKILL.md").path, encoding: .utf8)
        XCTAssertTrue(linked.hasSuffix("My local notes"))
    }

    func testReplacesABrokenSymlinkInsteadOfFailing() throws {
        let root = try makeRoot()
        let second = makeTarget("second", in: root)
        try FileManager.default.createDirectory(atPath: second.expandedSkillsDir, withIntermediateDirectories: true)
        let stale = "\(second.expandedSkillsDir)/pdf"
        try FileManager.default.createSymbolicLink(atPath: stale, withDestinationPath: "/nonexistent/pdf")

        try SkillRegistry().install(content: original, skillName: "pdf", agents: [makeTarget("primary", in: root), second])

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(stale)/SKILL.md"))
    }
}

extension SkillRegistryAndHistoryTests {

    func testCompactInstallCounts() {
        typealias R = SkillRegistry.RegistrySkill
        XCTAssertEqual(R.compactCount(999), "999")
        XCTAssertEqual(R.compactCount(1_000), "1K")
        XCTAssertEqual(R.compactCount(1_250), "1.3K")
        XCTAssertEqual(R.compactCount(10_040), "10K")
        XCTAssertEqual(R.compactCount(999_950), "1M")
        XCTAssertEqual(R.compactCount(2_500_000), "2.5M")
    }
}
