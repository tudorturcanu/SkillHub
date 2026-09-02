import Foundation
import Observation

/// Transport for Claude Code. Each `prompt()` is a single
/// `claude -p --output-format stream-json --verbose --include-partial-messages` invocation:
/// send the system prompt + current file content + user request, consume the NDJSON event
/// stream as it arrives (text deltas → `responseText`, thinking / tool activity →
/// `thoughtText`), then parse the final reply for a fenced code block that becomes the
/// proposed new file content — a `PendingWrite` the existing diff-review UI gates.
///
/// Conversation memory: the `system/init` and `result` events carry a `session_id`, which
/// we pass back as `--resume <id>` on the next turn so Claude keeps its own context. If
/// resuming fails (session expired, config changed) we retry once with the prior turns
/// replayed inside the prompt.
///
/// SkillKit owns the disk write — Claude never touches the file (`--tools ""`).
@Observable
@MainActor
final class ClaudeCLIAgent: AgentSession {

    // MARK: - AgentSession state

    var responseText: String = ""
    var thoughtText: String = ""
    var currentActivity: String? = nil
    var pendingWrites: [PendingWrite] = []
    var deferredContent: [String: String] = [:]
    private(set) var pendingPermissionRequest: PermissionRequest? = nil
    private(set) var isConnected: Bool = false
    private(set) var isConnecting: Bool = false
    private(set) var isProcessing: Bool = false
    private(set) var turnStartedAt: Date? = nil
    private(set) var activities: [AgentActivity] = []
    private(set) var lastError: String? = nil
    var isBypassMode: Bool = false  // unused in one-shot mode
    var hasNativeSession: Bool { sessionId != nil }

    // MARK: - Private

    /// Oldest Claude Code release we drive. `--output-format stream-json` with
    /// `--include-partial-messages`, `--settings` and `--tools` all exist from the 2.0 line
    /// on; older 1.x builds reject one of them with "unknown option", which is far less
    /// helpful than a version error.
    static let minimumVersion = (major: 2, minor: 0, patch: 0)

    private var workingDirectory: URL?
    private var sessionSystemPrompt: String?
    private var binaryURL: URL?
    private var scopedAccessURL: URL?
    private var runner: CLIStreamRunner?
    private var connectTask: Task<Void, Never>?
    private var promptWasCancelled = false
    /// Claude Code session to resume on the next turn.
    private var sessionId: String?
    /// Whether the resolved binary's version has already been verified this connection.
    private var versionVerified = false

    // MARK: - Lifecycle

