import SwiftUI
import AppKit
import os

@MainActor
@Observable
final class SkillEditorDocument {
    var editorContent: String = "" {
        didSet {
            guard !isLoading else { return }
            hasUnsavedChanges = editorContent != fullFileContent
        }
    }
    var hasUnsavedChanges = false
    var isLoadingRemote = false
    var isSavingRemote = false
    var showingSaveError = false
    var saveErrorMessage = ""
    /// When this document last wrote successfully (local or remote). Reset on load.
    var lastSaveDate: Date?

    private var fullFileContent: String = ""
    private var isLoading = false
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    func load(from skill: Skill) {
        if skill.isRemote {
            loadRemote(skill)
        } else {
            loadLocal(skill)
        }
    }

    func save(to skill: Skill) {
        if skill.isRemote {
            saveRemote(skill)
        } else {
            saveLocal(skill)
        }
    }

    /// Whether the file on disk differs from what this document last loaded or
    /// saved. Used to tell an external edit apart from a rescan that merely
    /// re-observed our own write (same bytes, possibly a slightly different mtime).
    func hasExternalChangeOnDisk(for skill: Skill) -> Bool {
        guard !skill.isRemote, !isLoading else { return false }
        guard let onDisk = Self.readLocalFile(at: skill.filePath) else { return false }
        return onDisk != fullFileContent
    }

    /// Whether a local skill's file is still present (checked with sandbox access).
    /// Remote skills always report `true`.
    func fileExistsOnDisk(for skill: Skill) -> Bool {
        guard !skill.isRemote else { return true }
        let path = skill.filePath
        return SandboxBookmarkManager.resolveAndAccess(path: Self.accessRoot(for: path)) { _ in
            FileManager.default.fileExists(atPath: path)
        }
    }

    // MARK: - Local

    /// The bookmarked root that grants sandbox access to `path`.
    nonisolated private static func accessRoot(for path: String) -> String {
        let customPaths = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
        let sotDir = SkillKitSettings.sotDir
        return ([sotDir] + customPaths).first(where: { path.hasPrefix($0) }) ?? path
    }

    nonisolated private static func readLocalFile(at path: String) -> String? {
        SandboxBookmarkManager.resolveAndAccess(path: accessRoot(for: path)) { _ in
            try? String(contentsOfFile: path, encoding: .utf8)
        }
    }

    private func loadLocal(_ skill: Skill) {
        isLoading = true
        loadTask?.cancel()
        loadGeneration += 1

        let path = skill.filePath
        let fallback = skill.content
        let generation = loadGeneration

        loadTask = Task.detached { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()
            let parentPath = Self.accessRoot(for: path)

            let data = SandboxBookmarkManager.resolveAndAccess(path: parentPath) { _ in
                if let fileData = try? String(contentsOfFile: path, encoding: .utf8) {
                    return fileData
                }
                return ""
            }
            let finalData = data.isEmpty && !fallback.isEmpty ? fallback : data
            guard !Task.isCancelled else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            AppLogger.fileIO.notice("Loaded \(path) in \(String(format: "%.3f", elapsed))s (\(finalData.count) chars)")

            await MainActor.run { [weak self, finalData] in
                guard let self, self.loadGeneration == generation else { return }
                self.editorContent = finalData
                self.fullFileContent = finalData
                self.isLoading = false
                self.hasUnsavedChanges = false
                self.showingSaveError = false
                self.saveErrorMessage = ""
                self.lastSaveDate = nil
            }
        }
    }

