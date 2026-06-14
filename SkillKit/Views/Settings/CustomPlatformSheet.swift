import SwiftUI
import AppKit

struct CustomPlatformSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    var platformToEdit: PlatformOption? // nil means adding
    var onSave: (PlatformOption) -> Void
    
    @State private var displayName = ""
    @State private var detail = ""
    @State private var skillsPath = ""
    @State private var xcodePath = ""
    @State private var iconName = "folder"
    @State private var iconColorName = "blue"
    
    private let availableIcons = [
        "folder", "folder.badge.gearshape", "terminal", "cpu", "sparkles",
        "brain.head.profile", "globe", "arrow.up.circle", "chevron.left.forwardslash.chevron.right",
        "hammer", "wrench.and.screwdriver"
    ]
    
    private let availableColors = [
        "purple", "orange", "blue", "green", "cyan", "red", "pink", "teal", "gray"
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(platformToEdit == nil ? "Add Custom Platform" : "Edit Custom Platform")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Content
            Form {
                Section("Details") {
                    TextField("Name", text: $displayName)
                    TextField("Description", text: $detail)
                }
                
                Section("Paths") {
                    HStack {
                        TextField("Skills Directory", text: $skillsPath)
                        Button("Choose...") {
                            chooseFolder { path in
                                skillsPath = path
                            }
                        }
                    }
                    
                    HStack {
                        TextField("Xcode Directory (Optional)", text: $xcodePath)
                        Button("Choose...") {
                            chooseFolder { path in
                                xcodePath = path
                            }
                        }
                    }
                }
                
                Section("Aesthetics") {
                    // Grid of icons
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Icon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36))], spacing: 8) {
                            ForEach(availableIcons, id: \.self) { icon in
                                Button {
                                    iconName = icon
                                } label: {
                                    Image(systemName: icon)
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(width: 32, height: 32)
                                        .background(iconName == icon ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(iconName == icon ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    
                    // List of colors
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 10) {
                            ForEach(availableColors, id: \.self) { colorName in
                                Button {
                                    iconColorName = colorName
                                } label: {
                                    Circle()
                                        .fill(color(for: colorName))
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.primary, lineWidth: iconColorName == colorName ? 2 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    let id = platformToEdit?.id ?? "custom_\(UUID().uuidString)"
                    let platform = PlatformOption(
                        id: id,
                        displayName: displayName,
                        detail: detail.isEmpty ? "Custom Platform" : detail,
                        skillsPath: skillsPath,
                        xcodePath: xcodePath.isEmpty ? nil : xcodePath,
                        iconName: iconName,
                        iconColorName: iconColorName
                    )
                    onSave(platform)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.isEmpty || skillsPath.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 520)
        .onAppear {
            if let platform = platformToEdit {
                displayName = platform.displayName
                detail = platform.detail
                skillsPath = platform.skillsPath
                xcodePath = platform.xcodePath ?? ""
                iconName = platform.iconName
                iconColorName = platform.iconColorName
            }
        }
    }
    
    private func chooseFolder(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                completion(url.path)
            }
        }
    }
    
    private func color(for name: String) -> Color {
        switch name {
        case "purple": return .purple
        case "orange": return .orange
        case "blue": return .blue
        case "green": return .green
        case "cyan": return .cyan
        case "red": return .red
        case "pink": return .pink
        case "teal": return .teal
        default: return .gray
        }
    }
}
