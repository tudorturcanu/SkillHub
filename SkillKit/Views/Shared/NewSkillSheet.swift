import SwiftUI
import SwiftData

enum SkillTemplate: String, CaseIterable, Identifiable {
    case blank = "Blank"
    case webScraper = "Web Scraper"
    case databaseConnector = "Database Connector"
    
    var id: String { self.rawValue }
}

enum RuleTemplate: String, CaseIterable, Identifiable {
    case blank = "Blank"
    case codeStyle = "Code Style & Formatting"
    case concurrency = "Swift Concurrency Rules"
    case gitGuidelines = "Git & Commits Guidelines"
    
    var id: String { self.rawValue }
}

struct NewSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @State private var skillName = ""
    @State private var skillDescription = ""
    @State private var selectedTool: ToolSource = .agents
    @State private var selectedTemplate: SkillTemplate = .blank
    @State private var selectedRuleTemplate: RuleTemplate = .blank
    @State private var errorMessage: String?

    private var itemKind: ItemKind { appState.newItemKind }

    private var trimmedName: String {
        skillName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: String {
        skillDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The on-disk identifier derived from the display name: lowercased,
    /// spaces to hyphens, anything but letters/digits/hyphens dropped.
    static func slug(from name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private var slug: String { Self.slug(from: trimmedName) }

    /// Where the file will be written for the current name, kind, and tool.
    private var destinationPath: String? {
        guard !slug.isEmpty else { return nil }
        switch itemKind {
        case .rule:
            guard let dir = selectedTool.globalRulePaths.first else { return nil }
            return "\(dir)/\(slug).md"
        case .skill:
            guard let dir = selectedTool.globalPaths.first else { return nil }
            return "\(dir)/\(slug)/SKILL.md"
        }
    }

    private var destinationPreview: String? {
        destinationPath?.replacingOccurrences(of: AppPaths.userHomeDirectory, with: "~")
    }

    @ViewBuilder
    private var namePreviewCaption: some View {
        if !trimmedName.isEmpty {
            if slug.isEmpty {
                Text("Name must contain at least one letter or number.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if let destinationPreview {
                        Text(verbatim: destinationPreview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } else {
                        Text("\(selectedTool.displayName) has no \(itemKind.displayName.lowercased()) folder.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if slug != trimmedName {
                        Text("Saved with the identifier “\(slug)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
            Text("New \(itemKind.singularName)")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("\(itemKind.singularName) name", text: $skillName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: skillName) {
                            errorMessage = nil
                        }
                    namePreviewCaption
                }

                if itemKind == .skill {
                    TextField("Description", text: $skillDescription, prompt: Text("Optional — when the assistant should use this skill"))
                        .textFieldStyle(.roundedBorder)
                }

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
                } else if itemKind == .rule {
                    Picker("Template", selection: $selectedRuleTemplate) {
                        ForEach(RuleTemplate.allCases) { template in
                            Text(template.rawValue).tag(template)
                        }
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

                Button("Create") {
                    createItem()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            // Ensure selectedTool is valid for the current item kind
            if !creatableTools.contains(selectedTool) {
                selectedTool = creatableTools.first ?? .claude
            }
        }
    }

    private func createItem() {
        let fm = FileManager.default
        let sanitizedName = slug

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

                let boilerplate = generateBoilerplate(
                    name: trimmedName,
                    skillID: sanitizedName,
                    description: trimmedDescription,
                    tool: selectedTool
                )
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
                    name: trimmedName,
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

    /// A `description:` frontmatter line, or nothing when the user left it blank.
    /// Values with YAML-sensitive characters are double-quoted (the parser unquotes).
    private func descriptionFrontmatterLine(_ description: String) -> String {
        guard !description.isEmpty else { return "" }
        let needsQuoting = description.contains(":")
            || description.contains("#")
            || description.contains("\"")
            || description.first.map { "[]{}&*!|>'%@`-?".contains($0) } == true
        if needsQuoting {
            let escaped = description
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "description: \"\(escaped)\"\n"
        }
        return "description: \(description)\n"
    }

    private func generateBoilerplate(name: String, skillID: String, description: String, tool: ToolSource) -> String {
        switch itemKind {
        case .rule:
            var ruleContent = "Add your assistant rule content here."
            switch selectedRuleTemplate {
            case .codeStyle:
                ruleContent = """
                1. **Naming Conventions**: Use `camelCase` for variables and functions, and `PascalCase` for types.
                2. **Length Limit**: Keep functions short (under 40 lines) and focus on a single responsibility.
                3. **Safety First**: Never use force unwrapping (`!`). Always use `if let`, `guard let`, or provide a default value.
                4. **UI Layout**: Prefer declarative layout hierarchy, separating styling parameters logically.
                """
            case .concurrency:
                ruleContent = """
                1. **Main Actor Isolation**: Mark all UI-bound components, views, and `@Observable` models with `@MainActor`.
                2. **Async Operations**: Prefer modern Swift concurrency (`async/await`, `Task`, `TaskGroup`) over GCD/DispatchQueues or completion handlers.
                3. **Sendability**: Adhere to strict concurrency safety. Mark data structures crossing isolation barriers as `Sendable`.
                4. **Non-blocking Code**: Ensure no synchronous, blocking operations (e.g. heavy calculations, synchronous disk reads) are run on `@MainActor`.
                """
            case .gitGuidelines:
                ruleContent = """
                1. **Conventional Commits**: Format commit messages as `type(scope): description`. Common types include `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`.
                2. **Commit Headers**: Limit the subject line to 50 characters or less. Do not capitalize the first letter and do not end the subject line with a period.
                3. **Body Description**: Use the imperative tone (e.g., "fix issue" instead of "fixed issue" or "fixes issue").
                4. **Pre-commit Checks**: Compile, build, and run tests locally before committing. Never commit code that breaks the build.
                """
            case .blank:
                break
            }

            return """
            # \(name) (SkillKit Rule)

            \(ruleContent)
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
            
            let descriptionLine = descriptionFrontmatterLine(description)

            switch tool {
            case .claude, .cursor, .agents:
                return """
                ---
                name: \(skillID)
                \(descriptionLine)generator: skillkit
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
                \(descriptionLine)generator: skillkit
                ---

                # \(name) (SkillKit Skill)

                ## Instructions
                \(instructions)
                """
            }
        }
    }
}
