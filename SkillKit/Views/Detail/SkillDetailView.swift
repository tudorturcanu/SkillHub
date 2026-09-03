import SwiftUI
import SwiftData

/// Transparent NSView overlay that intercepts AppKit hit-testing so it owns
/// cursor management (pointing hand) and click handling, beating NSTextView's
/// aggressive I-beam cursor.
private struct ClickableCursorOverlay: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> OverlayNSView {
        let view = OverlayNSView()
        view.onTap = action
        return view
    }

    func updateNSView(_ nsView: OverlayNSView, context: Context) {
        nsView.onTap = action
    }

    final class OverlayNSView: NSView {
        var onTap: (() -> Void)?
        private var area: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow],
                owner: self
            )
            addTrackingArea(area!)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.pointingHand.set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) {
            onTap?()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

struct SkillDetailView: View {
    private enum ActiveAlert: Identifiable {
        case confirmDelete
        case confirmMakeGlobal
        case deleteError(String)
        case makeGlobalError(String)
        case restoreError(String)

        var id: String {
            switch self {
            case .confirmDelete:
                return "confirm-delete"
            case .confirmMakeGlobal:
                return "confirm-make-global"
            case .deleteError(let message):
                return "delete-error-\(message)"
            case .makeGlobalError(let message):
                return "make-global-error-\(message)"
            case .restoreError(let message):
                return "restore-error-\(message)"
            }
        }
    }

    @Bindable var skill: Skill
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @AppStorage("preferPreview") private var preferPreview = false
    @State private var document = SkillEditorDocument()
    @State private var activeAlert: ActiveAlert?
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var showingComposePanel = false
    @State private var showingLintFixes = false
    /// A lint fix awaiting before/after review. Nothing is written until Apply.
    @State private var pendingLintPreview: LintFixPreview?
    /// The skill `document` currently represents. Kept separately from `skill`
    /// so pending edits can be flushed to the *previous* skill when the
    /// selection changes underneath this view.
    @State private var loadedSkill: Skill?
    /// The `fileModifiedDate` we last accounted for; lets us tell a real
    /// external change apart from our own save or a selection switch.
    @State private var observedModifiedDate: Date?
    @State private var showingExternalChangeBar = false

    private enum ViewMode: String, CaseIterable, Identifiable {
        case edit
        case preview
        case playground

        var id: String { rawValue }
    }

    @State private var viewMode: ViewMode = .edit

    var body: some View {
        @Bindable var document = document

        VStack(spacing: 0) {
            if skill.isReadOnly {
                readOnlyBar
                Divider()
            }

            if showingExternalChangeBar {
                externalChangeBar
                Divider()
            }

            ZStack(alignment: .bottomTrailing) {
                switch viewMode {
                case .preview:
                    SkillPreviewView(content: document.editorContent)
                case .edit:
                    SkillEditorView(document: document, isEditable: !skill.isReadOnly)
                case .playground:
                    PromptPlaygroundView(skill: skill, promptTemplate: document.editorContent)
                }

                if viewMode != .playground && !showingComposePanel && !skill.isReadOnly {
                    composeFloatingButton
                }
            }

            // Inline compose panel
            if showingComposePanel {
                ComposePanel(
                    content: $document.editorContent,
                    isVisible: $showingComposePanel,
                    skillName: skill.name,
                    skillDescription: skill.skillDescription,
                    frontmatter: skill.frontmatter,
                    filePath: skill.filePath,
                    workingDirectory: URL(fileURLWithPath: skill.filePath).deletingLastPathComponent(),
                    templateType: WizardTemplateType(rawValue: skill.itemKind.rawValue) ?? .skill,
                    onAccept: { document.save(to: skill) }
                )
                .id(skill.filePath)
            }

            Divider()

            SkillMetadataBar(skill: skill, onRestoreSnapshot: restoreSnapshot)
        }
        .navigationTitle(skill.name)
        .onAppear {
            loadedSkill = skill
            observedModifiedDate = skill.fileModifiedDate
            document.load(from: skill)
            viewMode = preferPreview ? .preview : .edit
        }
        .onChange(of: viewMode) {
            if viewMode == .preview {
                preferPreview = true
            } else if viewMode == .edit {
                preferPreview = false
            }
        }
        .onChange(of: skill.filePath) { _, _ in
            // Flush edits to the skill we were showing before repointing the document.
            flushPendingSave()
            showingExternalChangeBar = false
            loadedSkill = skill
            observedModifiedDate = skill.fileModifiedDate
            document.load(from: skill)
        }
        .onChange(of: skill.fileModifiedDate) { _, _ in
            handleFileModifiedDateChange()
        }
        .onChange(of: document.editorContent) {
            scheduleAutosave()
        }
        .onDisappear {
            flushPendingSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveCurrentSkill)) { _ in
            guard !skill.isReadOnly else { return }
            autoSaveTask?.cancel()
            showingExternalChangeBar = false
            document.save(to: skill)
        }
        .onReceive(NotificationCenter.default.publisher(for: .applicationWillTerminate)) { _ in
            flushPendingSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteCurrentSkill)) { _ in
            guard !skill.isReadOnly else { return }
            activeAlert = .confirmDelete
        }
        .onReceive(NotificationCenter.default.publisher(for: .setDetailViewMode)) { notification in
            guard let raw = notification.object as? String,
                  let mode = ViewMode(rawValue: raw) else { return }
            viewMode = mode
        }
        .sheet(item: $pendingLintPreview) { preview in
            LintFixPreviewSheet(
                preview: preview,
                onApply: commitLintFix,
                onCancel: { pendingLintPreview = nil }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .jumpToEditorLine)) { notification in
            // Findings inside bundled scripts point at another file; only the
            // main document can be scrolled to here.
            guard notification.userInfo?["file"] == nil,
                  let line = notification.userInfo?["line"] as? Int else { return }
            viewMode = .edit
            // Give the editor a moment to mount if we just switched to it.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                NotificationCenter.default.post(
                    name: .scrollEditorToLine,
                    object: nil,
                    userInfo: ["line": line]
                )
            }
        }
        .alert("Save Error", isPresented: $document.showingSaveError) {
            Button("OK") {}
        } message: {
            Text(document.saveErrorMessage)
        }
        .toolbar {
            ToolbarItem {
                Picker("Mode", selection: $viewMode) {
                    Label("Edit", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .tag(ViewMode.edit)
                    Label("Preview", systemImage: "eye")
                        .labelStyle(.iconOnly)
                        .tag(ViewMode.preview)
                    Label("Prompt Playground", systemImage: "play.circle")
                        .labelStyle(.iconOnly)
                        .tag(ViewMode.playground)
                }
                .pickerStyle(.segmented)
                .help("Switch view mode: Edit, Preview, or Prompt Playground")
                .accessibilityLabel("View mode")
            }
            ToolbarItem {
                Button {
                    skill.isFavorite.toggle()
                    try? modelContext.save()
                } label: {
                    Image(systemName: skill.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(skill.isFavorite ? .yellow : .secondary)
                }
                .help(skill.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                .accessibilityLabel("Favorite")
                .accessibilityValue(skill.isFavorite ? "On" : "Off")
            }
            if !skill.isReadOnly {
                ToolbarItem {
                    Button {
                        showingLintFixes.toggle()
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .help("Lint fixes")
                    .accessibilityLabel("Lint fixes")
                    .popover(isPresented: $showingLintFixes) {
                        SkillLintFixesView(
                            fixes: SkillLinter.fixes(for: document.editorContent, skill: skill),
                            onApply: applyLintFix
                        )
                    }
                }
            }
            if !skill.isRemote {
                ToolbarItem {
                    Button {
                        NSWorkspace.shared.selectFile(skill.filePath, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
                }
            }
            if !skill.isReadOnly {
                ToolbarItem {
                    Button {
                        activeAlert = .confirmDelete
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Move \(skill.displayTypeName) to Trash")
                    .accessibilityLabel("Move to Trash")
                }
                ToolbarItem {
                    Button {
                        appState.skillToDuplicate = skill
                        appState.showingDuplicateSkillSheet = true
                    } label: {
                        Image(systemName: "plus.square.on.square")
                    }
                    .help("Duplicate \(skill.displayTypeName)")
                    .accessibilityLabel("Duplicate")
                }
            }
            if skill.canMakeGlobal {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        activeAlert = .confirmMakeGlobal
                    } label: {
                        Image(systemName: "globe")
                    }
                    .help("Make Global")
                    .accessibilityLabel("Make Global")
                }
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .confirmMakeGlobal:
                return Alert(
                    title: Text("Make \"\(skill.name)\" Global?"),
                    message: Text("This will move the skill to your global SkillKit library and symlink it to supported agent folders."),
                    primaryButton: .default(Text("Make Global")) {
                        makeSkillGlobal()
                    },
                    secondaryButton: .cancel()
                )
            case .confirmDelete:
                return Alert(
                    title: Text("Move \"\(skill.name)\" to Trash?"),
                    message: Text("This will move the \(skill.displayTypeName.lowercased()) to the Trash."),
                    primaryButton: .destructive(Text("Move to Trash")) {
                        deleteSkill()
                    },
                    secondaryButton: .cancel()
                )
            case .deleteError(let message):
                return Alert(
                    title: Text("Move to Trash Failed"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            case .makeGlobalError(let message):
                return Alert(
                    title: Text("Make Global Failed"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            case .restoreError(let message):
                return Alert(
                    title: Text("Restore Failed"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var readOnlyBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Read-only — this skill is managed by its plugin.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Duplicate to Edit") {
                appState.skillToDuplicate = skill
                appState.showingDuplicateSkillSheet = true
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var externalChangeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("This file changed on disk.")
                .font(.callout)
            Spacer()
            Button("Reload") {
                reloadFromDisk()
            }
            .controlSize(.small)
            .help("Discard your unsaved edits and load the version on disk")
            Button("Keep Mine") {
                keepLocalEdits()
            }
            .controlSize(.small)
            .help("Keep your edits; the next save overwrites the file on disk")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private var composeFloatingButton: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.accentColor))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .overlay(ClickableCursorOverlay(action: { [self] in showingComposePanel.toggle() }))
            .help("Compose with AI")
            .padding(16)
    }

    private func makeSkillGlobal() {
        do {
            try skill.makeGlobal()
            try? modelContext.save()
        } catch {
            activeAlert = .makeGlobalError(error.localizedDescription)
        }
    }

    private func deleteSkill() {
        guard !skill.isReadOnly else { return }
        do {
            try skill.deleteFromDisk()
            // Nothing left to flush: the file is in the Trash and the model is going away.
            autoSaveTask?.cancel()
            autoSaveTask = nil
            loadedSkill = nil
            showingExternalChangeBar = false
            appState.selectedSkill = nil
            modelContext.delete(skill)
            try modelContext.save()
        } catch {
            activeAlert = .deleteError(error.localizedDescription)
        }
    }

    // MARK: - Autosave & external changes

    private func scheduleAutosave() {
        guard !skill.isReadOnly else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            // While the "changed on disk" bar is up, hold off so we don't
            // silently clobber the external edit before the user decides.
            guard !Task.isCancelled, document.hasUnsavedChanges, !showingExternalChangeBar else { return }
            document.save(to: skill)
        }
    }

    /// Writes pending edits to the skill this document currently represents.
    /// Called before the document is repointed at another skill or torn down,
    /// so a selection change within the 1s autosave window never loses work.
    private func flushPendingSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        guard document.hasUnsavedChanges, let previous = loadedSkill else { return }
        guard !previous.isDeleted, previous.modelContext != nil, !previous.isReadOnly else { return }
        // Never resurrect a file that was just trashed or removed by a rescan.
        guard document.fileExistsOnDisk(for: previous) else { return }
        // The file changed underneath us and the user hasn't resolved it yet
        // (or the change landed between the last check and now). Writing here
        // would silently discard the other editor's version, so keep the buffer
        // and let the conflict bar handle it when this skill is reopened.
        guard !showingExternalChangeBar, !document.hasExternalChangeOnDisk(for: previous) else {
            AppLogger.fileIO.notice("Skipped autosave flush for \(previous.filePath): file changed on disk")
            return
        }
        document.save(to: previous)
    }

    /// Reacts to the file watcher's rescan updating `skill.fileModifiedDate`.
    /// Our own saves also bump it, so the on-disk bytes are compared against
    /// what the document last loaded/saved before treating it as external.
    private func handleFileModifiedDateChange() {
        // A selection switch changes the date too; onChange(filePath) owns that case.
        guard loadedSkill === skill else { return }
        guard skill.fileModifiedDate != observedModifiedDate else { return }
        observedModifiedDate = skill.fileModifiedDate
        guard !skill.isRemote, document.hasExternalChangeOnDisk(for: skill) else { return }

        if document.hasUnsavedChanges {
            showingExternalChangeBar = true
        } else {
            showingExternalChangeBar = false
            document.load(from: skill)
        }
    }

    private func reloadFromDisk() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        showingExternalChangeBar = false
        observedModifiedDate = skill.fileModifiedDate
        document.load(from: skill)
    }

    private func keepLocalEdits() {
        showingExternalChangeBar = false
        // Re-arm the autosave that was held back while the bar was visible.
        scheduleAutosave()
    }

    private func restoreSnapshot(_ snapshot: SkillVersionSnapshot) {
        guard !skill.isReadOnly, !skill.isRemote else { return }
        do {
            SkillVersionHistory.recordSnapshot(for: skill, content: document.editorContent, reason: "Before restore")
            try SkillVersionHistory.restore(snapshot, to: skill)
            document.load(from: skill)
            try? modelContext.save()
        } catch {
            activeAlert = .restoreError(error.localizedDescription)
        }
    }

    private func applyLintFix(_ fix: SkillLintFix) {
        showingLintFixes = false
        pendingLintPreview = fix.preview(document.editorContent, skill: skill)
    }

    private func commitLintFix(_ proposed: String) {
        SkillVersionHistory.recordSnapshot(for: skill, content: document.editorContent, reason: "Before lint fix")
        document.editorContent = proposed
        pendingLintPreview = nil
    }
}

private struct SkillLintFixesView: View {
    let fixes: [SkillLintFix]
    let onApply: (SkillLintFix) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lint Fixes")
                .font(.headline)

            if fixes.isEmpty {
                ContentUnavailableView(
                    "No Fixes",
                    systemImage: "checkmark.seal",
                    description: Text("No safe mechanical fixes are available.")
                )
                .frame(height: 160)
            } else {
                ForEach(fixes) { fix in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(fix.title)
                                .font(.subheadline.bold())
                            Text(fix.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Apply") {
                            onApply(fix)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding()
        .frame(width: 360, alignment: .leading)
    }
}
