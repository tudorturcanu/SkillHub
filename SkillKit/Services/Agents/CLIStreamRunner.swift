import Foundation

/// Runs a CLI subprocess, delivering each stdout line to the caller *as it arrives* (on
/// the main actor) while stderr is collected in the background. Used by the Claude and
/// Codex transports to consume NDJSON / JSONL event streams incrementally so the chat
/// panel can show text and tool activity before the process exits.
@MainActor
final class CLIStreamRunner {
    struct Outcome: Sendable {
        let exitCode: Int32
        /// A bounded transcript of stdout for diagnostics: the head of the stream, an
        /// elision marker, then the tail. Never the whole stream — with
        /// `--include-partial-messages` a single turn emits an NDJSON line per token, and
        /// only logging and error previews read this. The transports build the model's
        /// reply from the streamed events themselves (`StreamState`), not from here.
        let stdout: String
        /// Everything the process wrote to stderr.
        let stderr: String
        /// True when the process was terminated via `terminate()` (or task cancellation).
        let wasTerminated: Bool
    }

    private let process = Process()
    private var terminated = false

    init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        // Never inherit the app's stdin — CLIs like `codex` otherwise wait on it.
        process.standardInput = FileHandle.nullDevice
    }

    var isRunning: Bool { process.isRunning }

    /// Terminates the child. Safe to call more than once or before/after exit.
    func terminate() {
        terminated = true
        if process.isRunning {
            process.terminate()
        }
    }

    /// Launches the process and streams stdout lines to `onLine`. Returns once the
    /// process has exited and both pipes are drained. Throws `AgentError.launchFailed`
    /// if the executable could not be started.
    func run(onLine: @MainActor @escaping (String) -> Void) async throws -> Outcome {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AgentError.launchFailed(error.localizedDescription)
        }

        let proc = process
        // Drain stderr off the main actor so a chatty child can't block on a full pipe.
        let stderrTask = Task.detached(priority: .utility) { () -> Data in
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        var stdoutLog = BoundedTranscript()
        do {
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                stdoutLog.append(line)
                onLine(line)
                if Task.isCancelled { terminate() }
            }
        } catch {
            // Reading fails only if the handle was closed underneath us — treat as EOF.
            agentLog.debug("CLIStreamRunner: stdout read ended with \(error.localizedDescription)")
        }

        await Task.detached(priority: .utility) {
            proc.waitUntilExit()
        }.value

        let stderrData = await stderrTask.value
        return Outcome(
            exitCode: proc.terminationStatus,
            stdout: stdoutLog.joined(),
            stderr: AgentDataDecoding.text(from: stderrData) ?? "",
            wasTerminated: terminated || Task.isCancelled
        )
    }
}

/// Retains a fixed-size sample of a line stream: the first `maxHeadBytes` worth of lines
/// (callers quote the opening bytes when a reply can't be parsed) plus a rolling tail
/// (where a failure's cause usually is). Everything in between is counted and dropped, so
/// memory stays bounded no matter how long the turn runs.
private struct BoundedTranscript {
    private static let maxHeadBytes = 8 * 1024
    private static let maxTailLines = 100
    private static let maxTailBytes = 64 * 1024

    private var head: [String] = []
    private var headBytes = 0
    private var tail: [String] = []
    private var tailBytes = 0
    private var elidedLines = 0

    mutating func append(_ line: String) {
        let cost = line.utf8.count + 1
        if tail.isEmpty, headBytes + cost <= Self.maxHeadBytes {
            head.append(line)
            headBytes += cost
            return
        }
        tail.append(line)
        tailBytes += cost
        while tail.count > Self.maxTailLines || (tailBytes > Self.maxTailBytes && tail.count > 1) {
            tailBytes -= tail.removeFirst().utf8.count + 1
            elidedLines += 1
        }
    }

    func joined() -> String {
        var parts = head
        if elidedLines > 0 {
            parts.append("… \(elidedLines) line(s) elided …")
        }
        parts.append(contentsOf: tail)
        return parts.joined(separator: "\n")
    }
}

/// Minimal helpers for poking at loosely-typed JSON event payloads.
enum JSONEvent {
    static func parse(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// One-line summary of a tool's input for the activity feed / thinking view.
    static func summarize(_ value: Any?, limit: Int = 120) -> String {
        guard let value else { return "" }
        var text: String
        if let dict = value as? [String: Any] {
            // Prefer the most meaningful field a tool input tends to carry.
            let preferred = ["command", "file_path", "path", "pattern", "query", "url", "prompt", "description"]
            if let key = preferred.first(where: { dict[$0] != nil }), let v = dict[key] {
                text = "\(key): \(v)"
            } else if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                      let s = String(data: data, encoding: .utf8) {
                text = s
            } else {
                text = "\(dict)"
            }
        } else if let s = value as? String {
            text = s
        } else {
            text = "\(value)"
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
        if text.count > limit {
            text = String(text.prefix(limit)) + "…"
        }
        return text
    }
}
