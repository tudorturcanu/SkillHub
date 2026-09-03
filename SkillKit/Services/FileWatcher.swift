import Foundation
import os

/// Watches a set of directories (or files) with one kqueue-backed
/// `DispatchSource` each and reports *which* watched paths changed.
///
/// Events are coalesced: every path that fires within `coalesceInterval` of
/// the first one is collected into a single callback on the main queue, so a
/// burst (editor save → temp file → rename) becomes one incremental rescan.
///
/// `watchDirectories(_:)` diffs against the current set — unchanged paths keep
/// their descriptors, so callers can re-invoke it freely when the library
/// changes instead of tearing everything down.
///
/// A watched file that is replaced atomically (write to temp + rename, which
/// is what `String.write(toFile:atomically:)` does) delivers `.delete` /
/// `.rename` for the old inode; the watch is re-armed on the new file shortly
/// after so later saves are still observed.
final class FileWatcher {
    typealias ChangeHandler = (_ changedPaths: Set<String>) -> Void

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private let callback: ChangeHandler
    private let queue = DispatchQueue(label: "alice.turcanu.com.SkillKit.filewatcher", qos: .utility)
    private let coalesceInterval: TimeInterval

    /// Subdirectories we armed ourselves after a parent fired (see
    /// `armNewSubdirectoriesLocked`). Kept apart from the caller's set so a
    /// refresh of the explicit watches doesn't drop them before the skill they
    /// belong to has been discovered. In insertion order, so the oldest can be
    /// retired once the bridge is no longer worth a descriptor.
    private var autoWatchedPaths: [String] = []
    private var pendingPaths = Set<String>()
    private var flushWorkItem: DispatchWorkItem?

    /// - Parameters:
    ///   - coalesceInterval: how long to wait after the first event before
    ///     delivering the batch. Default 300 ms.
    ///   - callback: invoked on the main queue with every watched path that
    ///     changed during the window.
    init(coalesceInterval: TimeInterval = 0.3, callback: @escaping ChangeHandler) {
        self.coalesceInterval = coalesceInterval
        self.callback = callback
    }

    /// Paths currently being watched.
    var watchedPaths: Set<String> {
        queue.sync { Set(sources.keys) }
    }

    /// Makes the watched set equal to `paths`: opens new ones, closes dropped
    /// ones, leaves the rest alone. Non-existent paths are skipped.
    func watchDirectories(_ paths: [String]) {
        let wanted = Set(paths.filter { FileManager.default.fileExists(atPath: $0) })
        queue.sync {
            let current = Set(sources.keys)
            for path in current.subtracting(wanted).subtracting(Set(autoWatchedPaths)) {
                cancelSourceLocked(for: path)
            }
            // An explicitly requested path is no longer just an auto-watch.
            autoWatchedPaths.removeAll { wanted.contains($0) }
            for path in wanted.subtracting(current).sorted() {
                openSourceLocked(for: path)
            }
        }
    }

    /// Adds paths without touching existing watches.
    func addDirectories(_ paths: [String]) {
        let wanted = paths.filter { FileManager.default.fileExists(atPath: $0) }
        queue.sync {
            for path in wanted where sources[path] == nil {
                openSourceLocked(for: path)
            }
        }
    }

    func stopAll() {
        queue.sync {
            flushWorkItem?.cancel()
            flushWorkItem = nil
            pendingPaths.removeAll()
            for path in Array(sources.keys) {
                cancelSourceLocked(for: path)
            }
            autoWatchedPaths.removeAll()
        }
    }

    // MARK: - Internals (call on `queue`)

    private func openSourceLocked(for path: String) {
        SandboxBookmarkManager.resolveAndAccess(path: path) { url in
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else {
                AppLogger.fileIO.warning("Failed to watch: \(url.path)")
                return
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .extend],
                queue: queue
            )

            source.setEventHandler { [weak self, weak source] in
                guard let self else { return }
                let flags = source?.data ?? []
                AppLogger.fileIO.debug("File change detected: \(path)")
                self.recordChangeLocked(path)
                if flags.contains(.delete) || flags.contains(.rename) {
                    self.rearmLocked(path)
                }
            }

            source.setCancelHandler {
                close(fd)
            }

            source.resume()
            sources[path] = source
        }
    }

    private func cancelSourceLocked(for path: String) {
        autoWatchedPaths.removeAll { $0 == path }
        guard let source = sources.removeValue(forKey: path) else { return }
        source.cancel()
    }

    /// The inode we were watching is gone (atomic replace or real delete).
    /// Drop the dead descriptor and, if the path still exists a moment later,
    /// watch the new inode.
    private func rearmLocked(_ path: String) {
        cancelSourceLocked(for: path)
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.sources[path] == nil else { return }
            guard FileManager.default.fileExists(atPath: path) else { return }
            self.openSourceLocked(for: path)
        }
    }

    private func recordChangeLocked(_ path: String) {
        pendingPaths.insert(path)
        armNewSubdirectoriesLocked(of: path)
        guard flushWorkItem == nil else { return } // window already open

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.pendingPaths
            self.pendingPaths.removeAll()
            self.flushWorkItem = nil
            guard !batch.isEmpty else { return }
            AppLogger.fileIO.notice("Triggering rescan for \(batch.count) changed path(s)")
            DispatchQueue.main.async {
                self.callback(batch)
            }
        }
        flushWorkItem = work
        queue.asyncAfter(deadline: .now() + coalesceInterval, execute: work)
    }

    /// A new skill folder is usually created a moment before its `SKILL.md`
    /// is written. Only the parent fires for the folder creation, so unless we
    /// start watching the folder itself the later file write is invisible and
    /// the skill never appears. Arm any immediate subdirectory we aren't
    /// watching yet, and queue it for this batch in case the file already
    /// landed between the parent's event and now.
    private func armNewSubdirectoriesLocked(of path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        guard entries.count <= Self.maxAutoWatchedChildren else { return } // don't crawl huge trees

        for entry in entries where !entry.hasPrefix(".") {
            let child = (path as NSString).appendingPathComponent(entry)
            guard sources[child] == nil else { continue }
            var childIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child, isDirectory: &childIsDirectory),
                  childIsDirectory.boolValue else { continue }
            openSourceLocked(for: child)
            autoWatchedPaths.append(child)
            pendingPaths.insert(child)
        }

        retireOldestAutoWatchesLocked()
    }

    /// These watches exist only to bridge the gap between a skill folder being
    /// created and its file landing. One that never became a real skill (an
    /// empty folder, a build directory) would otherwise hold a descriptor for
    /// the life of the session, so the oldest are retired past a cap.
    private func retireOldestAutoWatchesLocked() {
        guard autoWatchedPaths.count > Self.maxAutoWatchedPaths else { return }
        let excess = autoWatchedPaths.count - Self.maxAutoWatchedPaths
        for path in autoWatchedPaths.prefix(excess) {
            cancelSourceLocked(for: path)
        }
    }

    /// Upper bound on directory entries we'll auto-watch, so pointing the app
    /// at a large tree doesn't open thousands of descriptors.
    private static let maxAutoWatchedChildren = 256

    /// Upper bound on how many self-armed watches are held at once.
    private static let maxAutoWatchedPaths = 256

    deinit {
        // Cancel directly; `queue.sync` from deinit could deadlock if the
        // last reference is dropped on the queue itself.
        flushWorkItem?.cancel()
        for source in sources.values {
            source.cancel()
        }
    }
}