    private func saveLocal(_ skill: Skill) {
        let path = skill.filePath
        let parentPath = Self.accessRoot(for: path)

        SandboxBookmarkManager.resolveAndAccess(path: parentPath) { _ in
            do {
                SkillVersionHistory.recordSnapshot(for: skill, content: fullFileContent, reason: "Before save")
                SkillScanner.active?.ignoreNextChange(for: skill.filePath)
                try editorContent.write(toFile: skill.filePath, atomically: true, encoding: .utf8)
                fullFileContent = editorContent
                hasUnsavedChanges = false
                lastSaveDate = .now

                let parsed = FrontmatterParser.parse(editorContent)
                if !parsed.name.isEmpty {
                    skill.name = parsed.name
                }
                skill.skillDescription = parsed.description
                skill.content = parsed.content
                skill.frontmatter = parsed.frontmatter

                let attrs = try? FileManager.default.attributesOfItem(atPath: skill.filePath)
                skill.fileModifiedDate = (attrs?[.modificationDate] as? Date) ?? skill.fileModifiedDate
                skill.fileSize = (attrs?[.size] as? Int) ?? skill.fileSize
                AppLogger.fileIO.info("Saved: \(skill.filePath)")
            } catch {
                AppLogger.fileIO.error("Save failed: \(error.localizedDescription)")
                saveErrorMessage = error.localizedDescription
                showingSaveError = true
            }
        }
    }

    // MARK: - Remote

    private func loadRemote(_ skill: Skill) {
        guard let server = skill.remoteServer, let remotePath = skill.remotePath else {
            editorContent = skill.content
            fullFileContent = skill.content
            return
        }

        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let fallbackContent = skill.content

        isLoading = true
        isLoadingRemote = true

        loadTask = Task {
            do {
                let content = try await SSHService.readFile(server, path: remotePath)
                guard !Task.isCancelled, loadGeneration == generation else { return }
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    editorContent = content
                    fullFileContent = content
                    isLoading = false
                    isLoadingRemote = false
                    hasUnsavedChanges = false
                    showingSaveError = false
                    saveErrorMessage = ""
                    lastSaveDate = nil
                }
            } catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    editorContent = fallbackContent
                    fullFileContent = fallbackContent
                    isLoading = false
                    isLoadingRemote = false
                    hasUnsavedChanges = false
                    saveErrorMessage = "Failed to load from server: \(error.localizedDescription)"
                    showingSaveError = true
                }
            }
        }
    }

    private func saveRemote(_ skill: Skill) {
        guard let server = skill.remoteServer, let remotePath = skill.remotePath else {
            saveErrorMessage = "Missing remote server or path"
            showingSaveError = true
            return
        }

        isSavingRemote = true

        // Capture what we are writing now: the editor may already show a
        // different skill by the time the SSH write completes (e.g. a flush
        // triggered by switching selection).
        let contentToWrite = editorContent
        let previousContent = fullFileContent
        let generation = loadGeneration

        Task {
            do {
                try await SSHService.writeFile(server, path: remotePath, content: contentToWrite)
                await MainActor.run {
                    SkillVersionHistory.recordSnapshot(for: skill, content: previousContent, reason: "Before remote save")
                    isSavingRemote = false

                    // Only touch document state if this document still shows the saved skill.
                    if loadGeneration == generation {
                        fullFileContent = contentToWrite
                        hasUnsavedChanges = editorContent != contentToWrite
                        lastSaveDate = .now
                    }

                    let parsed = FrontmatterParser.parse(contentToWrite)
                    let nameToSave = parsed.name
                    let descToSave = parsed.description
                    let contentToSave = parsed.content
                    let frontmatterToSave = parsed.frontmatter
                    let sizeToSave = contentToWrite.utf8.count

                    if !nameToSave.isEmpty {
                        skill.name = nameToSave
                    }
                    skill.skillDescription = descToSave
                    skill.content = contentToSave
                    skill.frontmatter = frontmatterToSave
                    skill.fileModifiedDate = .now
                    skill.fileSize = sizeToSave
                }
            } catch {
                await MainActor.run {
                    saveErrorMessage = error.localizedDescription
                    showingSaveError = true
                    isSavingRemote = false
                }
            }
        }
    }
}

