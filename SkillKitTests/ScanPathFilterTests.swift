import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class ScanPathFilterTests: XCTestCase {

    private let filter = ScanPathFilter(directories: ["/nonexistent-root/a/skills"])

    func testSiblingWithSharedPrefixIsNotCovered() {
        XCTAssertFalse(filter.covers("/nonexistent-root/a/skills2/x/SKILL.md"))
        XCTAssertFalse(filter.admits("/nonexistent-root/a/skills2"))
    }

    func testDescendantsAreCoveredAndAncestorsOnlyAdmitted() {
        XCTAssertTrue(filter.covers("/nonexistent-root/a/skills/x/SKILL.md"))
        XCTAssertTrue(filter.admits("/nonexistent-root/a"))
        XCTAssertFalse(filter.covers("/nonexistent-root/a"))
    }

    func testUnfilteredAdmitsEverything() {
        XCTAssertTrue(ScanPathFilter.all.covers("/anything"))
        XCTAssertTrue(ScanPathFilter.all.admits("/anything"))
    }
}
