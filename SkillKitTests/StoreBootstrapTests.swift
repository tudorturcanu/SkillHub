import XCTest
import SwiftData
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

/// A corrupt or unmigratable store used to hit `fatalError`, so the app
/// crashed on every launch with no way back in. The library is Markdown on
/// disk, so rebuilding the index is always preferable to refusing to start.
final class StoreBootstrapTests: XCTestCase {

    private var directory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SkillKitStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Never operate on the real library index.
        StoreBootstrap.containerDirectoryOverride = directory
        storeURL = directory.appendingPathComponent("SkillKit.store")
    }

    override func tearDownWithError() throws {
        StoreBootstrap.containerDirectoryOverride = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    /// Bytes that are definitively not a SQLite database.
    @discardableResult
    private func corruptTheStore() throws -> Data {
        let garbage = Data("this is not a database".utf8)
        try garbage.write(to: storeURL)
        return garbage
    }

    func testAnUnreadableStoreIsSetAsideRatherThanCrashing() throws {
        let garbage = try corruptTheStore()

        let schema = Schema(versionedSchema: SchemaV1.self)
        _ = try StoreBootstrap.makeContainer(schema: schema)

        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("SkillKit-unreadable-") && $0.hasSuffix(".store") }
        XCTAssertEqual(quarantined.count, 1, "the unreadable store should have been kept, exactly once")

        let kept = try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(quarantined.first)))
        XCTAssertEqual(kept, garbage, "the original bytes must stay recoverable")
    }

    func testTheRebuiltStoreIsUsable() throws {
        try corruptTheStore()

        let schema = Schema(versionedSchema: SchemaV1.self)
        let container = try StoreBootstrap.makeContainer(schema: schema)

        // Recovery is only worth anything if the fresh store actually works.
        let context = ModelContext(container)
        context.insert(
            Skill(
                filePath: "/tmp/recovered/SKILL.md",
                toolSource: .claude,
                isDirectory: true,
                name: "Recovered",
                skillDescription: "",
                content: "body",
                frontmatter: [:],
                fileModifiedDate: .now,
                fileSize: 4,
                isGlobal: true,
                resolvedPath: "/tmp/recovered/SKILL.md",
                kind: .skill
            )
        )
        XCTAssertNoThrow(try context.save())

        let fetched = try context.fetch(FetchDescriptor<Skill>())
        XCTAssertTrue(fetched.contains { $0.name == "Recovered" })
    }

    /// Two failures inside the same second must not let the second one delete
    /// the first backup — that copy may hold the user's only collections.
    func testASecondRecoveryDoesNotDestroyTheFirstBackup() throws {
        let schema = Schema(versionedSchema: SchemaV1.self)

        try corruptTheStore()
        _ = try StoreBootstrap.makeContainer(schema: schema)
        let afterFirst = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("SkillKit-unreadable-") && $0.hasSuffix(".store") }
        XCTAssertEqual(afterFirst.count, 1)

        let firstBackup = directory.appendingPathComponent(try XCTUnwrap(afterFirst.first))
        let firstBytes = try Data(contentsOf: firstBackup)

        // Immediately corrupt and recover again, within the same second.
        try Data("a different corruption".utf8).write(to: storeURL)
        _ = try StoreBootstrap.makeContainer(schema: schema)

        let afterSecond = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("SkillKit-unreadable-") && $0.hasSuffix(".store") }
        XCTAssertEqual(afterSecond.count, 2, "the earlier backup must still be there")
        XCTAssertEqual(
            try Data(contentsOf: firstBackup),
            firstBytes,
            "the first backup must not be overwritten by the second recovery"
        )
    }

    func testAHealthyStoreIsOpenedInPlaceAndNotQuarantined() throws {
        let schema = Schema(versionedSchema: SchemaV1.self)
        _ = try StoreBootstrap.makeContainer(schema: schema)

        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("SkillKit-unreadable-") }
        XCTAssertTrue(quarantined.isEmpty, "a healthy store must never be set aside")
    }
}
