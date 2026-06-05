import SwiftUI
import SwiftData

struct ReleaseReadinessView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var copiedField: ListingField?

    private let appStoreConnectURL = URL(string: "https://appstoreconnect.apple.com/apps")!
    private let appReviewURL = URL(string: "https://developer.apple.com/app-store/review/guidelines/")!

    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? "SkillKit"
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var category: String {
        Bundle.main.infoDictionary?["LSApplicationCategoryType"] as? String ?? "Missing"
    }

    private var configuredPaths: [String] {
        UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
    }

    private var grantedPathCount: Int {
        configuredPaths.filter {
            UserDefaults.standard.data(forKey: "bookmark_\($0)") != nil
        }.count
    }

    private var hasSelfUpdateMetadata: Bool {
        Bundle.main.infoDictionary?["SUFeedURL"] != nil
            || Bundle.main.infoDictionary?["SUPublicEDKey"] != nil
    }

    private var hasPrivacyManifest: Bool {
        Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil
    }

    private var releaseNotes: String {
        """
        SkillKit 1.0 introduces a native macOS workspace for discovering, organizing, editing, and reusing AI coding-agent skills across Codex, Claude, Gemini, GitHub Copilot, Cursor, Amp, Windsurf, and OpenCode.
        """
    }

    private var listingFields: [ListingField] {
        [
            ListingField(
                title: "App Name",
                limit: 30,
                text: "SkillKit"
            ),
            ListingField(
                title: "Subtitle",
                limit: 30,
                text: "AI agent skill manager"
            ),
            ListingField(
                title: "Promotional Text",
                limit: 170,
                text: "Organize, edit, and reuse coding-agent skills from Codex, Claude, Gemini, Copilot, Cursor, Amp, Windsurf, and more in one native Mac app."
            ),
            ListingField(
                title: "Keywords",
                limit: 100,
                text: "ai,coding,agents,skills,prompts,codex,claude,developer,swift,mac"
            ),
            ListingField(
                title: "What's New",
                limit: 4000,
                text: releaseNotes
            )
        ]
    }

    private var checks: [ReleaseCheck] {
        [
            ReleaseCheck(
                title: "Bundle Identifier",
                detail: bundleID,
                state: bundleID == "alice.turcanu.com.SkillKit" ? .ready : .warning
            ),
            ReleaseCheck(
                title: "Version and Build",
                detail: "\(version) (\(build))",
                state: version != "?" && build != "?" ? .ready : .missing
            ),
            ReleaseCheck(
                title: "App Category",
                detail: category,
                state: category == "public.app-category.developer-tools" ? .ready : .warning
            ),
            ReleaseCheck(
                title: "Sandbox Folder Access",
                detail: "\(grantedPathCount) of \(configuredPaths.count) configured paths have stored access grants",
                state: configuredPaths.isEmpty ? .warning : (grantedPathCount == configuredPaths.count ? .ready : .warning)
            ),
            ReleaseCheck(
                title: "Self-update Metadata",
                detail: hasSelfUpdateMetadata ? "Sparkle keys are present; remove direct-update behavior for Mac App Store builds." : "No direct updater metadata found.",
                state: hasSelfUpdateMetadata ? .warning : .ready
            ),
            ReleaseCheck(
                title: "Privacy Manifest",
                detail: hasPrivacyManifest ? "PrivacyInfo.xcprivacy is bundled." : "Add a privacy manifest before uploading to App Store Connect.",
                state: hasPrivacyManifest ? .ready : .missing
            )
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                readinessSummary
                checklist
                listingCopy
                releaseActions
            }
            .padding()
        }
        .frame(height: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Release Readiness")
                .font(.headline)

            Text("\(appName) \(version) build \(build)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var readinessSummary: some View {
        HStack(spacing: 10) {
            ReleaseMetric(
                title: "Ready",
                value: "\(checks.filter { $0.state == .ready }.count)",
                icon: "checkmark.seal.fill",
                color: .green
            )
            ReleaseMetric(
                title: "Review",
                value: "\(checks.filter { $0.state == .warning }.count)",
                icon: "exclamationmark.triangle.fill",
                color: .orange
            )
            ReleaseMetric(
                title: "Missing",
                value: "\(checks.filter { $0.state == .missing }.count)",
                icon: "xmark.octagon.fill",
                color: .red
            )
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checklist")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 0) {
                ForEach(checks) { check in
                    ReleaseCheckRow(check: check)

                    if check.id != checks.last?.id {
                        Divider()
                            .padding(.leading, 34)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var listingCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Listing Copy")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 0) {
                ForEach(listingFields) { field in
                    ListingCopyRow(
                        field: field,
                        copiedField: copiedField
                    ) {
                        copy(field)
                    }

                    if field.id != listingFields.last?.id {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var releaseActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Actions")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(appStoreConnectURL)
                } label: {
                    Label("App Store Connect", systemImage: "arrow.up.forward.app")
                }

                Button {
                    NSWorkspace.shared.open(appReviewURL)
                } label: {
                    Label("Review Guidelines", systemImage: "book.pages")
                }

                Button {
                    DiagnosticExporter.export(modelContext: modelContext)
                } label: {
                    Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func copy(_ field: ListingField) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(field.text, forType: .string)
        copiedField = field

        Task {
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                if copiedField == field {
                    copiedField = nil
                }
            }
        }
    }
}

private struct ReleaseMetric: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Spacer()
                Text(value)
                    .font(.title2.weight(.bold))
            }

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ReleaseCheckRow: View {
    let check: ReleaseCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.state.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(check.state.color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                    .font(.body.weight(.medium))

                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
    }
}

private struct ListingCopyRow: View {
    let field: ListingField
    let copiedField: ListingField?
    let copy: () -> Void

    private var isWithinLimit: Bool {
        field.text.count <= field.limit
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(field.title)
                        .font(.body.weight(.medium))

                    Text("\(field.text.count)/\(field.limit)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isWithinLimit ? Color.secondary : Color.red)
                }

                Text(field.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(field.limit > 200 ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                copy()
            } label: {
                Image(systemName: copiedField == field ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy \(field.title)")
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
    }
}

private struct ReleaseCheck: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let state: ReleaseCheckState
}

private enum ReleaseCheckState: Equatable {
    case ready
    case warning
    case missing

    var icon: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .missing: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .warning: .orange
        case .missing: .red
        }
    }
}

private struct ListingField: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let limit: Int
    let text: String
}
