import Foundation

/// Shared parser for one-shot agent replies. Both Claude (`claude -p --output-format json`)
/// and Codex (`codex exec --output-last-message`) ask the model for "summary + fenced full
/// file" or a structured edits JSON envelope; this turns either into `(summary, newContent)`.
enum OneShotResponseParser {

    /// `summary` is plain text the user sees in chat. `newContent` is the proposed file
    /// body — `nil` means the agent replied conversationally with no edit to apply.
    struct Result {
        let summary: String
        let newContent: String?
    }

    struct EditApplyError: LocalizedError {
        let errorDescription: String?
    }

    /// Decoded shape of the structured-edits JSON format.
    private struct EditsResponse: Decodable {
        let summary: String
        let edits: [EditOp]

        struct EditOp: Decodable {
            let find: String
            let replace: String
        }
    }

    static func parse(_ text: String, originalContent: String?) -> Result {
        // 1. Try structured-edits JSON first.
        let stripped = stripCodeFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = stripped.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(EditsResponse.self, from: data) {
            if parsed.edits.isEmpty {
                return Result(summary: parsed.summary, newContent: nil)
            }
            guard let original = originalContent else {
                return Result(summary: parsed.summary, newContent: nil)
            }
            do {
                return Result(summary: parsed.summary, newContent: try applyEdits(parsed.edits, to: original))
            } catch {
                // Say so: a summary like "Updated X" with no diff looks like a silent success.
                return Result(
                    summary: parsed.summary + "\n\n(The edit couldn't be applied: \(error.localizedDescription))",
                    newContent: nil
                )
            }
        }

        // 2. Fall back to summary + fenced full-file block.
        guard let block = trailingFencedBlock(in: text) else {
            // No block, or prose after it: a conversational answer, possibly quoting
            // snippets. A snippet must never be mistaken for the whole file.
            return Result(summary: text.trimmingCharacters(in: .whitespacesAndNewlines), newContent: nil)
        }
        guard looksLikeWholeFile(block.body, original: originalContent) else {
            return Result(
                summary: block.summary + "\n\n(The reply's code block doesn't look like the complete file, so no edit was proposed. Ask for the full updated file to get one.)",
                newContent: nil
            )
        }
        return Result(summary: block.summary, newContent: block.body)
    }

