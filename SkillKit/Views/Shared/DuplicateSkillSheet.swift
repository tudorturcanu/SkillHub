import SwiftUI
import SwiftData

struct RenameSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var skill: Skill
    @State private var proposedName: String
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    init(skill: Skill) {
        self.skill = skill
        _proposedName = State(initialValue: skill.name)
    }

    private var trimmedName: String {
        proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var identifier: String {
        SkillRenamer.identifier(from: trimmedName)
    }

    private var destinationPreview: String? {
        guard !identifier.isEmpty else { return nil }
        return SkillRenamer.destinationPath(for: skill, identifier: identifier)?
            .replacingOccurrences(of: AppPaths.userHomeDirectory, with: "~")
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Rename \(skill.displayTypeName)")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $proposedName)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFocused)
                        .onChange(of: proposedName) { errorMessage = nil }

                    if identifier.isEmpty, !trimmedName.isEmpty {
                        Text("Name must contain at least one letter or number.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let destinationPreview {
                        Text(verbatim: destinationPreview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") { rename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(identifier.isEmpty || trimmedName == skill.name)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            NotificationCenter.default.post(name: .saveCurrentSkill, object: nil)
            isNameFocused = true
        }
    }

    private func rename() {
        do {
            try SkillRenamer.rename(skill, to: trimmedName)
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DuplicateSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @State private var skillName = ""
    @State private var selectedTool: ToolSource = .agents
    @State private var errorMessage: String?

    private var sourceSkill: Skill? {
        appState.skillToDuplicate
    }

    private var itemKind: ItemKind {
        sourceSkill?.itemKind ?? .skill
    }

    private var trimmedName: String {
        skillName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var creatableTools: [ToolSource] {
        switch itemKind {
        case .skill:
            return [.agents, .amp, .antigravity, .claude, .codex, .cursor, .opencode, .pi]
        case .rule:
            return ToolSource.allCases.filter { !$0.globalRulePaths.isEmpty }
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Duplicate \(itemKind.singularName)")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                TextField("New \(itemKind.singularName) name", text: $skillName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: skillName) {
                        errorMessage = nil
                    }

                Picker("Tool", selection: $selectedTool) {
                    ForEach(creatableTools) { tool in
                        Label(tool.displayName, systemImage: tool.iconName)
                            .tag(tool)
                    }
                }
            }
            .formStyle(.grouped)

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Duplicate") {
                    duplicateItem()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            if let sourceSkill {
                skillName = "\(sourceSkill.name) Copy"
                let primaryTool = sourceSkill.toolSource
                if creatableTools.contains(primaryTool) {
                    selectedTool = primaryTool
                } else {
                    selectedTool = creatableTools.first ?? .claude
                }
            }
        }
    }

    private func duplicateItem() {
        guard let sourceSkill else {
            errorMessage = "No source skill selected for duplication"
            return
        }

        let fm = FileManager.default
        let sanitizedName = trimmedName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        guard !sanitizedName.isEmpty else {
            errorMessage = "Invalid name"
            return
        }

        let basePath: String
        let fileName: String

        switch itemKind {
        case .rule:
            guard let dir = selectedTool.globalRulePaths.first else {
                errorMessage = "This tool doesn't support rules"
                return
            }
            basePath = dir
            fileName = "\(sanitizedName).md"
        case .skill:
            guard let dir = selectedTool.globalPaths.first else {
                errorMessage = "This tool doesn't support skills"
                return
            }
            basePath = "\(dir)/\(sanitizedName)"
            fileName = "SKILL.md"
        }

        let sotDir = SkillKitSettings.sotDir
        var creationError: Error? = nil

        SandboxBookmarkManager.resolveAndAccess(path: sotDir) { _ in
            do {
                try fm.createDirectory(atPath: basePath, withIntermediateDirectories: true)

                let filePath = "\(basePath)/\(fileName)"
                var installedPaths = [filePath]
                var toolSources = [selectedTool]

                guard !fm.fileExists(atPath: filePath) else {
                    errorMessage = "A \(itemKind.singularName.lowercased()) with this name already exists"
                    return
                }

                // Read original content
                var originalContent = ""
                if sourceSkill.isRemote {
                    originalContent = sourceSkill.content
                } else {
                    do {
                        originalContent = try String(contentsOfFile: sourceSkill.filePath, encoding: .utf8)
                    } catch {
                        originalContent = sourceSkill.content
                    }
                }

                // Update content frontmatter/headings
                var newContent = originalContent
                let parsed = FrontmatterParser.parse(originalContent)
                if !parsed.frontmatter.isEmpty {
                    var fmData = parsed.frontmatter
                    fmData["name"] = sanitizedName
                    fmData["description"] = trimmedName
                    newContent = "---\n"
                    for (key, val) in fmData.sorted(by: { $0.key < $1.key }) {
                        newContent += "\(key): \(val)\n"
                    }
                    newContent += "---\n\n\(parsed.content)"
                } else {
                    if newContent.hasPrefix("# \(sourceSkill.name)") {
                        newContent = "# \(trimmedName)" + newContent.dropFirst("# \(sourceSkill.name)".count)
                    }
                }

                try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)

                // If duplicating to Global agent tools, create symlinks to active local agents
                if itemKind == .skill && selectedTool == .agents {
                    for agent in AgentTarget.installed {
                        let agentDir = "\(agent.expandedSkillsDir)/\(sanitizedName)"
                        guard !fm.fileExists(atPath: agentDir) else { continue }
                        try fm.createDirectory(atPath: agent.expandedSkillsDir, withIntermediateDirectories: true)
                        try fm.createSymbolicLink(atPath: agentDir, withDestinationPath: basePath)
                        installedPaths.append("\(agentDir)/SKILL.md")
                        if let toolSource = ToolSource.allCases.first(where: { $0.globalPaths.contains(agent.expandedSkillsDir) }) {
                            toolSources.append(toolSource)
                        }
                    }
                }

                let parsedNew = FrontmatterParser.parse(newContent)
                let newSkill = Skill(
                    filePath: filePath,
                    toolSource: selectedTool,
                    isDirectory: itemKind != .rule,
                    name: trimmedName,
                    skillDescription: parsedNew.description,
                    content: parsedNew.content,
                    frontmatter: parsedNew.frontmatter,
                    fileModifiedDate: .now,
                    fileSize: newContent.count,
                    isGlobal: true,
                    resolvedPath: filePath,
                    kind: itemKind
                )
                newSkill.installedPaths = installedPaths
                newSkill.toolSources = toolSources
                
                modelContext.insert(newSkill)
                try modelContext.save()

                switch itemKind {
                case .skill: appState.sidebarFilter = .allSkills
                case .rule: appState.sidebarFilter = .allRules
                }
                appState.selectedSkill = newSkill
                dismiss()
            } catch {
                creationError = error
            }
        }

        if let creationError {
            errorMessage = creationError.localizedDescription
        }
    }
}
