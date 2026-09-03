import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

/// Covers the watcher behaviour the incremental scanner depends on. Before
/// these fixes the callback carried no paths and a full rescan ran on every
/// event, which masked the gaps exercised here.
final class FileWatcherTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SkillKitFileWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// The batch must name the directory that actually changed, otherwise the
    /// scanner cannot narrow the rescan and falls back to walking everything.
    func testCallbackReportsTheChangedDirectory() throws {
        // An atomic write emits several directory events, which can arrive in
        // more than one coalesced batch.
        let expectation = expectation(description: "watcher reports the changed directory")
        expectation.assertForOverFulfill = false
        let watchedPath = root.path
        let received = Locked<Set<String>>([])

        let watcher = FileWatcher(coalesceInterval: 0.1) { changed in
            received.withLock { $0.formUnion(changed) }
            if changed.contains(watchedPath) { expectation.fulfill() }
        }
        watcher.watchDirectories([watchedPath])

        try "# New".write(
            to: root.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(received.value.contains(watchedPath))
        watcher.stopAll()
    }

    /// A skill folder is created a moment before its SKILL.md is written. Only
    /// the parent fires for the folder itself, so unless the watcher arms the
    /// new folder the later file write is invisible and the skill never shows
    /// up until a manual rescan or relaunch.
    func testFileWrittenIntoANewlyCreatedSubdirectoryIsObserved() throws {
        let parentEvent = expectation(description: "parent directory reports the new folder")
        parentEvent.assertForOverFulfill = false
        let childEvent = expectation(description: "new folder reports its SKILL.md")
        childEvent.assertForOverFulfill = false
        let newFolder = root.appendingPathComponent("brand-new-skill")

        let watcher = FileWatcher(coalesceInterval: 0.1) { changed in
            if changed.contains(self.root.path) { parentEvent.fulfill() }
            if changed.contains(newFolder.path) { childEvent.fulfill() }
        }
        watcher.watchDirectories([root.path])

        // Step 1: the folder appears, still empty.
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        wait(for: [parentEvent], timeout: 5)

        // Step 2: the file lands afterwards. Only a watch on the new folder can see this.
        try "# Brand New".write(
            to: newFolder.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        wait(for: [childEvent], timeout: 5)
        watcher.stopAll()
    }

    /// Refreshing the explicit watch set must not drop the folders the watcher
    /// armed itself, or the bridge to discovering a new skill is lost.
    func testRefreshingWatchesKeepsSelfArmedSubdirectories() throws {
        let parentEvent = expectation(description: "parent reports the new folder")
        parentEvent.assertForOverFulfill = false
        let newFolder = root.appendingPathComponent("auto-armed")

        let watcher = FileWatcher(coalesceInterval: 0.1) { changed in
            if changed.contains(self.root.path) { parentEvent.fulfill() }
        }
        watcher.watchDirectories([root.path])

        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        wait(for: [parentEvent], timeout: 5)
        XCTAssertTrue(watcher.watchedPaths.contains(newFolder.path), "expected the new folder to be armed")

        // The library changed, so the app re-asserts its explicit watch list.
        watcher.watchDirectories([root.path])
        XCTAssertTrue(
            watcher.watchedPaths.contains(newFolder.path),
            "a refresh must not drop a self-armed folder before its skill is discovered"
        )
        watcher.stopAll()
    }

    func testStopAllReleasesEveryWatch() throws {
        let watcher = FileWatcher(coalesceInterval: 0.1) { _ in }
        watcher.watchDirectories([root.path])
        XCTAssertFalse(watcher.watchedPaths.isEmpty)

        watcher.stopAll()
        XCTAssertTrue(watcher.watchedPaths.isEmpty)
    }
}

/// Minimal mutex so the watcher's background callbacks can record into shared
/// state without tripping the strict-concurrency checker.
private final class Locked<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withLock(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
