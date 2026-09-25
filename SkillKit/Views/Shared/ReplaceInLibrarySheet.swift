import SwiftUI
import SwiftData

/// Find and replace across every local, editable item in the library. Each file
/// is snapshotted into version history before it is rewritten, so a replace can
/// be undone from the item's history.
struct ReplaceInLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Skill.name) private var allSkills: [Skill]

    @State private var findText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = false
    @State private var matches: [Match] = []
    @State private var excluded: Set<String> = []
    @State private var resultMessage: String?

    struct Match: Identifiable {
        let skill: Skill
        let count: Int
        var id: String { skill.filePath }
    }

    private var editableSkills: [Skill] {
        allSkills.filter { !$0.isRemote && !$0.isReadOnly }
    }

    private var options: String.CompareOptions {
        caseSensitive ? [] : [.caseInsensitive]
    }

    private var included: [Match] {
        matches.filter { !excluded.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace in Library")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Find").foregroundStyle(.secondary)
                    TextField("Text to find", text: $findText)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Replace").foregroundStyle(.secondary)
                    TextField("Replacement (may be empty)", text: $replaceText)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Toggle("Match case", isOn: $caseSensitive)

            Divider()

            if findText.isEmpty {
                placeholder("Type something to find in \(editableSkills.count) editable items.")
            } else if matches.isEmpty {
                placeholder("No editable items contain “\(findText)”.")
            } else {
                Text("\(matches.reduce(0) { $0 + $1.count }) matches in \(matches.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                List(matches) { match in
                    Toggle(isOn: Binding(
                        get: { !excluded.contains(match.id) },
                        set: { on in
                            if on { excluded.remove(match.id) } else { excluded.insert(match.id) }
                        }
                    )) {
                        HStack {
                            Text(match.skill.name)
                            Spacer()
                            Text("\(match.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help(match.skill.filePath)
                }
                .frame(minHeight: 180)
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Replace in \(included.count) Items") { replaceAll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(included.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .task(id: "\(findText)\u{0}\(caseSensitive)") {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            search()
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, options: options, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
    }

    private func search() {
        guard !findText.isEmpty else { matches = []; return }
        matches = editableSkills.compactMap { skill in
            // Read the file rather than the indexed body so frontmatter matches too.
            guard let text = SkillEditorDocument.readLocalFile(at: skill.filePath) else { return nil }
            let count = occurrences(of: findText, in: text)
            return count > 0 ? Match(skill: skill, count: count) : nil
        }
        excluded.removeAll()
    }

    private func replaceAll() {
        // Let the open editor write its pending edits first, so they aren't
        // reported as a conflict with the replace.
        NotificationCenter.default.post(name: .saveCurrentSkill, object: nil)

        var changed = 0
        var failed: [String] = []
        for match in included {
            let path = match.skill.filePath
            let ok: Bool = SandboxBookmarkManager.resolveAndAccess(path: SkillEditorDocument.accessRoot(for: path)) { _ in
                guard let current = SkillEditorDocument.readLocalFile(at: path) else { return false }
                let updated = current.replacingOccurrences(of: findText, with: replaceText, options: options)
                guard updated != current else { return true }
                do {
                    SkillVersionHistory.recordSnapshot(for: match.skill, content: current, reason: "Before replace in library")
                    SkillScanner.active?.ignoreNextChange(for: path)
                    let writePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    try updated.write(toFile: writePath, atomically: true, encoding: .utf8)
                    let parsed = FrontmatterParser.parse(updated)
                    if !parsed.name.isEmpty { match.skill.name = parsed.name }
                    match.skill.skillDescription = parsed.description
                    match.skill.content = parsed.content
                    match.skill.frontmatter = parsed.frontmatter
                    match.skill.fileModifiedDate = .now
                    return true
                } catch {
                    return false
                }
            }
            if ok { changed += 1 } else { failed.append(match.skill.name) }
        }

        try? allSkills.first?.modelContext?.save()
        resultMessage = failed.isEmpty
            ? "Replaced in \(changed) items. Earlier versions are in each item's history."
            : "Replaced in \(changed) items. Couldn't write: \(failed.joined(separator: ", "))."
        search()
    }
}
