import Foundation
import Observation

/// One skill's compose conversation: its transcript plus the live agent driving it.
/// Owned by `ComposeSessionStore` so it survives `ComposePanel` being recreated (the
/// detail view applies `.id(skill.filePath)` to the panel, and closing / reopening it
/// otherwise wiped the chat).
@Observable
@MainActor
final class ComposeSession {
    /// Symlink-resolved path of the file this transcript belongs to.
    let key: String

    /// When `messages` last actually changed. This is the recency signal the persistence
    /// cap sorts on, so it must only move when the transcript does — never on every save.
    private(set) var updatedAt: Date

    /// Completed conversation history. Never holds in-flight messages — the agent drives live state.
    var messages: [ChatMessage] = [] {
        didSet {
            updatedAt = Date()
            ComposeSessionStore.shared.scheduleSave()
        }
    }
    /// True until the first successful prompt in this session.
    var isFirstTurn = true
    /// The transport currently attached to this transcript, if any.
    var agent: (any AgentSession)?
    /// Raw value of the `AgentID` that `agent` was created for.
    var agentId: String?

    init(key: String, updatedAt: Date = Date()) {
        self.key = key
        self.updatedAt = updatedAt
    }

    /// Seeds a transcript restored from disk, keeping its original recency instead of
    /// stamping it as if the user had just typed into it.
    func restore(messages: [ChatMessage], updatedAt: Date) {
        self.messages = messages
        self.updatedAt = updatedAt
    }

    var hasPendingDiffs: Bool {
        messages.contains { $0.diffs.contains { $0.status == .pending } }
    }

    /// The completed turns rendered for an agent's conversation memory. Assistant turns
    /// mention what happened to any proposed edit so the model knows whether the file
    /// content it sees already includes it.
    var conversationTurns: [ConversationTurn] {
        messages.compactMap { message in
            switch message.role {
            case .user:
                return ConversationTurn(role: .user, text: message.text)
            case .assistant:
                var text = message.text
                if message.isError {
                    text = "(error) " + text
                }
                for diff in message.diffs {
                    let name = URL(fileURLWithPath: diff.path).lastPathComponent
                    switch diff.status {
                    case .accepted: text += "\n[Proposed an edit to \(name) — the user accepted it.]"
                    case .rejected: text += "\n[Proposed an edit to \(name) — the user rejected it.]"
                    case .pending:  text += "\n[Proposed an edit to \(name) — still awaiting review.]"
                    }
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : ConversationTurn(role: .assistant, text: trimmed)
            }
        }
    }

    /// Drops the transcript (and the agent's native context) but keeps the agent attached.
    func clearHistory() {
        messages = []
        isFirstTurn = true
        agent?.resetContext()
    }

    /// Detaches and tears down the agent. The transcript is kept.
    func detachAgent() {
        let client = agent
        agent = nil
        agentId = nil
        Task { await client?.disconnect() }
    }
}

/// App-level registry of compose transcripts keyed by (symlink-resolved) skill file path.
/// In-memory for the life of the process, mirrored to Application Support as JSON so a
/// relaunch restores what was said. Live agents are never persisted.
@Observable
@MainActor
final class ComposeSessionStore {
    static let shared = ComposeSessionStore()

    private var sessions: [String: ComposeSession] = [:]
    private var saveTask: Task<Void, Never>?
    private var loaded = false

    private static let maxPersistedSessions = 40
    private static let maxPersistedMessages = 60

    private init() {}

    static func key(for filePath: String) -> String {
        URL(fileURLWithPath: filePath).resolvingSymlinksInPath().path
    }

    /// Returns the session for `filePath`, creating (and restoring from disk) as needed.
    func session(for filePath: String) -> ComposeSession {
        loadIfNeeded()
        let key = Self.key(for: filePath)
        if let existing = sessions[key] { return existing }
        let session = ComposeSession(key: key)
        sessions[key] = session
        return session
    }

    func hasTranscript(for filePath: String) -> Bool {
        loadIfNeeded()
        return !(sessions[Self.key(for: filePath)]?.messages.isEmpty ?? true)
    }

    // MARK: - Persistence

    private struct PersistedSession: Codable {
        let key: String
        let messages: [ChatMessage]
        let updatedAt: Date
    }

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("SkillKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ComposeSessions.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.storeURL),
              let persisted = try? JSONDecoder().decode([PersistedSession].self, from: data) else { return }
        for entry in persisted where sessions[entry.key] == nil {
            let session = ComposeSession(key: entry.key, updatedAt: entry.updatedAt)
            session.restore(messages: entry.messages, updatedAt: entry.updatedAt)
            session.isFirstTurn = !entry.messages.contains { $0.role == .assistant && !$0.isError }
            sessions[entry.key] = session
        }
    }

    /// Debounced write. Called from `ComposeSession.messages.didSet`.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    private func saveNow() {
        // `Dictionary.Values` has no defined order, so the cap has to be applied to a
        // deliberate ordering — most recently touched first — or relaunching would drop
        // an arbitrary transcript, quite possibly the one being used right now.
        let snapshot: [PersistedSession] = sessions.values
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.maxPersistedSessions)
            .map {
                PersistedSession(
                    key: $0.key,
                    messages: Array($0.messages.suffix(Self.maxPersistedMessages)),
                    updatedAt: $0.updatedAt
                )
            }
        let url = Self.storeURL
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger.fileIO.error("Compose transcript save failed: \(error.localizedDescription)")
            }
        }
    }
}
