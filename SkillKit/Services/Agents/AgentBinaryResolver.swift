import Foundation
import os

/// Locates agent CLI binaries (`claude`, `codex`, …) the way a user's terminal would.
///
/// Resolution order:
/// 1. A per-agent override chosen by the user in Settings (`agentBinaryPath.<agentId>`).
/// 2. The user's login-shell `PATH` (`$SHELL -l -c 'printf %s "$PATH"'`), so version
///    managers such as fnm / mise / volta / bun / pnpm that only export PATH from shell
///    profiles are honoured. Resolved once per process, off the main thread, with a short
///    timeout. If the login shell doesn't expose the binary we also try an interactive
///    login shell (`-l -i`) because many users configure their manager in `.zshrc`.
/// 3. The historical fixed probe list (`~/.local/bin`, Homebrew, `/usr/local/bin`, nvm).
///
/// `launchPATHComponents()` returns the same directories so subprocesses are launched with
/// the PATH the binary was found in (a `claude` shim usually needs `node` next to it).
final class AgentBinaryResolver: @unchecked Sendable {
    static let shared = AgentBinaryResolver()

    private static let logger = Logger(subsystem: "alice.turcanu.com.SkillKit", category: "AgentBinaryResolver")
    private static let shellTimeout: TimeInterval = 5

    private let lock = NSLock()
    /// Login-shell PATH by "interactive" flag. `.some(nil)` means "tried, got nothing".
    private var shellPATHCache: [Bool: String?] = [:]
    private var inFlight: [Bool: Task<String?, Never>] = [:]

    private init() {}

    // MARK: - Override (UserDefaults + security-scoped bookmark)

    static func overrideDefaultsKey(_ id: AgentID) -> String { "agentBinaryPath.\(id.rawValue)" }
    static func overrideBookmarkKey(_ id: AgentID) -> String { "agentBinary.\(id.rawValue)" }

