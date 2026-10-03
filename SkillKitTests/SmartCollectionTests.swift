import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class SmartCollectionTests: XCTestCase {
    func testMembershipReevaluatesAfterChanges() {
        let skill = Skill(filePath: "/tmp/test/SKILL.md", toolSource: .codex, name: "Review", isGlobal: false)
        let collection = SmartCollection(name: "Project favorites", query: "tool:codex is:project is:favorite")
        XCTAssertTrue(collection.matchingSkills(in: [skill]).isEmpty)
        skill.isFavorite = true
        XCTAssertEqual(collection.matchingSkills(in: [skill]).count, 1)
        skill.isGlobal = true
        XCTAssertTrue(collection.matchingSkills(in: [skill]).isEmpty)
    }

    func testSavedScopeAndNegation() {
        let skill = Skill(filePath: "/tmp/test/SKILL.md", toolSource: .codex, name: "Review", content: "release checklist")
        var collection = SmartCollection(name: "Release", query: "\"release checklist\" -draft", scope: .title)
        XCTAssertTrue(collection.matchingSkills(in: [skill]).isEmpty)
        collection.scope = .content
        XCTAssertEqual(collection.matchingSkills(in: [skill]).count, 1)
        skill.content += " draft"
        XCTAssertTrue(collection.matchingSkills(in: [skill]).isEmpty)
    }

    func testPersistenceAndSelectionRoundTrip() throws {
        let suite = "SmartCollectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let collection = SmartCollection(name: "Project rules", query: "is:project is:rule", scope: .content)
        SmartCollectionStore.save([collection], defaults: defaults)
        XCTAssertEqual(SmartCollectionStore.load(defaults: defaults), [collection])
        let filter = SidebarFilter.smartCollection(collection.id)
        XCTAssertEqual(SidebarFilter(persistedValue: filter.persistedValue), filter)
        XCTAssertNil(SidebarFilter(persistedValue: "smartCollection:invalid"))
        SmartCollectionStore.save([], defaults: defaults)
        XCTAssertTrue(SmartCollectionStore.load(defaults: defaults).isEmpty)
    }
}
