import SwiftUI

struct PromptPlaygroundView: View {
    let skill: Skill
    let promptTemplate: String
    
    @State private var variables: [String: String] = [:]
    @State private var detectedVariableNames: [String] = []
    @State private var viewRawMode: Bool = false
    @State private var copySuccess: Bool = false
    
    var renderedContent: String {
        render(content: promptTemplate, variables: variables)
    }
    
    var body: some View {
        HSplitView {
            // Left Column: Variables editor
            variablesColumn
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 350)
                .background(Color(NSColor.windowBackgroundColor))
            
            // Right Column: Output Preview
            outputColumn
                .frame(minWidth: 350, maxWidth: .infinity)
        }
        .onAppear {
            scanVariables()
            preFillMocks()
        }
        .onChange(of: promptTemplate) {
            scanVariables()
        }
    }
    
    // MARK: - Variables Column
    
    private var variablesColumn: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Template Variables")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(detectedVariableNames.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            
            Divider()
            
            if detectedVariableNames.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No template variables found")
                        .font(.subheadline.bold())
                    Text("Variables like {{my_var}} or {my_var} will automatically appear here as inputs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(detectedVariableNames, id: \.self) { variableName in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(variableName)
                                        .font(.system(.subheadline, design: .monospaced))
                                        .bold()
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if isStandardVariable(variableName) {
                                        Text("context")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(.teal.opacity(0.15), in: Capsule())
                                            .foregroundStyle(.teal)
                                    }
                                }
                                
                                TextField("Enter value...", text: Binding(
                                    get: { variables[variableName] ?? "" },
                                    set: { variables[variableName] = $0 }
                                ), axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...5)
                            }
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                        }
                    }
                    .padding(12)
                }
            }
            
            Divider()
            
            // Actions
            HStack(spacing: 8) {
                Button {
                    preFillMocks()
                } label: {
                    Label("Fill Mocks", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(detectedVariableNames.isEmpty)
                .help("Pre-fill fields with template placeholders and skill data")
                
                Button {
                    clearAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(detectedVariableNames.isEmpty)
                .help("Clear all input variables")
            }
            .padding(12)
        }
    }
    
    // MARK: - Output Column
    
    private var outputColumn: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Picker("Preview Mode", selection: $viewRawMode) {
                    Text("Rendered").tag(false)
                    Text("Raw Text").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                
                Spacer()
                
                Button {
                    copyToClipboard()
                } label: {
                    Label(copySuccess ? "Copied" : "Copy Prompt", systemImage: copySuccess ? "checkmark.circle.fill" : "doc.on.clipboard")
                        .foregroundStyle(copySuccess ? .green : .primary)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(12)
            
            Divider()
            
            // Main Output content
            ZStack {
                if viewRawMode {
                    rawTextView
                } else {
                    SkillPreviewView(content: renderedContent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            // Metrics and Tokens
            metricsFooter
        }
        .background(Color(NSColor.textBackgroundColor))
    }
    
    private var rawTextView: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Text(renderedContent)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    private var metricsFooter: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("Characters:")
                    .foregroundStyle(.secondary)
                Text("\(renderedContent.count)")
                    .bold()
            }
            
            HStack(spacing: 4) {
                Text("Words:")
                    .foregroundStyle(.secondary)
                Text("\(wordCount)")
                    .bold()
            }
            
            Spacer()
            
            // Token Estimates
            HStack(spacing: 12) {
                tokenEstimateChip(label: "Claude Tokens", tokens: claudeTokenEstimate, color: .orange)
                tokenEstimateChip(label: "GPT Tokens", tokens: gptTokenEstimate, color: .blue)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func tokenEstimateChip(label: String, tokens: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(.secondary)
            Text("~\(tokens)")
                .bold()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
    }
    
    // MARK: - Helpers & Parsing
    
    private func scanVariables() {
        let doubleCurlyRegex = try? NSRegularExpression(pattern: "\\{\\{([a-zA-Z0-9_.-]+)\\}\\}", options: [])
        let range = NSRange(promptTemplate.startIndex..<promptTemplate.endIndex, in: promptTemplate)
        var vars = Set<String>()
        
        if let matches = doubleCurlyRegex?.matches(in: promptTemplate, options: [], range: range) {
            for match in matches {
                if let varRange = Range(match.range(at: 1), in: promptTemplate) {
                    vars.insert(String(promptTemplate[varRange]))
                }
            }
        }
        
        let singleCurlyRegex = try? NSRegularExpression(pattern: "(?<!\\{)\\{([a-zA-Z_][a-zA-Z0-9_.-]*)\\}(?!\\})", options: [])
        if let matches = singleCurlyRegex?.matches(in: promptTemplate, options: [], range: range) {
            for match in matches {
                if let varRange = Range(match.range(at: 1), in: promptTemplate) {
                    vars.insert(String(promptTemplate[varRange]))
                }
            }
        }
        
        self.detectedVariableNames = Array(vars).sorted()
    }
    
    private func preFillMocks() {
        for name in detectedVariableNames {
            variables[name] = mockValue(for: name)
        }
    }
    
    private func clearAll() {
        for name in detectedVariableNames {
            variables[name] = ""
        }
    }
    
    private func isStandardVariable(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "skill_name" || lower == "name" || lower == "title" ||
               lower == "skill_description" || lower == "description" || lower == "desc" ||
               lower == "file_path" || lower == "path" || lower == "frontmatter" || lower == "kind"
    }
    
    private func mockValue(for name: String) -> String {
        let lower = name.lowercased()
        if lower == "skill_name" || lower == "name" || lower == "title" {
            return skill.name
        } else if lower == "skill_description" || lower == "description" || lower == "desc" {
            return skill.skillDescription
        } else if lower == "file_path" || lower == "path" {
            return skill.filePath
        } else if lower == "frontmatter" {
            if skill.frontmatter.isEmpty {
                return "title: \(skill.name)\ndescription: \(skill.skillDescription)"
            } else {
                return skill.frontmatter.sorted(by: { $0.key < $1.key })
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: "\n")
            }
        } else if lower == "kind" {
            return skill.itemKind.rawValue
        } else if lower.contains("date") {
            return Date.now.formatted(date: .abbreviated, time: .shortened)
        } else if lower.contains("author") {
            return "Developer"
        } else if lower.contains("version") {
            return "1.0.0"
        } else {
            return ""
        }
    }
    
    private func render(content: String, variables: [String: String]) -> String {
        var result = content
        for (key, value) in variables {
            let replacement = value.isEmpty ? "{{\(key)}}" : value
            result = result.replacingOccurrences(of: "{{\(key)}}", with: replacement)
            
            let singleReplacement = value.isEmpty ? "{\(key)}" : value
            result = result.replacingOccurrences(of: "{\(key)}", with: singleReplacement)
        }
        return result
    }
    
    private var wordCount: Int {
        renderedContent.split { $0.isWhitespace || $0.isNewline }.count
    }
    
    private var claudeTokenEstimate: Int {
        max(1, Int(Double(renderedContent.count) / 4.1))
    }
    
    private var gptTokenEstimate: Int {
        max(1, Int(Double(renderedContent.count) / 4.0))
    }
    
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(renderedContent, forType: .string)
        copySuccess = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copySuccess = false
        }
    }
}