    func startConnect(workingDirectory: URL, systemPrompt: String?) {
        self.workingDirectory = workingDirectory
        self.sessionSystemPrompt = systemPrompt
        self.lastError = nil
        guard !isConnected, !isConnecting else { return }
        isConnecting = true
        connectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isConnecting = false }
            guard let resolution = await ToolSource.claude.resolveCLIBinary() else {
                self.lastError = AgentError.binaryNotInstalled(
                    toolName: "Claude Code",
                    installURL: AgentID.claude.installURL
                ).localizedDescription
                return
            }
            if Task.isCancelled { return }
            self.binaryURL = resolution.url
            if !self.versionVerified {
                if let v = await ToolSource.claude.cliVersion(binary: resolution.url) {
                    let min = Self.minimumVersion
                    if (v.major, v.minor, v.patch) < (min.major, min.minor, min.patch) {
                        self.lastError = AgentError.agentTooOld(
                            toolName: "Claude Code",
                            found: "\(v.major).\(v.minor).\(v.patch)",
                            minimum: "\(min.major).\(min.minor).\(min.patch)"
                        ).localizedDescription
                        return
                    }
                    agentLog.info("Claude Code v\(v.major).\(v.minor).\(v.patch) at \(resolution.url.path) (\(resolution.source.rawValue))")
                } else {
                    // `--version` failing isn't fatal (some shims print nothing) — try to run anyway.
                    agentLog.info("Claude Code at \(resolution.url.path): version check inconclusive")
                }
                self.versionVerified = true
            }
            if Task.isCancelled { return }
            self.isConnected = true
        }
    }

    func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        runner?.terminate()
        runner = nil
        if let req = pendingPermissionRequest {
            pendingPermissionRequest = nil
            req.continuation.resume(returning: .cancelled)
        }
        isConnected = false
        isConnecting = false
        isProcessing = false
        turnStartedAt = nil
        responseText = ""
        thoughtText = ""
        currentActivity = nil
        activities = []
        pendingWrites = []
        deferredContent = [:]
        lastError = nil
        workingDirectory = nil
        sessionSystemPrompt = nil
        sessionId = nil
        versionVerified = false
        releaseScopedAccess()
    }

    func resetContext() {
        sessionId = nil
    }

    // MARK: - Per-turn

    func prompt(_ text: String, history: [ConversationTurn]) async throws {
        guard isConnected, let bin = binaryURL ?? ToolSource.claude.cliBinaryURL,
              let wd = workingDirectory else {
            throw AgentError.noSession
        }

        responseText = ""
        thoughtText = ""
        pendingWrites = []
        currentActivity = nil
        activities = []
        turnStartedAt = Date()
        isProcessing = true
        promptWasCancelled = false

        let activityId = UUID()
        activities.append(AgentActivity(
            id: activityId,
            kind: .thinking,
            title: "Thinking with Claude…",
            status: .running
        ))
        currentActivity = "Thinking with Claude…"

        defer {
            isProcessing = false
            turnStartedAt = nil
            currentActivity = nil
        }

        let (filePath, fileContent) = primaryFile()
        let systemPrompt = sessionSystemPrompt ?? OneShotPrompts.defaultSystemPrompt(filePath: filePath)

        do {
            var result: String
            if let resume = sessionId {
                // Native continuation: Claude already has the earlier turns.
                let message = OneShotPrompts.userMessage(userRequest: text, filePath: filePath, fileContent: fileContent)
                do {
                    result = try await runClaudeStreaming(
                        bin: bin, workingDir: wd, systemPrompt: systemPrompt,
                        userMessage: message, resumeSessionId: resume
                    )
                } catch let error as AgentError where Self.looksLikeResumeFailure(error) {
                    agentLog.info("Claude: --resume \(resume) failed, retrying with replayed history")
                    sessionId = nil
                    responseText = ""
                    thoughtText = ""
                    let replay = OneShotPrompts.userMessage(
                        userRequest: text, filePath: filePath, fileContent: fileContent, history: history
                    )
                    result = try await runClaudeStreaming(
                        bin: bin, workingDir: wd, systemPrompt: systemPrompt,
                        userMessage: replay, resumeSessionId: nil
                    )
                }
            } else {
                let message = OneShotPrompts.userMessage(
                    userRequest: text, filePath: filePath, fileContent: fileContent, history: history
                )
                result = try await runClaudeStreaming(
                    bin: bin, workingDir: wd, systemPrompt: systemPrompt,
                    userMessage: message, resumeSessionId: nil
                )
            }

            let parsed = OneShotResponseParser.parse(result, originalContent: fileContent)
            responseText = parsed.summary

            guard let newContent = parsed.newContent,
                  let filePath, let fileContent,
                  newContent != fileContent else {
                if responseText.isEmpty {
                    responseText = result.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let i = activities.firstIndex(where: { $0.id == activityId }) {
                    activities[i].status = .done
                    activities[i].title = "Replied"
                }
                return
            }

            let resolvedPath = URL(fileURLWithPath: filePath).resolvingSymlinksInPath().path
            pendingWrites.append(PendingWrite(
                path: filePath,
                content: newContent,
                originalText: fileContent,
                originalData: fileContent.data(using: .utf8),
                existedBefore: FileManager.default.fileExists(atPath: resolvedPath),
                agentDidWrite: false
            ))

            if let i = activities.firstIndex(where: { $0.id == activityId }) {
                activities[i].status = .done
                activities[i].title = "Proposed edit ready"
            }
        } catch is CancellationError {
            if let i = activities.firstIndex(where: { $0.id == activityId }) {
                activities[i].status = .failed
                activities[i].title = "Cancelled"
            }
            throw CancellationError()
        } catch {
            if let i = activities.firstIndex(where: { $0.id == activityId }) {
                activities[i].status = .failed
                activities[i].title = "Failed"
                activities[i].detail = error.localizedDescription
            }
            throw error
        }
    }

    func cancelPrompt() {
        promptWasCancelled = true
        runner?.terminate()
    }

    // MARK: - Permissions / writes (mostly no-ops in one-shot mode)

    func respondToPermission(optionId: String?) {
        guard let req = pendingPermissionRequest else { return }
        pendingPermissionRequest = nil
        if let id = optionId {
            req.continuation.resume(returning: .choice(id))
        } else {
            req.continuation.resume(returning: .cancelled)
        }
    }

    func clearPendingWrites() {
        pendingWrites = []
        deferredContent = [:]
    }

    func primeDeferredContent(for path: String, content: String) {
        // Single-file flows store both the literal and resolved-symlink path so callers
        // can look up by either. ComposePanel only ever primes the file currently in
        // the editor, so primaryFile() picks it up reliably.
        deferredContent[path] = content
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolved != path { deferredContent[resolved] = content }
    }

    func conversationalText(from text: String) -> String { text }

    // MARK: - Internals

    private func primaryFile() -> (path: String?, content: String?) {
        if let entry = deferredContent.first {
            return (entry.key, entry.value)
        }
        return (nil, nil)
    }

    private func releaseScopedAccess() {
        scopedAccessURL?.stopAccessingSecurityScopedResource()
        scopedAccessURL = nil
    }

    private static func looksLikeResumeFailure(_ error: AgentError) -> Bool {
        guard case .cliFailed(_, _, let detail) = error else { return false }
        let l = detail.lowercased()
        return l.contains("session") || l.contains("conversation") || l.contains("resume")
    }

    /// Per-turn streaming state for the NDJSON parser.
    @MainActor
    private final class StreamState {
        /// Text of assistant messages that have completed (joined with blank lines).
        var completedText = ""
        /// Text of the assistant message currently streaming via deltas.
        var currentText = ""
        var currentHadDelta = false
        var finalResult: String?
        var resultIsError = false
        var sessionId: String?
        var sawResult = false
        /// Tool-use activity IDs by tool_use block id, so results can flip their status.
        var toolActivities: [String: UUID] = [:]
    }

    private func runClaudeStreaming(
        bin: URL,
        workingDir: URL,
        systemPrompt: String,
        userMessage: String,
        resumeSessionId: String?
    ) async throws -> String {
        // `--settings` overrides ~/.claude/settings.json for THIS session only. We
        // force effortLevel="low" so the user's global "high" doesn't make every SkillKit
        // turn burn 5+ minutes on extended thinking for trivial markdown edits. We
        // skip merging the user's hooks/plugins because they'd add overhead for short
        // edit-style turns (the user's terminal claude is unaffected).
        let sessionSettings = #"{"effortLevel":"low","permissions":{"dangerouslySkipPermissions":false},"includeCoAuthoredBy":false}"#
        // Do NOT pass `--add-dir` — it's variadic and silently consumes the positional
        // prompt arg that follows. `--tools ""` disables tool use so Claude cannot write
        // behind SkillKit's diff review; `--` keeps the prompt out of that variadic option.
        var args: [String] = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--system-prompt", systemPrompt,
            "--model", "sonnet",
            "--settings", sessionSettings,
            "--tools", "",
        ]
        if let resumeSessionId {
            args += ["--resume", resumeSessionId]
        }
        args += ["--", userMessage]

        var env = ToolSource.envWithResolvedPATH(for: .claude)
        env.removeValue(forKey: "CLAUDECODE")
        env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-swift"
        env["CLAUDE_AGENT_SDK_VERSION"] = "0.2.121"

        // A user-chosen binary outside the sandbox needs its bookmark active while running.
        if scopedAccessURL == nil {
            scopedAccessURL = AgentBinaryResolver.shared.beginAccessingOverride(for: .claude)
        }

        let runner = CLIStreamRunner(executable: bin, arguments: args, environment: env, currentDirectory: workingDir)
        self.runner = runner
        defer { self.runner = nil }

        let state = StreamState()
        let outcome = try await runner.run { [weak self] line in
            guard let self else { return }
            self.handleClaudeLine(line, state: state)
        }

        if Task.isCancelled || promptWasCancelled || outcome.wasTerminated {
            throw CancellationError()
        }

        agentLog.info("Claude stdout (\(outcome.stdout.count) chars): \(outcome.stdout.prefix(2000))")
        if !outcome.stderr.isEmpty {
            agentLog.info("Claude stderr: \(outcome.stderr.prefix(2000))")
        }
        agentLog.info("Claude exit=\(outcome.exitCode) session=\(state.sessionId ?? "-")")

        if let sid = state.sessionId {
            sessionId = sid
        }

        if outcome.exitCode != 0 {
            if let known = AgentErrorText.classify(toolName: "Claude Code", stderr: outcome.stderr, stdout: outcome.stdout) {
                throw known
            }
            var detail = AgentErrorText.readable(stderr: outcome.stderr)
            if detail.isEmpty, state.resultIsError, let r = state.finalResult {
                detail = r
            }
            throw AgentError.cliFailed(toolName: "Claude Code", exitCode: outcome.exitCode, detail: detail)
        }

        if state.resultIsError {
            let message = state.finalResult ?? "Claude reported an error"
            if let known = AgentErrorText.classify(toolName: "Claude Code", stderr: message) {
                throw known
            }
            throw AgentError.launchFailed(message)
        }

        if let final = state.finalResult, !final.isEmpty {
            return final
        }
        let accumulated = state.completedText + state.currentText
        if !accumulated.isEmpty {
            return accumulated
        }
        if !state.sawResult {
            let preview = outcome.stdout.prefix(400)
            throw AgentError.launchFailed("Couldn't parse Claude's reply. First 400 bytes:\n\(preview)")
        }
        return ""
    }

    /// Handles one NDJSON line from `claude --output-format stream-json`.
    ///
    /// Event shapes (abridged):
    /// - `{"type":"system","subtype":"init","session_id":…}`
    /// - `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":…}}}`
    ///   (also `thinking_delta`, and `content_block_start` with `content_block.type == "tool_use"`)
    /// - `{"type":"assistant","message":{"content":[{"type":"text","text":…},{"type":"tool_use","name":…,"input":…}]}}`
    /// - `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":…,"is_error":…}]}}`
    /// - `{"type":"result","subtype":"success","result":…,"is_error":false,"session_id":…}`
    private func handleClaudeLine(_ line: String, state: StreamState) {
        guard let obj = JSONEvent.parse(line), let type = obj["type"] as? String else { return }
        agentLog.debug("<<< RECV(claude): \(line.prefix(600))")
        if let sid = obj["session_id"] as? String, !sid.isEmpty {
            state.sessionId = sid
        }

        switch type {
        case "system":
            if (obj["subtype"] as? String) == "init" {
                currentActivity = "Claude session started"
            }

        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  let eventType = event["type"] as? String else { return }
            switch eventType {
            case "message_start":
                state.currentText = ""
                state.currentHadDelta = false
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any],
                   (block["type"] as? String) == "tool_use" {
                    let name = (block["name"] as? String) ?? "tool"
                    noteToolUse(name: name, input: block["input"], id: block["id"] as? String, state: state)
                }
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { return }
                switch deltaType {
                case "text_delta":
                    if let text = delta["text"] as? String {
                        state.currentText += text
                        state.currentHadDelta = true
                        responseText = state.completedText + state.currentText
                        currentActivity = "Writing…"
                    }
                case "thinking_delta":
                    if let text = delta["thinking"] as? String {
                        thoughtText += text
                        currentActivity = "Thinking…"
                    }
                default:
                    break
                }
            default:
                break
            }

        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            var fullText = ""
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String { fullText += t }
                case "thinking":
                    // Only record when deltas didn't already stream it.
                    if let t = block["thinking"] as? String, !state.currentHadDelta, !thoughtText.contains(t.prefix(40)) {
                        thoughtText += t
                    }
                case "tool_use":
                    let name = (block["name"] as? String) ?? "tool"
                    let id = block["id"] as? String
                    if id.flatMap({ state.toolActivities[$0] }) == nil {
                        noteToolUse(name: name, input: block["input"], id: id, state: state)
                    }
                default:
                    break
                }
            }
            // The full message is authoritative for what was streamed via deltas.
            let messageText = fullText.isEmpty ? state.currentText : fullText
            if !messageText.isEmpty {
                if !state.completedText.isEmpty { state.completedText += "\n\n" }
                state.completedText += messageText
            }
            state.currentText = ""
            state.currentHadDelta = false
            responseText = state.completedText

        case "user":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content where (block["type"] as? String) == "tool_result" {
                let isError = (block["is_error"] as? Bool) ?? false
                if let toolId = block["tool_use_id"] as? String,
                   let activityId = state.toolActivities[toolId],
                   let i = activities.firstIndex(where: { $0.id == activityId }) {
                    activities[i].status = isError ? .failed : .done
                    activities[i].payload.resultText = JSONEvent.summarize(block["content"], limit: 300)
                }
                thoughtText += isError ? "  ✗ tool failed\n" : "  ✓ done\n"
            }

        case "result":
            state.sawResult = true
            state.resultIsError = (obj["is_error"] as? Bool) ?? false
            if let r = obj["result"] as? String {
                state.finalResult = r
            } else if state.resultIsError, let errors = obj["errors"] as? [String] {
                state.finalResult = errors.joined(separator: "\n")
            }
            if let subtype = obj["subtype"] as? String, subtype != "success", state.finalResult == nil {
                state.resultIsError = true
                state.finalResult = "Claude ended the turn with: \(subtype.replacingOccurrences(of: "_", with: " "))"
            }

        default:
            break
        }
    }

    private func noteToolUse(name: String, input: Any?, id: String?, state: StreamState) {
        let summary = JSONEvent.summarize(input)
        let activity = AgentActivity(
            kind: .toolCall(name: name),
            title: name,
            detail: summary.isEmpty ? nil : summary,
            status: .running,
            payload: AgentActivity.Payload(rawInput: summary)
        )
        activities.append(activity)
        if let id { state.toolActivities[id] = activity.id }
        if !thoughtText.isEmpty, !thoughtText.hasSuffix("\n") { thoughtText += "\n" }
        thoughtText += "→ \(name)" + (summary.isEmpty ? "\n" : " — \(summary)\n")
        currentActivity = "Using \(name)…"
    }
}
