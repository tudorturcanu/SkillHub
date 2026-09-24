import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

@MainActor
final class SkillEditorDocumentTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorDoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeSkill(at path: String) -> Skill {
        Skill(
            filePath: path, toolSource: .claude, isDirectory: false, name: "doc",
            skillDescription: "", content: "body only", frontmatter: [:],
            fileModifiedDate: .now, fileSize: 1, isGlobal: true, resolvedPath: path, kind: .skill
        )
    }

    private func loaded(_ skill: Skill, expecting text: String) async throws -> SkillEditorDocument {
        let document = SkillEditorDocument()
        document.load(from: skill)
        for _ in 0..<200 where document.editorContent != text {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(document.editorContent, text)
        return document
    }

    func testSaveHoldsBackWhenAnotherEditorChangedTheFile() async throws {
        let file = root.appendingPathComponent("SKILL.md")
        try "---\nname: doc\n---\nv1".write(to: file, atomically: true, encoding: .utf8)
        let skill = makeSkill(at: file.path)
        let document = try await loaded(skill, expecting: "---\nname: doc\n---\nv1")

        try "---\nname: doc\n---\nfrom another editor".write(to: file, atomically: false, encoding: .utf8)
        document.editorContent += "\nmine"
        document.save(to: skill)

        XCTAssertTrue(document.hasSaveConflict)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "---\nname: doc\n---\nfrom another editor")

        // Keep Mine makes the overwrite deliberate.
        document.adoptDiskVersionAsBaseline(for: skill)
        document.save(to: skill)
        XCTAssertFalse(document.hasSaveConflict)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "---\nname: doc\n---\nv1\nmine")
    }

    func testSavingThroughASymlinkKeepsTheLink() async throws {
        let target = root.appendingPathComponent("dotfiles-rule.md")
        let link = root.appendingPathComponent("CLAUDE.md")
        try "rule v1".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let skill = makeSkill(at: link.path)
        let document = try await loaded(skill, expecting: "rule v1")

        document.editorContent = "rule v2"
        document.save(to: skill)

        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "link must survive")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "rule v2")
    }

    func testUnreadableFileNeverSavesTheBodyOnlyFallback() async throws {
        let missing = root.appendingPathComponent("gone/SKILL.md")
        let skill = makeSkill(at: missing.path)
        let document = SkillEditorDocument()
        document.load(from: skill)
        for _ in 0..<200 where !document.loadFailed {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(document.loadFailed)
        XCTAssertNotEqual(document.editorContent, "body only")

        document.editorContent = "typed"
        document.save(to: skill)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertTrue(document.showingSaveError)
    }
}
