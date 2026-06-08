import SwiftUI
import SwiftData

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

                Picker("Tool", selection: $selectedTool) {
                    ForEach(creatableTools) { tool in
                        Label(tool.displayName, systemImage: tool.iconName)
                            .tag(tool)
                    }
                }
            }
            .formStyle(.grouped)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
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
                .disabled(skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        let sanitizedName = skillName
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
                    fmData["description"] = skillName
                    newContent = "---\n"
                    for (key, val) in fmData.sorted(by: { $0.key < $1.key }) {
                        newContent += "\(key): \(val)\n"
                    }
                    newContent += "---\n\n\(parsed.content)"
                } else {
                    if newContent.hasPrefix("# \(sourceSkill.name)") {
                        newContent = "# \(skillName)" + newContent.dropFirst("# \(sourceSkill.name)".count)
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
                    name: skillName,
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
