import Foundation
import os

enum SandboxBookmarkManager {
    /// Saves a security-scoped bookmark for the given URL
    static func saveBookmark(for url: URL, customKey: String? = nil) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let key = customKey ?? url.path
            UserDefaults.standard.set(bookmarkData, forKey: "bookmark_\(key)")
            AppLogger.fileIO.info("Saved security-scoped bookmark for \(key)")
        } catch {
            AppLogger.fileIO.error("Failed to save security-scoped bookmark for \(url.path): \(error.localizedDescription)")
        }
    }

    /// Resolves the bookmark for a path and executes the given closure with sandbox access
    static func resolveAndAccess<T>(path: String, action: (URL) throws -> T) rethrows -> T {
        let key = "bookmark_\(path)"
        guard let bookmarkData = UserDefaults.standard.data(forKey: key) else {
            // No bookmark found, fallback to standard URL (useful inside sandbox container, e.g. App Support)
            let url = URL(fileURLWithPath: path)
            return try action(url)
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                saveBookmark(for: url)
            }
            let success = url.startAccessingSecurityScopedResource()
            defer {
                if success {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return try action(url)
        } catch {
            AppLogger.fileIO.error("Failed to resolve security-scoped bookmark for \(path): \(error.localizedDescription). Falling back to direct path.")
            let url = URL(fileURLWithPath: path)
            return try action(url)
        }
    }

    /// Resolves the bookmark for the closest parent directory of path and executes the given closure with sandbox access
    static func resolveAndAccessParent<T>(for path: String, action: (URL) throws -> T) rethrows -> T {
        let customPaths = UserDefaults.standard.stringArray(forKey: "customScanPaths") ?? []
        let matchingParent = customPaths
            .sorted(by: { $0.count > $1.count })
            .first(where: { path.hasPrefix($0 + "/") || path == $0 })

        if let parent = matchingParent {
            return try resolveAndAccess(path: parent) { _ in
                try action(URL(fileURLWithPath: path))
            }
        }

        return try resolveAndAccess(path: path, action: action)
    }
}
