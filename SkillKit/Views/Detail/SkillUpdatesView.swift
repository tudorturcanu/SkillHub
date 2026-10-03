import SwiftUI

/// Per-file update action. Keyed by filePath in the detail view so a pending
/// network request or review can never follow the selection to another file.
struct SkillUpdatesView: View {
    let skill: Skill
    let document: SkillEditorDocument
    let prepareForCheck: () -> Void
    let didApply: () -> Void
    @State private var source: SkillSourceRevision?
    @State private var candidate: SkillSourceRevision?
    @State private var review: SkillUpdateProposal?
    @State private var showingPopover = false
    @State private var isChecking = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            Label(candidate == nil ? "Skill Updates" : "Update Available", systemImage: candidate == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                .foregroundStyle(candidate == nil ? Color.primary : Color.accentColor)
        }
        .help(candidate == nil ? "Check this skill for upstream updates" : "An upstream update is available")
        .popover(isPresented: $showingPopover) {
            VStack(alignment: .leading, spacing: 12) {
                Text(candidate == nil ? "Skill Updates" : "Update Available").font(.headline)
                if let source {
                    if let url = source.sourceURL {
                        Link(source.source, destination: url)
                    }
                    Text("\(source.path)\nBranch: \(source.branch) · Installed revision: \(source.revision.prefix(8))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let message { Text(message).font(.callout) }
                    if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
                    HStack {
                        if isChecking { ProgressView().controlSize(.small) }
                        Button(isChecking ? "Checking…" : "Check for Updates", action: check)
                            .disabled(isChecking || document.isLoadingContent)
                        if candidate != nil {
                            Button("Review Update", action: openReview)
                                .disabled(isChecking || document.isLoadingContent)
                        }
                    }
                } else {
                    Text(errorMessage ?? "No source revision is recorded for this file. New installs from Discover track their source automatically. Existing edited files need a known upstream baseline before they can be updated safely.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding().frame(width: 360)
        }
        .sheet(item: $review) { proposal in
            SkillUpdateReviewSheet(proposal: proposal) { resolved in
                guard !document.isLoadingContent, !document.hasUnsavedChanges,
                      document.editorContent == proposal.local else {
                    throw SkillUpdater.UpdateError.unsavedChanges
                }
                do {
                    try SkillUpdater.apply(proposal, resolvedContent: resolved, to: skill)
                } catch {
                    // A provenance error can occur after a successful file write.
                    didApply()
                    throw error
                }
                source = proposal.upstream
                candidate = nil
                message = "Update applied. Use History to restore the previous file."
                didApply()
            }
        }
        .task { loadSource() }
        .onChange(of: skill.fileModifiedDate) { loadSource() }
        .onDisappear { checkTask?.cancel() }
    }

    private func loadSource() {
        do {
            let recorded = try SandboxBookmarkManager.resolveAndAccess(path: SkillEditorDocument.accessRoot(for: skill.filePath)) { _ in
                try SkillSourceStore.load(for: skill.filePath)
            }
            // An ordinary autosave changes the modification date but not provenance.
            // In particular, flushing before Check must not cancel that new request.
            guard recorded != source else { return }
            checkTask?.cancel()
            candidate = nil
            message = nil
            errorMessage = nil
            source = recorded
        } catch {
            checkTask?.cancel()
            source = nil
            candidate = nil
            errorMessage = "Could not read source tracking: \(error.localizedDescription)"
        }
    }

    private func prepareLocalContent() throws -> String {
        prepareForCheck()
        guard !document.isLoadingContent, !document.loadFailed, !document.hasUnsavedChanges,
              !document.hasSaveConflict, !document.hasExternalChangeOnDisk(for: skill),
              let content = SkillEditorDocument.readLocalFile(at: skill.filePath) else {
            throw SkillUpdater.UpdateError.unsavedChanges
        }
        return content
    }

    private func check() {
        guard let source else { return }
        errorMessage = nil
        message = nil
        candidate = nil
        do { _ = try prepareLocalContent() } catch {
            errorMessage = error.localizedDescription
            return
        }
        isChecking = true
        checkTask?.cancel()
        checkTask = Task { @MainActor in
            defer { isChecking = false }
            do {
                let latest = try await SkillRegistry().fetchUpdate(for: source)
                try Task.checkCancellation()
                if latest.content == source.content {
                    message = "No upstream changes. Your local edits are unchanged."
                } else {
                    candidate = latest
                    message = "A new version is available. Review it before applying."
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openReview() {
        guard let source, let candidate else { return }
        do {
            let local = try prepareLocalContent()
            review = SkillUpdateProposal(filePath: skill.filePath, installed: source, upstream: candidate, local: local)
            showingPopover = false
        } catch { errorMessage = error.localizedDescription }
    }
}