struct SkillEditorView: View {
    @Bindable var document: SkillEditorDocument
    var isEditable: Bool = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if document.isLoadingRemote {
                VStack {
                    ProgressView("Loading from server...")
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HighlightedTextEditor(text: $document.editorContent, isEditable: isEditable)
            }

            HStack(spacing: 6) {
                if document.isSavingRemote {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isEditable, !document.isLoadingRemote {
                    if document.hasUnsavedChanges {
                        Text("Unsaved changes")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if let saved = document.lastSaveDate {
                        Text("Saved \(saved, format: .dateTime.hour().minute())")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(12)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Save notification for Cmd+S menu support

extension Notification.Name {
    static let saveCurrentSkill = Notification.Name("saveCurrentSkill")
}

// MARK: - Syntax-highlighted NSTextView wrapper

struct HighlightedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = SkillKitTextView()
        textView.isEditable = isEditable
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // Font & colors
        textView.font = EditorTheme.editorFont
        textView.textColor = EditorTheme.textColor
        textView.backgroundColor = .clear

        // Line height with baseline centering
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = EditorTheme.editorLineHeight
        paragraph.maximumLineHeight = EditorTheme.editorLineHeight
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: EditorTheme.editorFont,
            .foregroundColor: EditorTheme.textColor,
            .paragraphStyle: paragraph,
            .baselineOffset: EditorTheme.editorBaselineOffset
        ]

        // Insets
        textView.textContainerInset = NSSize(width: EditorTheme.editorInsetX, height: EditorTheme.editorInsetTop)
        textView.textContainer?.lineFragmentPadding = 0

        // Layout
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true

        textView.insertionPointColor = EditorTheme.textColor

        // Set up highlighter and coordinator
        let highlighter = MarkdownSyntaxHighlighter()
        context.coordinator.highlighter = highlighter
        context.coordinator.textView = textView

        // Set text BEFORE attaching delegate to avoid triggering textDidChange during setup
        textView.string = text
        textView.delegate = context.coordinator

        scrollView.documentView = textView

        // Initial highlight
        highlighter.highlightAll(textView.textStorage!)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SkillKitTextView else { return }

        context.coordinator.parent = self
        textView.isEditable = isEditable

        // Re-highlight on appearance change
        let currentScheme = colorScheme
        if context.coordinator.lastColorScheme != currentScheme {
            context.coordinator.lastColorScheme = currentScheme
            textView.insertionPointColor = EditorTheme.textColor

            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = EditorTheme.editorLineHeight
            paragraph.maximumLineHeight = EditorTheme.editorLineHeight
            textView.typingAttributes = [
                .font: EditorTheme.editorFont,
                .foregroundColor: EditorTheme.textColor,
                .paragraphStyle: paragraph,
                .baselineOffset: EditorTheme.editorBaselineOffset
            ]

            context.coordinator.isHighlightingInProgress = true
            context.coordinator.highlighter?.highlightAll(textView.textStorage!)
            context.coordinator.isHighlightingInProgress = false
        }

        // Only update text if it changed externally (not from user typing)
        if !context.coordinator.isUpdating && textView.string != text {
            context.coordinator.isUpdating = true
            let selectedRanges = textView.selectedRanges
            textView.string = text
            context.coordinator.isHighlightingInProgress = true
            context.coordinator.highlighter?.highlightAll(textView.textStorage!)
            context.coordinator.isHighlightingInProgress = false
            textView.selectedRanges = selectedRanges
            context.coordinator.isUpdating = false
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightedTextEditor
        var isUpdating = false
        var isHighlightingInProgress = false
        var highlighter: MarkdownSyntaxHighlighter?
        weak var textView: SkillKitTextView?
        var lastColorScheme: ColorScheme?

        init(_ parent: HighlightedTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if isUpdating { return }

            // Highlight synchronously so colors appear on the same frame
            isHighlightingInProgress = true
            highlighter?.highlightAll(textView.textStorage!)
            isHighlightingInProgress = false

            // Update binding asynchronously to prevent re-entrant updateNSView
            let newText = textView.string
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isUpdating = true
                self.parent.text = newText
                self.isUpdating = false
            }
        }
    }
}
