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

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ParsedSkill(frontmatter: [:], content: text, name: "", description: "")
        }

        var endIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
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
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines or pure comments in frontmatter block
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if let colonIndex = line.firstIndex(of: ":") {
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

    private static func isValidYAMLKey(_ key: String) -> Bool {
        !key.isEmpty && !key.contains(" ") && !key.hasPrefix("-")
    }

    private static func sanitizeValue(_ raw: String) -> String {
        var val = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove multiline indicator symbols if present at start
        if val.hasPrefix(">") || val.hasPrefix("|") {
            val = String(val.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Unquote double-quoted strings
        if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
            val = String(val.dropFirst().dropLast())
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
