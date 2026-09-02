import Foundation

struct SkillLintFix: Identifiable, Hashable {
    let id: String
    let title: String
    let message: String
    /// Returns the proposed full text. Never writes anything — callers decide
    /// whether to show it as a preview or assign it to the editor.
    let apply: (String, Skill) -> String

    static func == (lhs: SkillLintFix, rhs: SkillLintFix) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Runs the fix without applying it, so the result can be reviewed first.
    func preview(_ content: String, skill: Skill) -> LintFixPreview {
        LintFixPreview(fix: self, original: content, proposed: apply(content, skill))
    }
}

/// A lint problem the linter can describe but not safely fix mechanically.
struct SkillLintWarning: Identifiable, Hashable {
    let id: String
    let title: String
    let message: String
}

/// Before/after text for one quick-fix. Present with `LintFixPreviewSheet`.
struct LintFixPreview: Identifiable {
    let fix: SkillLintFix
    let original: String
    let proposed: String

    var id: String { fix.id }
    var hasChanges: Bool { original != proposed }
}

struct SkillLintReport {
    let fixes: [SkillLintFix]
    let warnings: [SkillLintWarning]

    var isEmpty: Bool { fixes.isEmpty && warnings.isEmpty }
}

enum SkillLinter {
    static let unterminatedFrontmatterWarningID = "unterminated-frontmatter"

    /// Mechanical fixes only (kept for existing callers). Use `lint` to also
    /// get warnings such as "Unterminated frontmatter".
    static func fixes(for fullContent: String, skill: Skill) -> [SkillLintFix] {
        lint(fullContent, skill: skill).fixes
    }

    static func warnings(for fullContent: String, skill: Skill) -> [SkillLintWarning] {
        lint(fullContent, skill: skill).warnings
    }

    /// Builds the proposed text for `fix` without writing it anywhere.
    static func preview(_ fix: SkillLintFix, content: String, skill: Skill) -> LintFixPreview {
        fix.preview(content, skill: skill)
    }

    static func lint(_ fullContent: String, skill: Skill) -> SkillLintReport {
        var fixes: [SkillLintFix] = []
        var warnings: [SkillLintWarning] = []
        let parsed = FrontmatterParser.parse(fullContent)

        if hasUnterminatedFrontmatter(fullContent) {
            // Prepending a second `---` block here would corrupt the file, so
            // refuse to offer "Add frontmatter" and explain instead.
            warnings.append(.init(
                id: unterminatedFrontmatterWarningID,
                title: "Unterminated frontmatter",
                message: "The file opens with `---` but the frontmatter block is never closed. Add a closing `---` line before the body."
            ))
        } else if parsed.frontmatter.isEmpty && !startsWithFrontmatterDelimiter(fullContent) {
            fixes.append(.init(
                id: "add-frontmatter",
                title: "Add frontmatter",
                message: "Create name and description metadata from the current item.",
                apply: { content, skill in
                    // Defensive: never wrap a file that already opens a block.
                    guard !startsWithFrontmatterDelimiter(content) else { return content }
                    let name = cleanMetadataValue(skill.name.isEmpty ? "Untitled Skill" : skill.name)
                    let description = cleanMetadataValue(skill.skillDescription.isEmpty ? "Describe when this skill should be used." : skill.skillDescription)
                    return "---\nname: \(name)\ndescription: \(description)\n---\n\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                }
            ))
        } else {
            if parsed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fixes.append(metadataFix(
                    id: "add-name",
                    title: "Add name",
                    message: "Fill the missing frontmatter name.",
                    key: "name",
                    value: skill.name.isEmpty ? "Untitled Skill" : skill.name
                ))
            }

            if skill.itemKind == .skill && parsed.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fixes.append(metadataFix(
                    id: "add-description",
                    title: "Add description",
                    message: "Fill the missing frontmatter description.",
                    key: "description",
                    value: "Describe when this skill should be used."
                ))
            }
        }

        if containsDeceptiveUnicode(fullContent) {
            fixes.append(.init(
                id: "remove-deceptive-unicode",
                title: "Remove deceptive Unicode",
                message: "Strip zero-width and bidirectional control characters.",
                apply: { content, _ in
                    content.unicodeScalars
                        .filter { !deceptiveUnicodeScalars.contains($0.value) }
                        .map(String.init)
                        .joined()
                }
            ))
        }

