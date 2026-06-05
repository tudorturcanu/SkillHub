import SwiftUI

struct OnboardingView: View {
    @Binding var didCompleteOnboarding: Bool
    @State private var selectedPlatformIDs = Set(PlatformOption.onboarding.map(\.id))
    @State private var step: OnboardingStep = .platforms
    @State private var grantedPaths: Set<String> = []
    @State private var syncingPaths: Set<String> = []

    private enum OnboardingStep {
        case platforms
        case folders
    }

    private var selectedPlatforms: [PlatformOption] {
        PlatformOption.onboarding.filter { selectedPlatformIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .platforms:
                platformSelection
            case .folders:
                folderSetup
            }

            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            refreshGrantedPaths()
        }
    }

    private var platformSelection: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose your platforms")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.primary)

                Text("You can use SkillKit with Codex, Claude, Gemini, GitHub Copilot, or multiple platforms. You can change this later in Settings.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 960, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 22) {
                ForEach(PlatformOption.onboarding) { option in
                    PlatformToggleRow(
                        option: option,
                        isSelected: selectedPlatformIDs.contains(option.id)
                    ) {
                        toggle(option)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 48)
        .padding(.horizontal, 48)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var folderSetup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Set up folders")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Grant SkillKit access to each selected platform folder so it can scan, install, and sync your skills.")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 960, alignment: .leading)
                }

                ForEach(selectedPlatforms) { option in
                    platformFolderCards(for: option)
                }
            }
            .padding(.top, 48)
            .padding(.horizontal, 48)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func platformFolderCards(for option: PlatformOption) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            FolderAccessCard(
                title: "\(option.displayName) User Skills",
                path: option.expandedSkillsPath,
                expectedPath: option.shortSkillsPath,
                buttonTitle: "Choose \(option.displayName) User Folder",
                isGranted: isGranted(option.expandedSkillsPath),
                isSyncing: syncingPaths.contains(option.expandedSkillsPath),
                isRequired: false
            ) {
                chooseFolder(for: option.expandedSkillsPath)
            }

            if let xcodePath = option.expandedXcodePath {
                FolderAccessCard(
                    title: "\(option.displayName) Xcode Environment",
                    path: xcodePath,
                    expectedPath: "Choose the Xcode \(option.displayName) environment folder or its `skills` subfolder.",
                    buttonTitle: "Choose \(option.displayName) Xcode Folder",
                    isGranted: isGranted(xcodePath),
                    isSyncing: syncingPaths.contains(xcodePath),
                    isRequired: true
                ) {
                    chooseFolder(for: xcodePath)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") {
                if step == .folders {
                    step = .platforms
                }
            }
            .buttonStyle(.bordered)
            .disabled(step == .platforms)

            Spacer()

            Button(step == .platforms ? "Set Up Folders" : "Finish") {
                switch step {
                case .platforms:
                    step = .folders
                case .folders:
                    completeOnboarding()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedPlatformIDs.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func toggle(_ option: PlatformOption) {
        if selectedPlatformIDs.contains(option.id) {
            selectedPlatformIDs.remove(option.id)
        } else {
            selectedPlatformIDs.insert(option.id)
        }
    }

    private func isGranted(_ path: String) -> Bool {
        grantedPaths.contains(path) || UserDefaults.standard.data(forKey: "bookmark_\(path)") != nil
    }

    private func refreshGrantedPaths() {
        let paths = selectedPlatforms.flatMap { option in
            [option.expandedSkillsPath, option.expandedXcodePath].compactMap(\.self)
        }
        grantedPaths = Set(paths.filter { UserDefaults.standard.data(forKey: "bookmark_\($0)") != nil })
    }

    private func chooseFolder(for path: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        panel.prompt = "Grant Access"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                let grantedPath = url.path
                SandboxBookmarkManager.saveBookmark(for: url, customKey: grantedPath)
                grantedPaths.insert(grantedPath)

                if grantedPath != path {
                    SandboxBookmarkManager.saveBookmark(for: url, customKey: path)
                    grantedPaths.insert(path)
                }

                syncGrantedFolder(grantedPath, canonicalPath: path)
            }
        }
    }

    private func syncGrantedFolder(_ grantedPath: String, canonicalPath: String) {
        var scanPaths = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
        for path in [canonicalPath, grantedPath] where !scanPaths.contains(path) {
            scanPaths.append(path)
        }
        scanPaths.sort()
        UserDefaults.standard.set(scanPaths, forKey: "customScanPaths")
        UserDefaults.standard.set(false, forKey: "dismissed_\(canonicalPath)")
        UserDefaults.standard.set(false, forKey: "dismissed_\(grantedPath)")
        NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)

        syncingPaths.insert(canonicalPath)
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                _ = syncingPaths.remove(canonicalPath)
            }
        }
    }

    private func completeOnboarding() {
        let selectedPaths = selectedPlatforms.map(\.expandedSkillsPath)
        let xcodePaths = selectedPlatforms.compactMap(\.expandedXcodePath)
        let existingPaths = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
        let scanPaths = Array(Set(existingPaths + selectedPaths + xcodePaths)).sorted()

        let fileManager = FileManager.default
        for path in scanPaths {
            try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        UserDefaults.standard.set(scanPaths, forKey: "customScanPaths")
        for option in PlatformOption.onboarding {
            let isDismissed = !selectedPlatformIDs.contains(option.id)
            UserDefaults.standard.set(isDismissed, forKey: "dismissed_\(option.expandedSkillsPath)")
            if let xcodePath = option.expandedXcodePath {
                UserDefaults.standard.set(isDismissed, forKey: "dismissed_\(xcodePath)")
            }
        }
        didCompleteOnboarding = true
        NotificationCenter.default.post(name: .customScanPathsChanged, object: nil)
    }
}

private struct PlatformToggleRow: View {
    let option: PlatformOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(option.displayName)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(option.detail)
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct FolderAccessCard: View {
    let title: String
    let path: String
    let expectedPath: String
    let buttonTitle: String
    let isGranted: Bool
    let isSyncing: Bool
    let isRequired: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.primary)

                Text(statusTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(statusBackground)
                    .clipShape(Capsule())
            }

            Text(isGranted ? path : "No folder selected")
                .font(.system(size: 22))
                .foregroundStyle(isGranted ? Color.secondary : Color.red)

            Text(isGranted ? "Usually `\(expectedPath)`." : expectedPath)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)

            if !isGranted {
                Text("SkillKit cannot scan, install, or sync this destination until you grant access.")
                    .font(.system(size: 17))
                    .foregroundStyle(.red)
            }

            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: isRequired ? 620 : 360, alignment: .leading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(isGranted ? Color.clear : Color.red.opacity(0.35), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private var statusBackground: Color {
        if isSyncing { return Color.blue.opacity(0.12) }
        return isGranted ? Color.green.opacity(0.14) : Color.red.opacity(0.12)
    }

    private var cardBackground: Color {
        isGranted ? Color(NSColor.controlBackgroundColor) : Color.red.opacity(0.045)
    }

    private var statusTitle: String {
        if isSyncing { return "Syncing" }
        return isGranted ? "Granted" : "Access Needed"
    }

    private var statusColor: Color {
        if isSyncing { return .blue }
        return isGranted ? .green : .red
    }
}
