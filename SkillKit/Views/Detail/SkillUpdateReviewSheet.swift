import SwiftUI

struct SkillUpdateReviewSheet: View {
    let proposal: SkillUpdateProposal
    let onApply: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var resolution: String
    @State private var isResolving = false
    @State private var reviewedResolution = false
    @State private var errorMessage: String?

    init(proposal: SkillUpdateProposal, onApply: @escaping (String) throws -> Void) {
        self.proposal = proposal
        self.onApply = onApply
        _resolution = State(initialValue: proposal.merged ?? proposal.local)
    }

    private var canApply: Bool { proposal.merged != nil || reviewedResolution }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review Skill Update").font(.headline)
                Text("\(proposal.upstream.source) · \(proposal.installed.revision.prefix(8)) → \(proposal.upstream.revision.prefix(8))")
                    .font(.caption).foregroundStyle(.secondary)
                if proposal.merged == nil {
                    Label("Local edits overlap this update. Resolve them manually before applying.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                    Text("The initial diff shows upstream changes. Your current file remains untouched.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if proposal.hasLocalEdits {
                    Label("Your local edits are included in the proposed result.", systemImage: "checkmark.circle")
                        .font(.callout)
                }
            }
            .padding()
            Divider()
            if isResolving {
                HSplitView {
                    VStack(alignment: .leading) {
                        Text("Upstream Version").font(.headline)
                        ScrollView {
                            Text(proposal.upstream.content)
                                .font(.body.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding().frame(minWidth: 280)
                    VStack(alignment: .leading) {
                        Text("Resolved Version (starts with your local file)").font(.headline)
                        TextEditor(text: $resolution)
                            .font(.body.monospaced())
                            .accessibilityLabel("Resolved skill content")
                    }.padding().frame(minWidth: 280)
                }
            } else {
                DiffReviewPanel(
                    original: canApply ? proposal.local : proposal.installed.content,
                    proposed: canApply ? resolution : proposal.upstream.content,
                    onAccept: nil, onReject: nil,
                    title: canApply ? "Current File → Proposed Result" : "Upstream Changes"
                )
                .id(reviewedResolution)
            }
            Divider()
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout).padding()
            }
            HStack {
                Text("The previous file is saved in History before applying.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if proposal.merged == nil {
                    Button(isResolving ? "Review Resolution" : "Resolve Manually") {
                        if isResolving { reviewedResolution = true }
                        isResolving.toggle()
                    }
                }
                Button("Apply Update") {
                    do {
                        try onApply(resolution)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply || isResolving || errorMessage != nil)
            }.padding()
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 520, idealHeight: 650)
    }
}