        if trimmingTrailingWhitespace(in: fullContent) != fullContent {
            fixes.append(.init(
                id: "trim-trailing-whitespace",
                title: "Trim trailing whitespace",
                message: "Remove whitespace at line endings (keeps fenced code and two-space hard breaks).",
                apply: { content, _ in trimmingTrailingWhitespace(in: content) }
            ))
        }

        if !fullContent.hasSuffix("\n") {
            fixes.append(.init(
                id: "add-final-newline",
                title: "Add final newline",
                message: "End the file with a newline.",
                apply: { content, _ in content.hasSuffix("\n") ? content : content + "\n" }
            ))
        }

        return SkillLintReport(fixes: fixes, warnings: warnings)
    }

    // MARK: - Frontmatter

    static func startsWithFrontmatterDelimiter(_ content: String) -> Bool {
        content.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) == "---"
    }

    /// `true` when the file opens with `---` but no closing `---` line follows.
    static func hasUnterminatedFrontmatter(_ content: String) -> Bool {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return false }
        return !lines.dropFirst().contains { $0.trimmingCharacters(in: .whitespaces) == "---" }
    }

    private static func metadataFix(id: String, title: String, message: String, key: String, value: String) -> SkillLintFix {
        SkillLintFix(id: id, title: title, message: message) { content, _ in
            var lines = content.components(separatedBy: "\n")
            guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return content }

            let cleanValue = cleanMetadataValue(value)
            for index in 1..<lines.count {
                if lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                    lines.insert("\(key): \(cleanValue)", at: index)
                    return lines.joined(separator: "\n")
                }
            }
            return content
        }
    }

    // MARK: - Trailing whitespace

    /// Trims trailing whitespace line by line, except:
    /// - lines inside fenced code blocks (``` or ~~~), where whitespace can be
    ///   significant, are left untouched;
    /// - lines ending in exactly two spaces keep them — that is a Markdown
    ///   hard line break.
    ///
    /// Trims only the end of a line. Trimming both ends would strip the
    /// indentation that nested lists depend on, and splitting on `\n` (rather
    /// than the newline character set) keeps CRLF line endings from expanding
    /// into blank lines — the trailing `\r` is dropped everywhere, including
    /// inside fences, so the file ends up with uniform line endings.
    static func trimmingTrailingWhitespace(in content: String) -> String {
        var inFence = false
        var fenceChar: Character = "`"
        var fenceLength = 0

        return content.components(separatedBy: "\n").map { rawLine -> String in
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

            if let (char, length) = fenceMarker(in: line) {
                if !inFence {
                    inFence = true
                    fenceChar = char
                    fenceLength = length
                    return trimmingTrailingWhitespace(line)
                } else if char == fenceChar && length >= fenceLength && isPureFence(line) {
                    inFence = false
                    return trimmingTrailingWhitespace(line)
                }
            }

            if inFence { return line }

            let trimmed = trimmingTrailingWhitespace(line)
            if isHardBreak(line, trimmed: trimmed) {
                return trimmed + "  "
            }
            return trimmed
        }
        .joined(separator: "\n")
    }

    /// Exactly two trailing *spaces* after visible content = Markdown hard break.
    private static func isHardBreak(_ line: String, trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        let trailing = line.dropFirst(trimmed.count)
        return trailing == "  "
    }

    /// (`fence character`, `run length`) if the line opens/closes a fence: up to
    /// three leading spaces, then three or more backticks or tildes.
    private static func fenceMarker(in line: String) -> (Character, Int)? {
        var index = line.startIndex
        var leading = 0
        while index < line.endIndex, line[index] == " ", leading < 3 {
            index = line.index(after: index)
            leading += 1
        }
        guard index < line.endIndex else { return nil }
        let char = line[index]
        guard char == "`" || char == "~" else { return nil }
        var length = 0
        while index < line.endIndex, line[index] == char {
            index = line.index(after: index)
            length += 1
        }
        return length >= 3 ? (char, length) : nil
    }

    /// A closing fence has nothing but the fence characters (and whitespace).
    private static func isPureFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func trimmingTrailingWhitespace(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            guard line[previous].isWhitespace else { break }
            end = previous
        }
        return String(line[line.startIndex..<end])
    }

    // MARK: - Helpers

    private static func cleanMetadataValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsDeceptiveUnicode(_ content: String) -> Bool {
        content.unicodeScalars.contains { deceptiveUnicodeScalars.contains($0.value) }
    }

    private static let deceptiveUnicodeScalars: Set<UInt32> = [
        0x200B, 0x200C, 0x200D, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
    ]
}
