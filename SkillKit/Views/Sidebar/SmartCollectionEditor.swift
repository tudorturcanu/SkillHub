import SwiftUI

struct SmartCollectionEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var collection: SmartCollection
    let skills: [Skill]

    init(collection: SmartCollection, skills: [Skill]) {
        _collection = State(initialValue: collection)
        self.skills = skills
    }

    private var normalizedName: String {
        collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var duplicateName: Bool {
        appState.smartCollections.contains {
            $0.id != collection.id && $0.name.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
        }
    }

    private var canSave: Bool {
        !normalizedName.isEmpty && !SkillSearchQuery(collection.query).isEmpty && !duplicateName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Smart Collection")
                .font(.headline)
            Form {
                TextField("Name", text: $collection.name)
                TextField("Search", text: $collection.query, prompt: Text("tool:codex is:project"))
                Picker("Search in", selection: $collection.scope) {
                    ForEach(SkillSearchScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
            }
            Text("Searches all skills and rules in your library. Items are added and removed automatically as they change.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Use words, \"exact phrases\", -excluded, tool:cursor, is:rule, or is:favorite. Other sidebar and quick filters are not saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if duplicateName {
                Text("A smart collection with this name already exists.")
                    .foregroundStyle(.red)
            }
            Text("\(collection.matchingSkills(in: skills).count) matching items")
                .font(.callout)
                .accessibilityLabel("\(collection.matchingSkills(in: skills).count) matching items in the library")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func save() {
        guard canSave else { return }
        collection.name = normalizedName
        collection.query = collection.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = appState.smartCollections.firstIndex(where: { $0.id == collection.id }) {
            appState.smartCollections[index] = collection
        } else {
            appState.smartCollections.append(collection)
        }
        appState.sidebarFilter = .smartCollection(collection.id)
        dismiss()
    }
}
