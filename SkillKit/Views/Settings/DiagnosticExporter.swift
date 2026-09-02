import AppKit
import Foundation
import OSLog
import SwiftData

/// Result of a diagnostic export attempt. Callers that don't need it can ignore the return
/// value — `export` already presents an alert for the success and failure cases.
enum DiagnosticExportOutcome: Equatable {
    case success(URL)
    case failure(String)
    case cancelled
}

enum DiagnosticExporter {
    /// Builds the report, asks where to save it, writes it, and shows an alert describing
    /// the outcome. Must be called on the main thread (it runs a modal save panel).
    @discardableResult
    @MainActor
    static func export(modelContext: ModelContext) -> DiagnosticExportOutcome {
        let report = buildReport(modelContext: modelContext)

        // Save panel
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "skillkit-diagnostic-\(dateStamp()).txt"
        panel.allowedContentTypes = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }

        let outcome: DiagnosticExportOutcome
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            outcome = .success(url)
        } catch {
            AppLogger.fileIO.error("Diagnostic export failed: \(error.localizedDescription)")
            outcome = .failure(error.localizedDescription)
        }

        presentAlert(for: outcome)
        return outcome
    }

    /// Assembles the report text without any UI. Exposed for callers that want to save or
    /// display it themselves.
    static func buildReport(modelContext: ModelContext) -> String {
        var lines: [String] = []

        // System info
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        lines.append("# SkillKit Diagnostic Report")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: .now))")
        lines.append("")
        lines.append("## System")
        lines.append("- App Version: \(version) (\(build))")
        lines.append("- macOS: \(osVersion)")
        lines.append("- Memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        lines.append("")

        // Skill counts
        let descriptor = FetchDescriptor<Skill>()
        let skills = (try? modelContext.fetch(descriptor)) ?? []
        let skillsOnly = skills.filter { $0.itemKind == .skill }
        let rulesOnly = skills.filter { $0.itemKind == .rule }
        lines.append("## Items")
        lines.append("- Total: \(skills.count)")
        lines.append("- Skills: \(skillsOnly.count)")
        lines.append("- Rules: \(rulesOnly.count)")
        for tool in ToolSource.allCases {
            let count = skills.filter { $0.toolSources.contains(tool) }.count
            if count > 0 {
                lines.append("- \(tool.displayName): \(count)")
            }
        }
        lines.append("")

        // Library settings
        lines.append("## Library")
        lines.append("- Root: \(SkillKitSettings.sotDir)\(SkillKitSettings.isUsingDefaultSotDir ? " (default)" : "")")
        lines.append("- Include plugin-installed skills: \(SkillKitSettings.includePluginSkills ? "yes" : "no")")
        lines.append("")

        // Custom scan paths
        let customPaths = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
        lines.append("## Custom Scan Paths")
        if customPaths.isEmpty {
            lines.append("- (none)")
        } else {
            for path in customPaths {
                lines.append("- \(path)")
            }
        }
        lines.append("")

        // Recent logs
        lines.append("## Recent Logs")
        if let logEntries = collectRecentLogs() {
            lines.append(logEntries)
        } else {
            lines.append("(Unable to collect logs)")
        }

        return lines.joined(separator: "\n")
    }

    @MainActor
    private static func presentAlert(for outcome: DiagnosticExportOutcome) {
        let alert = NSAlert()
        switch outcome {
        case .success(let url):
            alert.alertStyle = .informational
            alert.messageText = "Diagnostic Report Saved"
            alert.informativeText = "Saved to \(url.path)"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Reveal in Finder")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .failure(let message):
            alert.alertStyle = .warning
            alert.messageText = "Couldn't Save Diagnostic Report"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .cancelled:
            break
        }
    }

    private static func collectRecentLogs() -> String? {
        // Try system scope first (persisted logs, survives force quit)
        // Fall back to current process scope
        let store: OSLogStore
        if let systemStore = try? OSLogStore(scope: .system) {
            store = systemStore
        } else if let processStore = try? OSLogStore(scope: .currentProcessIdentifier) {
            store = processStore
        } else {
            return nil
        }

        let since = Date.now.addingTimeInterval(-3600) // last hour
        let subsystem = Bundle.main.bundleIdentifier ?? "alice.turcanu.com.SkillKit"

        guard let entries = try? store.getEntries(
            at: store.position(date: since),
            matching: NSPredicate(format: "subsystem == %@", subsystem)
        ) else {
            return nil
        }

        var lines: [String] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog else { continue }
            let time = formatter.string(from: logEntry.date)
            lines.append("[\(time)] [\(logEntry.category)] \(logEntry.composedMessage)")
        }

        return lines.isEmpty ? "(No log entries in the last hour)" : lines.joined(separator: "\n")
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: .now)
    }
}
