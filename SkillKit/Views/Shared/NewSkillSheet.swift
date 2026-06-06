import SwiftUI
import SwiftData

enum SkillTemplate: String, CaseIterable, Identifiable {
    case blank = "Blank"
    case webScraper = "Web Scraper"
    case databaseConnector = "Database Connector"
    
    var id: String { self.rawValue }
}

struct NewSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @State private var skillName = ""
    @State private var selectedTool: ToolSource = .agents
    @State private var selectedTemplate: SkillTemplate = .blank
    @State private var errorMessage: String?

    private var itemKind: ItemKind { appState.newItemKind }

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
            Text("New \(itemKind.singularName)")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                TextField("\(itemKind.singularName) name", text: $skillName)
                    .textFieldStyle(.roundedBorder)

                Picker("Tool", selection: $selectedTool) {
                    ForEach(creatableTools) { tool in
                        Label(tool.displayName, systemImage: tool.iconName)
                            .tag(tool)
                    }
                }
                
                if itemKind == .skill {
                    Picker("Template", selection: $selectedTemplate) {
                        ForEach(SkillTemplate.allCases) { template in
                            Text(template.rawValue).tag(template)
                        }
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

                Button("Create") {
                    createItem()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(skillName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            // Ensure selectedTool is valid for the current item kind
            if !creatableTools.contains(selectedTool) {
                selectedTool = creatableTools.first ?? .claude
            }
        }
    }

    private func createItem() {
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

                let boilerplate = generateBoilerplate(name: skillName, skillID: sanitizedName, tool: selectedTool)
                try boilerplate.write(toFile: filePath, atomically: true, encoding: .utf8)

                // When creating a Global skill, symlink from each installed agent's skills dir
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

                let parsed = FrontmatterParser.parse(boilerplate)
                let skill = Skill(
                    filePath: filePath,
                    toolSource: selectedTool,
                    isDirectory: itemKind != .rule,
                    name: skillName,
                    skillDescription: parsed.description,
                    content: parsed.content,
                    frontmatter: parsed.frontmatter,
                    fileModifiedDate: .now,
                    fileSize: boilerplate.count,
                    isGlobal: true,
                    resolvedPath: filePath,
                    kind: itemKind
                )
                skill.installedPaths = installedPaths
                skill.toolSources = toolSources
                modelContext.insert(skill)
                try modelContext.save()

                switch itemKind {
                case .skill: appState.sidebarFilter = .allSkills
                case .rule: appState.sidebarFilter = .allRules
                }
                appState.selectedSkill = skill
                dismiss()
            } catch {
                creationError = error
            }
        }

        if let creationError {
            errorMessage = creationError.localizedDescription
        }
    }

    private func generateBoilerplate(name: String, skillID: String, tool: ToolSource) -> String {
        switch itemKind {
        case .rule:
            return """
            # \(name) (SkillKit Rule)

            // Created via SkillKit.
            Add your assistant rule content here.
            """
        case .skill:
            var instructions = "Add your skill instructions here."
            switch selectedTemplate {
            case .webScraper:
                instructions = """
                1. Use `curl` or a headless browser to fetch the URL.
                2. Parse the HTML to extract the requested elements.
                3. Output the extracted data in a structured format (e.g. JSON, CSV).
                4. Handle rate limits and connection errors gracefully.
                """
            case .databaseConnector:
                instructions = """
                1. Connect to the specified database using appropriate drivers.
                2. Execute the user's query (ensure it is safe and read-only if possible).
                3. Format the results as a markdown table.
                4. Report any connection or execution errors clearly.
                """
            case .blank:
                break
            }
            
            switch tool {
            case .claude, .cursor, .agents:
                return """
                ---
                name: \(skillID)
                description: \(name)
                generator: skillkit
                ---

                # \(name) (SkillKit Skill)

                ## When to Use
                - Describe when this SkillKit skill should be triggered by the coding assistant.

                ## Instructions
                \(instructions)
                """
            default:
                return """
                ---
                name: \(skillID)
                description: \(name)
                generator: skillkit
                ---

                # \(name) (SkillKit Skill)

                ## Instructions
                \(instructions)
                """
            }
        }
    }
}
