import Foundation

// MARK: - Permission flow

/// One option presented to the user when an agent asks to use a tool.
/// `kind` is a stable string used by the UI to color the button (e.g. `allow_once`,
/// `allow_always`, `reject_once`, `reject_always`).
struct PermissionOption: Codable, Sendable, Identifiable {
    let kind: String
    let name: String
    let optionId: String

    var id: String { optionId }
}

/// Optional diff payload attached to a permission ask. When present the UI shows the
/// before/after content side-by-side so the user can review the proposed change before
/// clicking Allow. Required for any tool that mutates disk (Write / Edit / MultiEdit).
struct PermissionDiffPreview: Sendable {
    let path: String
    let originalText: String?
    let proposedText: String
    let existedBefore: Bool
}

/// Wraps a parked permission ask so the UI can resume it once the user clicks.
struct PermissionRequest: Identifiable, @unchecked Sendable {
    let id: UUID = UUID()
    let title: String
    let options: [PermissionOption]
    let diffPreview: PermissionDiffPreview?
    let continuation: CheckedContinuation<PermissionResponse, Error>
}

/// Result of a permission ask. `cancelled == true` means the user dismissed without choosing
/// a specific option; otherwise `optionId` identifies the chosen option.
struct PermissionResponse: Sendable {
    let optionId: String?
    let cancelled: Bool

    static func choice(_ optionId: String) -> PermissionResponse {
        PermissionResponse(optionId: optionId, cancelled: false)
    }
    static var cancelled: PermissionResponse {
        PermissionResponse(optionId: nil, cancelled: true)
    }
}

// MARK: - Activity feed

/// One step in the agent's chronological activity feed for a turn. The UI shows these
/// to give the user real-time visibility into what the agent is doing — Claude
/// generating long tool inputs can take minutes; without an activity feed it looks like
/// the app is frozen.
struct AgentActivity: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case thinking
        case toolCall(name: String)
        case toolInputDraft(name: String, charCount: Int)
        case toolResult(name: String)
        case info
    }
    enum Status: Sendable, Equatable {
        case running
        case done       // tool ran successfully (read-only / non-mutating)
        case applied    // mutating tool (Write/Edit/MultiEdit) successfully changed disk
        case failed
    }

    /// Optional rich payload so the UI can show what each step actually did when
    /// expanded. For Write/Edit this carries the diff; for Read/Bash the raw input/output.
    struct Payload: Sendable, Equatable {
        var filePath: String?
        var originalText: String?
        var proposedText: String?
        var existedBefore: Bool?
        var rawInput: String?      // pretty-printed JSON of tool input
        var resultText: String?    // tool_result content (truncated)
    }

    let id: UUID
    var kind: Kind
    var title: String
    var detail: String?
    var startedAt: Date
    var status: Status
    var payload: Payload

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        detail: String? = nil,
        startedAt: Date = Date(),
        status: Status = .running,
        payload: Payload = Payload()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.startedAt = startedAt
        self.status = status
        self.payload = payload
    }
}

// MARK: - Pending writes

/// A file write proposed by the agent. Surfaced in the chat as a diff for the user to
/// accept or reject. Both Claude (`Write` / `Edit` / `MultiEdit`) and Codex
/// (`item/fileChange/*`) populate this.
struct PendingWrite: Sendable {
    let path: String
    let content: String
    let originalText: String?
    let originalData: Data?
    let existedBefore: Bool
    /// True when the agent itself performed the disk write (the case for direct CLI
    /// agents). On reject the UI restores from the captured snapshot.
    let agentDidWrite: Bool

    init(
        path: String,
        content: String,
        originalText: String?,
        originalData: Data?,
        existedBefore: Bool,
        agentDidWrite: Bool = false
    ) {
        self.path = path
        self.content = content
        self.originalText = originalText
        self.originalData = originalData
        self.existedBefore = existedBefore
        self.agentDidWrite = agentDidWrite
    }
}

// MARK: - Conversation history

/// One completed turn of the current compose session, handed back to the agent so a
/// one-shot CLI invocation still "remembers" what was said earlier. Assistant turns carry
/// the summary text shown in chat (never the full proposed file body).
struct ConversationTurn: Sendable, Equatable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    let text: String
}

// MARK: - Errors

enum AgentError: Error, LocalizedError {
    case noSession
    case binaryNotInstalled(toolName: String, installURL: URL)
    case agentTooOld(toolName: String, found: String, minimum: String)
    case launchFailed(String)
    case processExitedDuringConnect(String)
    case connectTimedOut(stage: String)
    /// The CLI ran but exited non-zero. `detail` is already cleaned for display.
    case cliFailed(toolName: String, exitCode: Int32, detail: String)
    case notAuthenticated(toolName: String, hint: String)

    var errorDescription: String? {
        switch self {
        case .noSession:
            "No active agent session."
        case .binaryNotInstalled(let name, _):
            "\(name) isn't installed."
        case .agentTooOld(let name, let found, let minimum):
            "\(name) v\(found) is too old. Update to v\(minimum) or newer."
        case .launchFailed(let detail):
            "Failed to launch agent: \(detail)"
        case .processExitedDuringConnect(let detail):
            "Agent exited before initializing.\n\n\(detail)"
        case .connectTimedOut(let stage):
            "Connection timed out (\(stage))."
        case .cliFailed(let name, let code, let detail):
            detail.isEmpty
                ? "\(name) exited with code \(code)."
                : "\(name) exited with code \(code).\n\n\(detail)"
        case .notAuthenticated(let name, let hint):
            "\(name) isn't signed in. \(hint)"
        }
    }
}

/// Turns raw CLI stderr into something a person can read in the chat panel.
enum AgentErrorText {
    /// Strips ANSI escapes, drops progress/noise lines and keeps the tail of what's left.
    static func readable(stderr: String, maxLines: Int = 6, maxChars: Int = 600) -> String {
        let stripped = stripANSI(stderr)
        let lines = stripped
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isNoise($0) }
        let tail = lines.suffix(maxLines).joined(separator: "\n")
        if tail.count > maxChars {
            return "…" + tail.suffix(maxChars)
        }
        return tail
    }

    /// Maps well-known failure modes to a friendlier error. Returns nil when there is no
    /// better description than the raw exit.
    static func classify(toolName: String, stderr: String, stdout: String = "") -> AgentError? {
        let haystack = (stderr + "\n" + stdout).lowercased()
        let authMarkers = [
            "not logged in", "please run /login", "please login", "not authenticated",
            "invalid api key", "authentication_error", "authentication failed",
            "run `codex login`", "codex login", "oauth token", "401",
        ]
        if authMarkers.contains(where: haystack.contains) {
            let hint = toolName.hasPrefix("Claude")
                ? "Run `claude` in Terminal and sign in, then try again."
                : "Run `codex login` in Terminal, then try again."
            return .notAuthenticated(toolName: toolName, hint: hint)
        }
        return nil
    }

    static func stripANSI(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#) else { return s }
        let ns = s as NSString
        return regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    private static func isNoise(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.hasPrefix("reading additional input from stdin")
            || l.hasPrefix("[debug]")
            || l.hasPrefix("npm warn")
            || l.hasPrefix("(node:")
    }
}

// MARK: - Helpers

enum AgentDataDecoding {
    /// Best-effort decode of bytes to a Swift String. Tries UTF-8 then UTF-16.
    static func text(from data: Data?) -> String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
    }
}
