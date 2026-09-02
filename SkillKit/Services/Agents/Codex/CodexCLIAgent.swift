import Foundation
import Observation

/// One-shot transport for OpenAI Codex. Each `prompt()` is a single
/// `codex exec --json --output-last-message <tmp> --sandbox read-only --skip-git-repo-check
/// --ephemeral <user-message>` invocation. The JSONL event stream is parsed as it arrives
/// so the panel shows reasoning / command activity and the reply as it lands; the
/// `--output-last-message` file still provides the authoritative final text.
///
/// Older Codex builds without `--json` fall back to the blocking mode (wait for exit, read
/// the last-message file). Conversation memory is replayed inside the prompt: `--ephemeral`
/// sessions can't be resumed, and we don't want SkillKit turns cluttering the user's
/// Codex history.
///
/// Codex never touches the filesystem; SkillKit owns the disk write the same way the
/// Claude transport does.
@Observable
@MainActor
final class CodexCLIAgent: AgentSession {

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
    var hasNativeSession: Bool { false }

    // MARK: - Private

    private var workingDirectory: URL?
    private var sessionSystemPrompt: String?
    private var binaryURL: URL?
    private var scopedAccessURL: URL?
    private var runner: CLIStreamRunner?
    private var connectTask: Task<Void, Never>?
    private var promptWasCancelled = false
    /// Whether the resolved binary understands `codex exec --json`. Probed once per binary.
    private var supportsJSON: Bool?

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
            guard let resolution = await ToolSource.codex.resolveCLIBinary() else {
                self.lastError = AgentError.binaryNotInstalled(
                    toolName: "Codex",
                    installURL: AgentID.codex.installURL
                ).localizedDescription
                return
            }
            if Task.isCancelled { return }
            self.binaryURL = resolution.url
            if let v = await ToolSource.codex.cliVersion(binary: resolution.url) {
                agentLog.info("Codex v\(v.major).\(v.minor).\(v.patch) at \(resolution.url.path) (\(resolution.source.rawValue))")
            }
            if Task.isCancelled { return }
            self.supportsJSON = await Self.probeJSONSupport(bin: resolution.url)
            agentLog.info("Codex exec --json supported: \(self.supportsJSON ?? false)")
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
        scopedAccessURL?.stopAccessingSecurityScopedResource()
        scopedAccessURL = nil
    }

    func resetContext() {
        // Prompt-replayed history only; nothing native to forget.
    }

    // MARK: - Per-turn

    func prompt(_ text: String, history: [ConversationTurn]) async throws {
        guard isConnected, let bin = binaryURL ?? ToolSource.codex.cliBinaryURL,
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
            title: "Thinking with Codex…",
            status: .running
        ))
        currentActivity = "Thinking with Codex…"

        defer {
            isProcessing = false
            turnStartedAt = nil
            currentActivity = nil
        }

        let (filePath, fileContent) = primaryFile()
        // Codex doesn't accept a separate system prompt flag, so we splice it into the
        // user message — same shape that worked end-to-end in CLI smoke tests.
        let systemPrompt = sessionSystemPrompt ?? OneShotPrompts.defaultSystemPrompt(filePath: filePath)
        let userBody = OneShotPrompts.userMessage(
            userRequest: text,
            filePath: filePath,
            fileContent: fileContent,
            history: history
        )
        let combined = "\(systemPrompt)\n\n---\n\n\(userBody)"

        do {
            let result = try await runCodex(bin: bin, workingDir: wd, userMessage: combined)

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

    // MARK: - Permissions / writes (no-op in one-shot mode — we own disk writes)

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

    /// `codex exec --help` mentions `--json` on builds that support JSONL streaming.
    private static func probeJSONSupport(bin: URL) async -> Bool {
        let env = ToolSource.envWithResolvedPATH(for: .codex)
        let help = await ToolSource.captureStdoutAsync(
            of: bin,
            arguments: ["exec", "--help"],
            environment: env,
            timeout: 10
        ) ?? ""
        return help.contains("--json")
    }

    @MainActor
    private final class StreamState {
        /// agent_message item id → text, so `item.updated` can replace in place.
        var messages: [(id: String, text: String)] = []
        var itemActivities: [String: UUID] = [:]
        var errorMessage: String?
        var turnCompleted = false

        var joinedText: String {
            messages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
    }

    private func runCodex(bin: URL, workingDir: URL, userMessage: String) async throws -> String {
        // `--output-last-message` is the cleanest way to get just the final agent reply.
        // Stdout interleaves status lines, "tokens used", colorised banners, etc. (or JSONL
        // events with --json); the file gets exactly the last assistant message.
        let lastMsgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillkit-codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: lastMsgURL) }

        let useJSON = supportsJSON ?? false
        var args: [String] = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral", "--color", "never"]
        if useJSON { args.append("--json") }
        args += ["--output-last-message", lastMsgURL.path, userMessage]

        if scopedAccessURL == nil {
            scopedAccessURL = AgentBinaryResolver.shared.beginAccessingOverride(for: .codex)
        }

        let runner = CLIStreamRunner(
            executable: bin,
            arguments: args,
            environment: ToolSource.envWithResolvedPATH(for: .codex),
            currentDirectory: workingDir
        )
        self.runner = runner
        defer { self.runner = nil }

        let state = StreamState()
        let outcome = try await runner.run { [weak self] line in
            guard let self, useJSON else { return }
            self.handleCodexLine(line, state: state)
        }

        if Task.isCancelled || promptWasCancelled || outcome.wasTerminated {
            throw CancellationError()
        }

        agentLog.info("Codex stdout (\(outcome.stdout.count) chars): \(outcome.stdout.prefix(2000))")
        if !outcome.stderr.isEmpty {
            agentLog.info("Codex stderr: \(outcome.stderr.prefix(2000))")
        }
        agentLog.info("Codex exit=\(outcome.exitCode)")

        if outcome.exitCode != 0 {
            if let known = AgentErrorText.classify(toolName: "Codex", stderr: outcome.stderr, stdout: state.errorMessage ?? "") {
                throw known
            }
            var detail = AgentErrorText.readable(stderr: outcome.stderr)
            if let streamed = state.errorMessage, !streamed.isEmpty {
                detail = detail.isEmpty ? streamed : "\(streamed)\n\(detail)"
            }
            throw AgentError.cliFailed(toolName: "Codex", exitCode: outcome.exitCode, detail: detail)
        }

        if let lastMsg = try? String(contentsOf: lastMsgURL, encoding: .utf8),
           !lastMsg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lastMsg
        }
        let streamed = state.joinedText
        if !streamed.isEmpty {
            return streamed
        }
        if let err = state.errorMessage, !err.isEmpty {
            throw AgentError.launchFailed(err)
        }
        let preview = outcome.stdout.prefix(400)
        throw AgentError.launchFailed("Codex returned no final message. First 400 bytes of stdout:\n\(preview)")
    }

    /// Handles one JSONL line from `codex exec --json`.
    ///
    /// Event shapes (abridged):
    /// - `{"type":"thread.started","thread_id":…}` / `{"type":"turn.started"}`
    /// - `{"type":"item.started"|"item.updated"|"item.completed","item":{"id":…,"type":"agent_message","text":…}}`
    ///   where `item.type` is one of `agent_message`, `reasoning`, `command_execution`
    ///   (`command`, `aggregated_output`, `status`), `file_change`, `mcp_tool_call`,
    ///   `web_search`, `todo_list`.
    /// - `{"type":"turn.completed","usage":{…}}` / `{"type":"turn.failed","error":{"message":…}}`
    /// - `{"type":"error","message":…}`
    private func handleCodexLine(_ line: String, state: StreamState) {
        guard let obj = JSONEvent.parse(line), let type = obj["type"] as? String else { return }
        agentLog.debug("<<< RECV(codex): \(line.prefix(600))")

        switch type {
        case "thread.started":
            currentActivity = "Codex session started"
        case "turn.started":
            currentActivity = "Thinking with Codex…"
        case "turn.completed":
            state.turnCompleted = true
        case "turn.failed":
            let error = obj["error"] as? [String: Any]
            state.errorMessage = (error?["message"] as? String) ?? "Codex turn failed"
        case "error":
            state.errorMessage = (obj["message"] as? String) ?? "Codex reported an error"
        case "item.started", "item.updated", "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return }
            handleCodexItem(item, phase: type, state: state)
        default:
            break
        }
    }

    private func handleCodexItem(_ item: [String: Any], phase: String, state: StreamState) {
        let id = (item["id"] as? String) ?? UUID().uuidString
        let itemType = (item["type"] as? String) ?? ""
        let completed = phase == "item.completed"

        switch itemType {
        case "agent_message":
            let text = (item["text"] as? String) ?? ""
            if let i = state.messages.firstIndex(where: { $0.id == id }) {
                state.messages[i].text = text
            } else {
                state.messages.append((id: id, text: text))
            }
            responseText = state.joinedText
            currentActivity = completed ? "Replied" : "Writing…"

        case "reasoning":
            let text = (item["text"] as? String) ?? ""
            if !text.isEmpty {
                if !thoughtText.isEmpty, !thoughtText.hasSuffix("\n") { thoughtText += "\n" }
                thoughtText += text + "\n"
            }
            currentActivity = "Thinking…"

        case "command_execution":
            let command = (item["command"] as? String) ?? "command"
            let status = (item["status"] as? String) ?? ""
            let activityStatus: AgentActivity.Status = {
                switch status {
                case "completed": return .done
                case "failed", "declined": return .failed
                default: return completed ? .done : .running
                }
            }()
            upsertActivity(
                id: id, kind: .toolCall(name: "shell"), title: "Run: \(JSONEvent.summarize(command, limit: 80))",
                detail: JSONEvent.summarize(item["aggregated_output"], limit: 200),
                status: activityStatus, state: state
            )
            if phase == "item.started" {
                thoughtText += "$ \(JSONEvent.summarize(command, limit: 160))\n"
            }
            currentActivity = "Running command…"

        case "file_change":
            upsertActivity(id: id, kind: .toolCall(name: "file_change"), title: "File change",
                           detail: JSONEvent.summarize(item["changes"], limit: 160),
                           status: completed ? .done : .running, state: state)
            if phase == "item.started" { thoughtText += "→ file change\n" }

        case "mcp_tool_call":
            let name = [(item["server"] as? String), (item["tool"] as? String)].compactMap { $0 }.joined(separator: "/")
            upsertActivity(id: id, kind: .toolCall(name: name.isEmpty ? "tool" : name), title: name.isEmpty ? "Tool call" : name,
                           detail: JSONEvent.summarize(item["arguments"]),
                           status: completed ? .done : .running, state: state)
            if phase == "item.started" { thoughtText += "→ \(name.isEmpty ? "tool" : name)\n" }

        case "web_search":
            let query = (item["query"] as? String) ?? ""
            upsertActivity(id: id, kind: .toolCall(name: "web_search"), title: "Web search",
                           detail: query.isEmpty ? nil : query, status: completed ? .done : .running, state: state)
            if phase == "item.started" { thoughtText += "→ web search: \(query)\n" }

        default:
            break
        }
    }

    private func upsertActivity(
        id: String,
        kind: AgentActivity.Kind,
        title: String,
        detail: String?,
        status: AgentActivity.Status,
        state: StreamState
    ) {
        if let activityId = state.itemActivities[id],
           let i = activities.firstIndex(where: { $0.id == activityId }) {
            activities[i].title = title
            if let detail, !detail.isEmpty { activities[i].detail = detail }
            activities[i].status = status
        } else {
            let activity = AgentActivity(kind: kind, title: title, detail: (detail?.isEmpty ?? true) ? nil : detail, status: status)
            activities.append(activity)
            state.itemActivities[id] = activity.id
        }
    }
}
