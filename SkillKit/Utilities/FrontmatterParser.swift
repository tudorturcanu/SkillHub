import Foundation

struct ParsedSkill {
    var frontmatter: [String: String]
    var content: String
    var name: String
    var description: String
}
enum FrontmatterParser {
    static func parse(_ text: String) -> ParsedSkill {
        let lines = text.components(separatedBy: "\n")

        // `.whitespacesAndNewlines` so a CRLF file's `---\r` still counts as a delimiter.
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return ParsedSkill(frontmatter: [:], content: text, name: "", description: "")
        }

        var endIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                endIndex = i
                break
            }
        }

        guard let end = endIndex else {
            return ParsedSkill(frontmatter: [:], content: text, name: "", description: "")
        }

        var frontmatter: [String: String] = [:]
        var currentKey: String?
        var currentValueLines: [String] = []

        let commitCurrentKey = {
            if let key = currentKey {
                let joined = currentValueLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                frontmatter[key] = sanitizeValue(joined)
            }
        }

        for i in 1..<end {
            let line = lines[i].hasSuffix("\r") ? String(lines[i].dropLast()) : lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines or pure comments in frontmatter block
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Once a key is open, an indented line belongs to it: a block scalar line such
            // as `  Note: careful` or a nested map's `  name: inner` is not a new top-level key.
            let isIndented = line.first.map { $0 == " " || $0 == "\t" } ?? false
            if !(isIndented && currentKey != nil), let colonIndex = line.firstIndex(of: ":") {
                let possibleKey = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let valuePart = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

                if isValidYAMLKey(possibleKey) {
                    commitCurrentKey()
                    currentKey = possibleKey
                    currentValueLines = [valuePart]
                    continue
                }
            }

            // Continuation line for multiline string values
            if currentKey != nil {
                currentValueLines.append(line)
            }
        }
        commitCurrentKey()

        let contentStartIndex = min(end + 1, lines.count)
        let contentLines = Array(lines[contentStartIndex...])
        let content = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let cleanName = sanitizeValue(frontmatter["name"] ?? "")
        let cleanDescription = sanitizeValue(frontmatter["description"] ?? "")

        return ParsedSkill(
            frontmatter: frontmatter,
            content: content,
            name: cleanName,
            description: cleanDescription
        )
    }

    /// Renders `value` as a YAML scalar for a `key: value` line, double-quoting it when it
    /// would otherwise be misread: `Use when: asked` is a nested mapping to a YAML parser,
    /// `# x` a comment, `[a]` a list, and a newline would end the value early.
    static func yamlScalar(_ value: String) -> String {
        let needsQuotes = value.isEmpty
            || value.contains(": ") || value.hasSuffix(":") || value.contains(" #")
            || value.contains("\"") || value.contains("\\") || value.contains("\n") || value.contains("\r")
            || value.first.map { "[]{}&*!|>'%@`-?#,".contains($0) || $0.isWhitespace } == true
            || value.last?.isWhitespace == true
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Resolves the escapes a YAML double-quoted scalar may carry. Unknown escapes are kept
    /// as written rather than dropped.
    private static func unescapeDoubleQuoted(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\"", "\\", "/": result.append(next)
            default: result.append("\\"); result.append(next)
            }
        }
        return result
    }

    private static func isValidYAMLKey(_ key: String) -> Bool {
        !key.isEmpty && !key.contains(" ") && !key.hasPrefix("-")
    }

    private static func sanitizeValue(_ raw: String) -> String {
        var val = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove multiline indicator symbols if present at start
        if val.hasPrefix(">") || val.hasPrefix("|") {
            val = String(val.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Unquote double-quoted strings, resolving the escapes `yamlScalar` writes.
        if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
            val = unescapeDoubleQuoted(String(val.dropFirst().dropLast()))
        }
        // Unquote single-quoted strings
        else if val.hasPrefix("'") && val.hasSuffix("'") && val.count >= 2 {
            val = String(val.dropFirst().dropLast())
        }

        // Convert inline bracket array syntax `[a, b, c]` to clean comma string
        if val.hasPrefix("[") && val.hasSuffix("]") && val.count >= 2 {
            let inner = String(val.dropFirst().dropLast())
            val = inner.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }

        return val
    }
}
