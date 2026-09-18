import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

/// Deleting a skill used to unlink it permanently, and removed its installed
/// paths in alphabetical order — which could trash the canonical folder before
/// a symlink pointing at it, leaving the link dangling and skipped.
final class SkillDeletionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Deliberately under the home directory rather than the temp volume:
        // `trashItem` routes to the volume's own .Trashes, and skills really do
        // live under home, so this exercises the path users hit.
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".skillkit-deletion-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// A folder-style skill is modelled by the path of the `SKILL.md` *inside*
    /// the folder; the folder itself is what gets deleted. Mirrors what the
    /// scanner builds.
    private func makeSkill(filePath: String, installedPaths: [String]) -> Skill {
        let skill = Skill(
            filePath: filePath,
            toolSource: .claude,
            isDirectory: true,
            name: "Deletable",
            skillDescription: "",
            content: "body",
            frontmatter: [:],
            fileModifiedDate: .now,
            fileSize: 10,
            isGlobal: true,
            resolvedPath: filePath,
            kind: .skill
        )
        skill.installedPaths = installedPaths
        return skill
    }

    func testDeleteMovesTheSkillToTheTrashRatherThanUnlinkingIt() throws {
        let folder = root.appendingPathComponent("my-skill")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("SKILL.md")
        try "# Mine".write(to: file, atomically: true, encoding: .utf8)

        let skill = makeSkill(filePath: file.path, installedPaths: [file.path])
        let trashed = try skill.deleteFromDisk()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.path),
            "the skill should be gone from its original location"
        )
        // The point of the change: it was relocated, not destroyed, so the
        // user can still get it back.
        XCTAssertEqual(trashed.count, 1, "expected exactly one item in the Trash")
        let recovered = try XCTUnwrap(trashed.first)
        XCTAssertTrue(recovered.path.contains("/.Trash"), "expected a Trash path, got \(recovered.path)")
        XCTAssertEqual(recovered.lastPathComponent, "my-skill", "the skill folder should be trashed, not its parent")
        XCTAssertEqual(
            try String(contentsOf: recovered.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "# Mine",
            "the trashed copy must still hold the user's content"
        )

        try? FileManager.default.removeItem(at: recovered)
    }

    /// The canonical folder sorts *after* the symlink alphabetically here, so a
    /// naive ordering would remove the target first and leave "a-link"
    /// dangling — at which point `fileExists` reports it missing and it is
    /// silently skipped, stranding a broken link in the agent's folder.
    func testSymlinksAreRemovedBeforeTheirTarget() throws {
        let canonical = root.appendingPathComponent("z-canonical")
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        try "# Canonical".write(
            to: canonical.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let link = root.appendingPathComponent("a-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: canonical)

        let skill = makeSkill(
            filePath: canonical.appendingPathComponent("SKILL.md").path,
            installedPaths: [
                canonical.appendingPathComponent("SKILL.md").path,
                link.appendingPathComponent("SKILL.md").path,
            ]
        )
        let trashed = try skill.deleteFromDisk()

        XCTAssertNil(
            try? FileManager.default.attributesOfItem(atPath: link.path),
            "the symlink must be removed, not left dangling"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))

        for url in trashed {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func testDeletingAnAlreadyMissingSkillIsNotAnError() throws {
        let missing = root.appendingPathComponent("never-existed").appendingPathComponent("SKILL.md")
        let skill = makeSkill(filePath: missing.path, installedPaths: [missing.path])
        XCTAssertNoThrow(try skill.deleteFromDisk())
    }

    /// Guards the folder-derivation rule itself: deleting a skill must target
    /// its own folder, never the library directory that contains it.
    func testDeletionNeverTargetsTheContainingLibraryDirectory() throws {
        let folder = root.appendingPathComponent("scoped-skill")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("SKILL.md")
        try "# Scoped".write(to: file, atomically: true, encoding: .utf8)

        let skill = makeSkill(filePath: file.path, installedPaths: [file.path])
        XCTAssertEqual(skill.deletionTargets, [folder.path])

        let trashed = try skill.deleteFromDisk()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.path),
            "the containing directory must survive deleting one skill"
        )
        for url in trashed { try? FileManager.default.removeItem(at: url) }
    }
}

final class SkillRenameTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillkit-rename-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testRenameRuleMovesFileAndUpdatesHeading() throws {
        let original = root.appendingPathComponent("old-rule.md")
        try "# Old Rule (SkillKit Rule)\n\nKeep responses concise."
            .write(to: original, atomically: true, encoding: .utf8)
        let skill = Skill(
            filePath: original.path,
            toolSource: .claude,
            name: "Old Rule",
            content: "# Old Rule (SkillKit Rule)\n\nKeep responses concise.",
            fileModifiedDate: .now,
            fileSize: 52,
            resolvedPath: original.path,
            kind: .rule
        )

