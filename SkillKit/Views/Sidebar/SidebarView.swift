import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Skill.name) private var allSkills: [Skill]
    @Query(sort: \RemoteServer.label) private var servers: [RemoteServer]
    @AppStorage("securityScanningEnabled") private var securityScanningEnabled = true
    @State private var syncingServerIDs: Set<String> = []
    @State private var serverErrors: [String: String] = [:]
    @State private var showingErrorForServer: String?

    private var activeSources: [ToolSource] {
        ToolSource.allCases.filter { tool in
            guard tool.listable else { return false }
            return allSkills.contains { $0.toolSources.contains(tool) }
        }
    }

    private func toolCount(_ tool: ToolSource) -> Int {
        allSkills.filter { $0.toolSources.contains(tool) }.count
    }

    private var securityFindingCount: Int {
        allSkills.filter { !$0.securityScan.isClean }.count
    }

    private var activeCustomPlatforms: [PlatformOption] {
        PlatformOption.customPlatforms.filter { platform in
            customPlatformCount(platform) > 0
        }
    }

    private func customPlatformCount(_ platform: PlatformOption) -> Int {
        allSkills.filter { skill in
            guard skill.toolSource == .custom else { return false }
            let path = skill.filePath.lowercased()
            let platformSkills = platform.expandedSkillsPath.lowercased()
            let platformXcode = platform.expandedXcodePath?.lowercased()
            return path.hasPrefix(platformSkills) || (platformXcode != nil && path.hasPrefix(platformXcode!))
        }.count
    }

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.sidebarFilter) {
            Section("Library") {
                Label("Dashboard", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    .tag(SidebarFilter.dashboard)

                Label("Discover", systemImage: "sparkle.magnifyingglass")
                    .tag(SidebarFilter.discover)

                Label("Recent", systemImage: "clock.badge.checkmark")
                    .badge(allSkills.filter { $0.lastOpened != nil }.count)
                    .tag(SidebarFilter.recent)

                Label("Skills", systemImage: "doc.text")
                    .badge(allSkills.filter { $0.itemKind == .skill }.count)
                    .tag(SidebarFilter.allSkills)

                Label("Rules", systemImage: "list.bullet.rectangle")
                    .badge(allSkills.filter { $0.itemKind == .rule }.count)
                    .tag(SidebarFilter.allRules)

                Label("Needs Review", systemImage: "exclamationmark.triangle")
                    .badge(allSkills.filter(\.hasValidationWarnings).count)
                    .tag(SidebarFilter.needsReview)

                if securityScanningEnabled {
                    Label("Security", systemImage: "shield.lefthalf.filled")
                        .badge(securityFindingCount)
                        .tag(SidebarFilter.securityReview)
                }

                Label("Favorites", systemImage: "star")
                    .badge(allSkills.filter(\.isFavorite).count)
                    .tag(SidebarFilter.favorites)
            }

            Section("Collections") {
                CollectionListView()
            }

            if !activeSources.isEmpty || !activeCustomPlatforms.isEmpty {
                Section("Tools") {
                    ForEach(activeSources) { tool in
                        Label {
                            Text(tool.displayName)
                        } icon: {
                            ToolIcon(tool: tool)
                        }
                        .badge(toolCount(tool))
                        .tag(SidebarFilter.tool(tool))
                    }

                    ForEach(activeCustomPlatforms) { platform in
                        Label {
                            Text(platform.displayName)
                        } icon: {
                            Image(systemName: platform.iconName)
                                .foregroundStyle(platform.color)
                        }
                        .badge(customPlatformCount(platform))
                        .tag(SidebarFilter.customPlatform(id: platform.id))
                    }
                }
            }

            if !servers.isEmpty {
                Section("Servers") {
                    ForEach(servers) { server in
                        HStack {
                            Label {
                                Text(server.label)
                            } icon: {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if let error = serverErrors[server.id] {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .popover(isPresented: Binding(
                                        get: { showingErrorForServer == server.id },
                                        set: { if !$0 { showingErrorForServer = nil } }
                                    )) {
                                        Text(error)
                                            .font(.caption)
                                            .padding()
                                            .frame(maxWidth: 250)
                                    }
                                    .onTapGesture {
                                        showingErrorForServer = server.id
                                    }
                            }

                            Button {
                                syncServer(server)
                            } label: {
                                if syncingServerIDs.contains(server.id) {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Sync skills from server")
                            .disabled(syncingServerIDs.contains(server.id))
                        }
                        .badge(server.skills.count)
                        .tag(SidebarFilter.server(server.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SkillKit")
        .onChange(of: securityScanningEnabled) {
            if !securityScanningEnabled, appState.sidebarFilter == .securityReview {
                appState.sidebarFilter = .allSkills
            }
        }
    }

    private func syncServer(_ server: RemoteServer) {
        syncingServerIDs.insert(server.id)
        serverErrors.removeValue(forKey: server.id)
        let context = modelContext
        Task {
            let scanner = SkillScanner(modelContext: context)
            await scanner.scanRemoteServer(server)
            syncingServerIDs.remove(server.id)
            if let error = server.lastSyncError {
                serverErrors[server.id] = error
            }
        }
    }
}
