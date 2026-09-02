import SwiftUI

/// Before/after review for a lint quick-fix. Nothing is written until the
/// user clicks Apply; `onApply` receives the proposed full text.
///
/// Present it from the detail view:
///
///     .sheet(item: $pendingLintPreview) { preview in
///         LintFixPreviewSheet(
///             preview: preview,
///             onApply: { proposed in
///                 SkillVersionHistory.recordSnapshot(for: skill, content: document.editorContent, reason: "Before lint fix")
///                 document.editorContent = proposed
///                 pendingLintPreview = nil
///             },
///             onCancel: { pendingLintPreview = nil }
///         )
///     }
///
/// where `pendingLintPreview = fix.preview(document.editorContent, skill: skill)`.
struct LintFixPreviewSheet: View {
    let preview: LintFixPreview
    let onApply: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if preview.hasChanges {
                DiffReviewPanel(
                    original: preview.original,
                    proposed: preview.proposed,
                    onAccept: nil,
                    onReject: nil
                )
            } else {
                ContentUnavailableView(
                    "Nothing to Change",
                    systemImage: "checkmark.seal",
                    description: Text("This fix would leave the file exactly as it is.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.accentColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(preview.fix.title)
                    .font(.headline)
                Text(preview.fix.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Text("Review the changes above. Nothing is saved until you click Apply.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button("Apply") {
                onApply(preview.proposed)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!preview.hasChanges)
        }
        .padding(12)
    }
}