        try SkillRenamer.rename(skill, to: "Clear Answers")

        let renamed = root.appendingPathComponent("clear-answers.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(skill.filePath, renamed.path)
        XCTAssertEqual(skill.name, "Clear Answers")
        XCTAssertTrue(try String(contentsOf: renamed, encoding: .utf8).hasPrefix("# Clear Answers (SkillKit Rule)"))
    }

    func testRenameGlobalSkillKeepsLinkedInstallationWorking() throws {
        let canonicalRoot = root.appendingPathComponent("agents/skills", isDirectory: true)
        let linkedRoot = root.appendingPathComponent("claude/skills", isDirectory: true)
        let canonicalFolder = canonicalRoot.appendingPathComponent("old-skill", isDirectory: true)
        let linkedFolder = linkedRoot.appendingPathComponent("old-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
        let originalFile = canonicalFolder.appendingPathComponent("SKILL.md")
        let originalContent = """
        ---
        name: old-skill
        description: A linked skill
        ---

        # Old Skill (SkillKit Skill)

        Instructions.
        """
        try originalContent.write(to: originalFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: canonicalFolder)

        let linkedFile = linkedFolder.appendingPathComponent("SKILL.md")
        let skill = Skill(
            filePath: originalFile.path,
            toolSource: .agents,
            isDirectory: true,
            name: "Old Skill",
            skillDescription: "A linked skill",
            content: "# Old Skill (SkillKit Skill)\n\nInstructions.",
            frontmatter: ["name": "old-skill", "description": "A linked skill"],
            fileModifiedDate: .now,
            fileSize: originalContent.utf8.count,
            resolvedPath: originalFile.path,
            kind: .skill
        )
        skill.installedPaths = [originalFile.path, linkedFile.path]

        try SkillRenamer.rename(skill, to: "Better Skill")

        let renamedCanonical = canonicalRoot.appendingPathComponent("better-skill/SKILL.md")
        let renamedLink = linkedRoot.appendingPathComponent("better-skill/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedCanonical.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedLink.path))
        XCTAssertEqual(
            URL(fileURLWithPath: renamedLink.path).resolvingSymlinksInPath().path,
            renamedCanonical.path
        )
        XCTAssertEqual(Set(skill.installedPaths), Set([renamedCanonical.path, renamedLink.path]))
        XCTAssertEqual(skill.filePath, renamedCanonical.path)

        let content = try String(contentsOf: renamedCanonical, encoding: .utf8)
        XCTAssertTrue(content.contains("name: better-skill"))
        XCTAssertTrue(content.contains("# Better Skill (SkillKit Skill)"))
    }

    func testRenameRefusesToOverwriteAnExistingItem() throws {
        let original = root.appendingPathComponent("first.md")
        let collision = root.appendingPathComponent("second.md")
        try "# First".write(to: original, atomically: true, encoding: .utf8)
        try "# Second".write(to: collision, atomically: true, encoding: .utf8)
        let skill = Skill(
            filePath: original.path,
            toolSource: .claude,
            name: "First",
            content: "# First",
            fileModifiedDate: .now,
            fileSize: 7,
            resolvedPath: original.path,
            kind: .rule
        )

        XCTAssertThrowsError(try SkillRenamer.rename(skill, to: "Second"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try String(contentsOf: collision, encoding: .utf8), "# Second")
        XCTAssertEqual(skill.filePath, original.path)
    }
}

/// The sidebar selection and open item are restored on relaunch, so the
/// encoding has to survive a round trip for every filter shape.
final class SidebarFilterPersistenceTests: XCTestCase {

    func testEveryFilterShapeRoundTrips() {
        let cases: [SidebarFilter] = [
            .dashboard,
            .discover,
            .recent,
            .allSkills,
            .allRules,
            .needsReview,
            .securityReview,
            .favorites,
            .tool(.claude),
            .tool(.cursor),
            .customPlatform(id: "my-platform"),
            .collection("Release Checklists"),
            .server("6B0F1C2E-0000-4000-8000-000000000001"),
        ]

        for filter in cases {
            let encoded = filter.persistedValue
            XCTAssertEqual(
                SidebarFilter(persistedValue: encoded),
                filter,
                "\(encoded) did not round trip"
            )
        }
    }

    /// A collection named with a colon must not be truncated at the separator.
    func testPayloadContainingSeparatorSurvives() {
        let filter = SidebarFilter.collection("Notes: Q3")
        XCTAssertEqual(SidebarFilter(persistedValue: filter.persistedValue), filter)
    }

    func testUnknownOrCorruptValuesAreRejected() {
        XCTAssertNil(SidebarFilter(persistedValue: ""))
        XCTAssertNil(SidebarFilter(persistedValue: "nonsense"))
        XCTAssertNil(SidebarFilter(persistedValue: "tool:notATool"))
    }
}
