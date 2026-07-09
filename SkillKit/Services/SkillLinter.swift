import Foundation

struct SkillLintFix: Identifiable, Hashable {
    let id: String
    let title: String
    let message: String
    let apply: (String, Skill) -> String

    static func == (lhs: SkillLintFix, rhs: SkillLintFix) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum SkillLinter {
    static func fixes(for fullContent: String, skill: Skill) -> [SkillLintFix] {
        var fixes: [SkillLintFix] = []
        let parsed = FrontmatterParser.parse(fullContent)

        if parsed.frontmatter.isEmpty {
            fixes.append(.init(
                id: "add-frontmatter",
                title: "Add frontmatter",
                message: "Create name and description metadata from the current item.",
                apply: { content, skill in
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

        if fullContent.components(separatedBy: .newlines).contains(where: { $0 != $0.trimmingCharacters(in: .whitespaces) }) {
            fixes.append(.init(
                id: "trim-trailing-whitespace",
                title: "Trim trailing whitespace",
                message: "Remove whitespace at line endings.",
                apply: { content, _ in
                    content.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .joined(separator: "\n")
                }
            ))
        }

        if !fullContent.hasSuffix("\n") {
            fixes.append(.init(
                id: "add-final-newline",
                title: "Add final newline",
                message: "End the file with a newline.",
                apply: { content, _ in content + "\n" }
            ))
        }

        return fixes
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