    func overridePath(for id: AgentID) -> String? {
        let value = UserDefaults.standard.string(forKey: Self.overrideDefaultsKey(id))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Stores (or clears, with `nil`) the user-chosen binary. Saves a security-scoped
    /// bookmark so the sandboxed app can keep executing it across launches.
    func setOverride(_ url: URL?, for id: AgentID) {
        let defaults = UserDefaults.standard
        if let url {
            defaults.set(url.path, forKey: Self.overrideDefaultsKey(id))
            SandboxBookmarkManager.saveBookmark(for: url, customKey: Self.overrideBookmarkKey(id))
            Self.logger.info("Binary override for \(id.rawValue): \(url.path)")
        } else {
            defaults.removeObject(forKey: Self.overrideDefaultsKey(id))
            defaults.removeObject(forKey: "bookmark_\(Self.overrideBookmarkKey(id))")
            Self.logger.info("Binary override cleared for \(id.rawValue)")
        }
    }

    /// Starts security-scoped access for an override binary (if one is set and bookmarked).
    /// Returns the URL access was started on; the caller must call
    /// `stopAccessingSecurityScopedResource()` on it once the subprocess has exited.
    func beginAccessingOverride(for id: AgentID) -> URL? {
        guard overridePath(for: id) != nil,
              let data = UserDefaults.standard.data(forKey: "bookmark_\(Self.overrideBookmarkKey(id))") else {
            return nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale {
            SandboxBookmarkManager.saveBookmark(for: url, customKey: Self.overrideBookmarkKey(id))
        }
        return url.startAccessingSecurityScopedResource() ? url : nil
    }

    // MARK: - Resolution

    enum Source: String, Sendable {
        case override = "Chosen manually"
        case loginShell = "Found on login-shell PATH"
        case probe = "Found in a standard location"
    }

    struct Resolution: Sendable {
        let url: URL
        let source: Source
    }

    /// Synchronous, non-blocking best effort: override, then whatever login-shell PATH is
    /// already cached, then the fixed probe list. Never spawns a shell.
    func resolveCached(name: String, agentId: AgentID?, extraPaths: [String] = []) -> Resolution? {
        if let agentId, let path = overridePath(for: agentId) {
            if FileManager.default.isExecutableFile(atPath: path) {
                return Resolution(url: URL(fileURLWithPath: path), source: .override)
            }
            // A dead override should not silently fall through to a different binary:
            // surface it as "not found" so the Settings pane can show the broken path.
            return nil
        }
        for interactive in [false, true] {
            if let path = cachedShellPATH(interactive: interactive),
               let url = Self.find(name, inPATH: path) {
                return Resolution(url: url, source: .loginShell)
            }
        }
        if let url = Self.probe(name, extraPaths: extraPaths) {
            return Resolution(url: url, source: .probe)
        }
        return nil
    }

    /// Full resolution, spawning the login shell if it hasn't been queried yet.
    func resolve(name: String, agentId: AgentID?, extraPaths: [String] = []) async -> Resolution? {
        if let agentId, overridePath(for: agentId) != nil {
            return resolveCached(name: name, agentId: agentId, extraPaths: extraPaths)
        }
        if let path = await shellPATH(interactive: false), let url = Self.find(name, inPATH: path) {
            return Resolution(url: url, source: .loginShell)
        }
        if let path = await shellPATH(interactive: true), let url = Self.find(name, inPATH: path) {
            return Resolution(url: url, source: .loginShell)
        }
        if let url = Self.probe(name, extraPaths: extraPaths) {
            return Resolution(url: url, source: .probe)
        }
        return nil
    }

    /// Warms the login-shell cache. Safe to call repeatedly.
    func warmUp() async {
        _ = await shellPATH(interactive: false)
    }

    /// Whether the login shell has been queried yet (either mode).
    var hasQueriedLoginShell: Bool {
        lock.lock(); defer { lock.unlock() }
        return shellPATHCache[false] != nil
    }

    /// Directories to put on PATH when launching a subprocess: the override's directory,
    /// every login-shell PATH entry we know about, then the classic fallbacks.
    func launchPATHComponents(for agentId: AgentID? = nil) -> [String] {
        var components: [String] = []
        func add(_ p: String) {
            guard !p.isEmpty, !components.contains(p) else { return }
            components.append(p)
        }
        if let agentId, let override = overridePath(for: agentId) {
            add(URL(fileURLWithPath: override).deletingLastPathComponent().path)
        }
        for interactive in [false, true] {
            if let path = cachedShellPATH(interactive: interactive) {
                path.split(separator: ":").map(String.init).forEach(add)
            }
        }
        Self.fallbackDirectories().forEach(add)
        return components
    }

    // MARK: - Login shell

    private func cachedShellPATH(interactive: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        return shellPATHCache[interactive] ?? nil
    }

    private enum QueryState {
        case cached(String?)
        case pending(Task<String?, Never>, owner: Bool)
    }

    private func shellPATH(interactive: Bool) async -> String? {
        switch startOrJoinQuery(interactive: interactive) {
        case .cached(let value):
            return value
        case .pending(let task, let owner):
            let result = await task.value
            if owner { storeShellPATH(result, interactive: interactive) }
            return result
        }
    }

    /// Synchronous critical section: returns the cached value, joins an in-flight query,
    /// or starts one (the caller that starts it is the `owner` responsible for caching).
    private func startOrJoinQuery(interactive: Bool) -> QueryState {
        lock.lock(); defer { lock.unlock() }
        if let cached = shellPATHCache[interactive] {
            return .cached(cached)
        }
        if let task = inFlight[interactive] {
            return .pending(task, owner: false)
        }
        let task = Task.detached(priority: .userInitiated) { () -> String? in
            await Self.queryShellPATH(interactive: interactive)
        }
        inFlight[interactive] = task
        return .pending(task, owner: true)
    }

    private func storeShellPATH(_ value: String?, interactive: Bool) {
        lock.lock(); defer { lock.unlock() }
        shellPATHCache[interactive] = .some(value)
        inFlight[interactive] = nil
    }

    private static let marker = "__SKILLKIT_PATH__"

    /// Dedicated queue for the blocking shell probe. Keeping it off the cooperative pool
    /// means a slow profile can't tie up one of Swift concurrency's few worker threads.
    private static let shellQueue = DispatchQueue(
        label: "alice.turcanu.com.SkillKit.AgentBinaryResolver.shell",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Runs the user's login shell and captures `$PATH`, waiting on a dedicated queue.
    private static func queryShellPATH(interactive: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            shellQueue.async {
                continuation.resume(returning: queryShellPATHBlocking(interactive: interactive))
            }
        }
    }

    /// Runs the user's login shell and captures `$PATH`. Blocking; call off the main thread.
    private static func queryShellPATHBlocking(interactive: Bool) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // Print with a marker so profile chatter (motd, echo in .zshrc) can't confuse us.
        let script = "printf '\\n\(marker)%s\\n' \"$PATH\""
        proc.arguments = interactive ? ["-l", "-i", "-c", script] : ["-l", "-c", script]
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = env["TERM"] ?? "dumb"
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe

        // Signalled from the termination handler instead of polling `isRunning`.
        // Installed before `run()` so an immediate exit can't be missed.
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }

        do {
            try proc.run()
        } catch {
            logger.error("Login shell launch failed (\(shell)): \(error.localizedDescription)")
            return nil
        }

        // Read in the background so a chatty profile can't fill the pipe and block us.
        let readDone = DispatchSemaphore(value: 0)
        var output = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }

        if exited.wait(timeout: .now() + shellTimeout) == .timedOut {
            logger.error("Login shell (\(shell)\(interactive ? " -i" : "")) timed out after \(shellTimeout)s")
            proc.terminate()
            // `output` is still being written by the reader — never read it here.
            return nil
        }
        // Only safe to touch `output` once the reader has finished with it.
        guard readDone.wait(timeout: .now() + 1) == .success else { return nil }

        guard let text = String(data: output, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines).reversed() {
            if let range = line.range(of: marker) {
                let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                logger.info("Login shell PATH (\(interactive ? "interactive" : "login")): \(path)")
                return path.isEmpty ? nil : path
            }
        }
        return nil
    }

    // MARK: - Filesystem helpers

    private static func find(_ name: String, inPATH path: String) -> URL? {
        let fm = FileManager.default
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Fixed probe list: caller-supplied paths, the standard bin dirs, then nvm versions.
    static func probe(_ name: String, extraPaths: [String] = []) -> URL? {
        let fm = FileManager.default
        for path in extraPaths where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        for dir in fallbackDirectories() {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Standard directories plus every nvm node version's bin, newest first.
    static func fallbackDirectories() -> [String] {
        let home = AppPaths.userHomeDirectory
        var dirs = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let fm = FileManager.default
        let nvmDir = "\(home)/.nvm/versions/node"
        if let nodeDirs = try? fm.contentsOfDirectory(atPath: nvmDir) {
            for nodeDir in nodeDirs.sorted().reversed() {
                let binDir = "\(nvmDir)/\(nodeDir)/bin"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: binDir, isDirectory: &isDir), isDir.boolValue {
                    dirs.append(binDir)
                }
            }
        }
        return dirs
    }
}
