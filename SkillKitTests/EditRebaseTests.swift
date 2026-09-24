import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class EditRebaseTests: XCTestCase {

    private let original = "# Title\n\nintro\n\n## Usage\nold usage\n\n## Notes\nnote"

    func testUnchangedEditorTakesTheProposalAsIs() {
        let proposed = original.replacingOccurrences(of: "old usage", with: "new usage")
        XCTAssertEqual(EditRebase.apply(original: original, proposed: proposed, onto: original), proposed)
    }

    func testKeepsWhatTheUserTypedElsewhereWhileTheAgentWorked() {
        let proposed = original.replacingOccurrences(of: "old usage", with: "new usage\nmore usage")
        let current = original.replacingOccurrences(of: "note", with: "my new note\nanother")
        XCTAssertEqual(
            EditRebase.apply(original: original, proposed: proposed, onto: current),
            "# Title\n\nintro\n\n## Usage\nnew usage\nmore usage\n\n## Notes\nmy new note\nanother"
        )
    }

    func testRefusesWhenBothChangedTheSameLines() {
        let proposed = original.replacingOccurrences(of: "old usage", with: "agent usage")
        let current = original.replacingOccurrences(of: "old usage", with: "my usage")
        XCTAssertNil(EditRebase.apply(original: original, proposed: proposed, onto: current))
    }

    func testRefusesWhenTheUserInsertedRightNextToTheEdit() {
        let proposed = original.replacingOccurrences(of: "old usage", with: "agent usage")
        let current = original.replacingOccurrences(of: "## Usage\n", with: "## Usage\nuser line\n")
        XCTAssertNil(EditRebase.apply(original: original, proposed: proposed, onto: current))
    }

    func testAppliesInsertionsAndDeletions() {
        let proposed = "# Title\n\nintro\n\n## Usage\nold usage\n\n## Notes\nnote\n\n## Added"
        let current = "# Title (edited)\n\nintro\n\n## Usage\nold usage\n\n## Notes\nnote"
        XCTAssertEqual(
            EditRebase.apply(original: original, proposed: proposed, onto: current),
            "# Title (edited)\n\nintro\n\n## Usage\nold usage\n\n## Notes\nnote\n\n## Added"
        )
        let deleting = "# Title\n\nintro\n\n## Notes\nnote"
        XCTAssertEqual(
            EditRebase.apply(original: original, proposed: deleting, onto: current),
            "# Title (edited)\n\nintro\n\n## Notes\nnote"
        )
    }
}
