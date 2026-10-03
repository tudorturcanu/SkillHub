import SwiftUI

struct SmartCollectionListView: View {
    @Environment(AppState.self) private var appState
    let skills: [Skill]
    @State private var draft: SmartCollection?

    var body: some View {
        ForEach(appState.smartCollections) { collection in
            Label(collection.name, systemImage: "folder.badge.gearshape")
                .badge(collection.matchingSkills(in: skills).count)
                .tag(SidebarFilter.smartCollection(collection.id))
                .help(collection.query)
                .contextMenu {
                    Button("Edit Smart Collection…") { draft = collection }
                    Button("Delete Smart Collection", role: .destructive) {
                        appState.smartCollections.removeAll { $0.id == collection.id }
                        if appState.sidebarFilter == .smartCollection(collection.id) {
                            appState.sidebarFilter = .allSkills
                        }
                    }
                }
        }
        Button {
            draft = SmartCollection(name: "", query: appState.searchText, scope: appState.skillSearchScope)
        } label: {
            Label("New Smart Collection", systemImage: "plus.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .sheet(item: $draft) { collection in
            SmartCollectionEditor(collection: collection, skills: skills)
        }
    }
}
