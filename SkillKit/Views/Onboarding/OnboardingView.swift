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
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.primary)

                Text("You can use SkillKit with Codex, Claude, Gemini, GitHub Copilot, or multiple platforms. You can change this later in Settings.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 960, alignment: .leading)
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 18),
                GridItem(.flexible(), spacing: 18)
            ], spacing: 18) {
                ForEach(PlatformOption.onboarding) { option in
                    PlatformCard(
                        option: option,
                        isSelected: selectedPlatformIDs.contains(option.id)
                    ) {
                        toggle(option)
                    }
                }
            }
            .frame(maxWidth: 720)

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
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Grant SkillKit access to each selected platform folder so it can scan, install, and sync your skills.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 960, alignment: .leading)
                }

                folderTable
                    .frame(maxWidth: 820)

                permissionWarningBanner
                    .frame(maxWidth: 820)
            }
            .padding(.top, 48)
            .padding(.horizontal, 48)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var folderItems: [FolderPermissionItem] {
        var items: [FolderPermissionItem] = []
        for option in selectedPlatforms {
            items.append(FolderPermissionItem(
                id: "\(option.id)_skills",
                platform: option,
                title: "\(option.displayName) User Skills",
                path: option.expandedSkillsPath,
                expectedPath: option.shortSkillsPath,
                buttonTitle: "Choose \(option.displayName) User Folder",
                isRequired: false,
                isXcode: false
            ))
            if let xcodePath = option.expandedXcodePath {
                items.append(FolderPermissionItem(
                    id: "\(option.id)_xcode",
                    platform: option,
                    title: "\(option.displayName) Xcode Environment",
                    path: xcodePath,
                    expectedPath: "Choose the Xcode \(option.displayName) environment folder or its `skills` subfolder.",
                    buttonTitle: "Choose \(option.displayName) Xcode Folder",
                    isRequired: true,
                    isXcode: true
                ))
            }
        }
        return items
    }

    private var folderTable: some View {
        VStack(spacing: 0) {
            // Table Header
            HStack(spacing: 16) {
                Text("Platform & Target")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)

                Text("Location")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Status")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .center)

                Text("Action")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider()

            // Table Body
            VStack(spacing: 0) {
                let items = folderItems
                if items.isEmpty {
                    Text("No platforms selected. Please go back and select at least one platform.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .padding(32)
                } else {
                    ForEach(items) { item in
                        FolderTableRow(
                            item: item,
                            isGranted: isGranted(item.path),
                            isSyncing: syncingPaths.contains(item.path)
                        ) {
                            chooseFolder(for: item.path)
                        }

                        if item.id != items.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var permissionWarningBanner: some View {
        let hasUngranted = folderItems.contains { !isGranted($0.path) }
        return Group {
            if hasUngranted {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Missing Folder Access")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                        Text("SkillKit cannot scan, install, or sync skills for targets marked as 'Access Needed' until access is granted.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.15), lineWidth: 1)
                )
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

// MARK: - PlatformCard

private struct PlatformCard: View {
    let option: PlatformOption
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    // Beautiful platform icon badge
                    Image(systemName: option.iconName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(option.color)
                        .frame(width: 44, height: 44)
                        .background(option.color.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Spacer()

                    // Selection indicator
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(option.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(option.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.15) : Color.primary.opacity(0.06)), lineWidth: 1.5)
            )
            .scaleEffect(isHovered ? 1.015 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FolderPermissionItem

private struct FolderPermissionItem: Identifiable {
    let id: String
    let platform: PlatformOption
    let title: String
    let path: String
    let expectedPath: String
    let buttonTitle: String
    let isRequired: Bool
    let isXcode: Bool
}

// MARK: - FolderTableRow

private struct FolderTableRow: View {
    let item: FolderPermissionItem
    let isGranted: Bool
    let isSyncing: Bool
    let onChoose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            // Column 1: Target
            HStack(spacing: 10) {
                Image(systemName: item.platform.iconName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(item.platform.color)
                    .frame(width: 28, height: 28)
                    .background(item.platform.color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(item.isXcode ? "Xcode Environment" : "User Skills Store")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, alignment: .leading)

            // Column 2: Current Path / Expected Path
            VStack(alignment: .leading, spacing: 4) {
                if isGranted {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(item.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("Not Configured")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                let displayExpected = item.isXcode ? item.expectedPath : "Usually `\(item.expectedPath)`."
                Text(displayExpected)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Column 3: Status Badge
            HStack {
                if isSyncing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                        Text("Syncing")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(Capsule())
                } else if isGranted {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                        Text("Granted")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                        Text("Access Needed")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            .frame(width: 120, alignment: .center)

            // Column 4: Action Button
            HStack {
                if isGranted {
                    Button("Change...", action: onChoose)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                } else {
                    Button("Choose Folder", action: onChoose)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(isHovered ? Color.primary.opacity(0.015) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

}