    /// The reply format is "summary, then one fenced block holding the whole file", so the
    /// block must be the last thing in the reply. The closing fence has to match the
    /// opener (same character, at least as long), which lets a ```` fence wrap a file that
    /// contains its own ``` examples.
    static func trailingFencedBlock(in text: String) -> (summary: String, body: String)? {
        let pattern = #"(?m)^(`{3,}|~{3,})[A-Za-z0-9_+.-]*[ \t]*\n"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let openRange = Range(match.range, in: text),
              let fenceRange = Range(match.range(at: 1), in: text) else { return nil }
        let fence = text[fenceRange]
        let summary = String(text[..<openRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        var lines = String(text[openRange.upperBound...]).components(separatedBy: "\n")
        // Drop trailing blank lines, then the last line must close the fence.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let closing = lines.last?.trimmingCharacters(in: .whitespaces),
              closing.count >= fence.count,
              closing.allSatisfy({ $0 == fence.first }) else { return nil }
        lines.removeLast()
        return (summary, lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
    }

    /// Guards against proposing a fragment as the new file: one that drops the frontmatter
    /// the file had, or keeps less than a quarter of a file of any size.
    static func looksLikeWholeFile(_ candidate: String, original: String?) -> Bool {
        guard let original, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        func opensFrontmatter(_ text: String) -> Bool {
            text.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }
        if opensFrontmatter(original), !opensFrontmatter(candidate) { return false }
        let originalLines = original.components(separatedBy: "\n").count
        let candidateLines = candidate.components(separatedBy: "\n").count
        if originalLines >= 12, candidateLines * 4 < originalLines { return false }
        return true
    }

    // MARK: - Internals

    private static func stripCodeFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["```json\n", "```JSON\n", "```\n"]
        for prefix in prefixes where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        if s.hasSuffix("\n```") { s.removeLast(4) }
        else if s.hasSuffix("```") { s.removeLast(3) }
        return s
    }

    private static func applyEdits(_ edits: [EditsResponse.EditOp], to original: String) throws -> String {
        var content = original
        for (i, edit) in edits.enumerated() {
            var occurrences = 0
            var searchStart = content.startIndex
            while let r = content.range(of: edit.find, range: searchStart..<content.endIndex) {
                occurrences += 1
                searchStart = r.upperBound
                if occurrences > 1 { break }
            }
            switch occurrences {
            case 0:
                throw EditApplyError(
                    errorDescription: "edit #\(i + 1)'s `find` text doesn't appear in the file:\n\n\(edit.find.prefix(300))"
                )
            case 1:
                if let r = content.range(of: edit.find) {
                    content.replaceSubrange(r, with: edit.replace)
                }
            default:
                throw EditApplyError(
                    errorDescription: "edit #\(i + 1)'s `find` text appears more than once, so it needs more surrounding context to be unique."
                )
            }
        }
        return content
    }
}

/// Small helpers shared by one-shot agents for assembling the system + user prompts.
enum OneShotPrompts {
    /// System prompt sent to the agent when the host hasn't supplied one. Identical for
    /// Claude and Codex so the parser can rely on a consistent reply format.
    static func defaultSystemPrompt(filePath: String?) -> String {
        let name = filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "the file"
        return """
        You are helping the user edit \(name) — a Markdown file used to instruct an AI coding assistant.

        Apply the user's request **minimally**. Preserve every unchanged line exactly — same whitespace, same blank lines, same wording. Do not refactor or "improve" anything the user didn't ask about.

        ## Reply format

        Reply with two things in this exact order:
        1. ONE OR TWO SENTENCES summarizing what changed (plain text, no preamble).
        2. The COMPLETE updated file content inside a single fenced code block. Open with ``` on its own line, then the full file (including YAML frontmatter), then ``` on its own line.

        If the user is asking a question rather than requesting an edit, omit the code fence and just answer in prose.
        """
    }

    /// Wraps the user's request with the current file content (and, when the transport
    /// can't resume a native session, the conversation so far) so the agent has full
    /// context without needing tool access.
    static func userMessage(
        userRequest: String,
        filePath: String?,
        fileContent: String?,
        history: [ConversationTurn] = []
    ) -> String {
        var parts: [String] = []
        if let filePath, let fileContent {
            let name = URL(fileURLWithPath: filePath).lastPathComponent
            parts.append("Current contents of \(name):")
            parts.append("```")
            parts.append(fileContent.isEmpty ? "(empty file)" : fileContent)
            parts.append("```")
            parts.append("")
        }
        let transcript = historySection(history)
        if !transcript.isEmpty {
            parts.append(transcript)
            parts.append("")
        }
        parts.append("User's request:")
        parts.append(userRequest)
        return parts.joined(separator: "\n")
    }

    /// Maximum number of prior turns replayed into a one-shot prompt.
    static let maxHistoryTurns = 12
    /// Maximum total characters of replayed history. Oldest turns are dropped first.
    static let maxHistoryChars = 24_000

    /// Renders the tail of `history` as a "Conversation so far:" block, bounded by
    /// `maxHistoryTurns` / `maxHistoryChars`. Empty string when there is nothing to replay.
    static func historySection(_ history: [ConversationTurn]) -> String {
        let trimmed = trimHistory(history)
        guard !trimmed.isEmpty else { return "" }
        var lines: [String] = []
        lines.append("Conversation so far (oldest first — the file content above already reflects any accepted edits):")
        for turn in trimmed {
            let label = turn.role == .user ? "User" : "Assistant"
            lines.append("\(label): \(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Marks where a single oversized turn was cut. Kept short so it eats little budget.
    static let historyElision = "…(earlier part of this message omitted)…\n"

    static func trimHistory(_ history: [ConversationTurn]) -> [ConversationTurn] {
        var kept: [ConversationTurn] = []
        var chars = 0
        for turn in history.reversed() {
            let cost = turn.text.count + 16
            if kept.isEmpty {
                // The most recent turn is always replayed. Dropping it because it alone
                // busts the budget would silently wipe the agent's whole memory, so cut
                // the turn down to its tail instead.
                let turn = cost > maxHistoryChars ? truncatedToBudget(turn) : turn
                kept.append(turn)
                chars += turn.text.count + 16
                continue
            }
            if kept.count >= maxHistoryTurns || chars + cost > maxHistoryChars { break }
            kept.append(turn)
            chars += cost
        }
        return kept.reversed()
    }

    /// Keeps the tail of `turn.text` (the part closest to the current request) within
    /// `maxHistoryChars`, prefixed with an elision marker so the model knows it was cut.
    private static func truncatedToBudget(_ turn: ConversationTurn) -> ConversationTurn {
        let budget = max(0, maxHistoryChars - 16 - historyElision.count)
        return ConversationTurn(role: turn.role, text: historyElision + String(turn.text.suffix(budget)))
    }
}
