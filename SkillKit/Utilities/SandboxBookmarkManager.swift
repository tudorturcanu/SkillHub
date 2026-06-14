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

    /// Resolves the bookmark for a path (or its closest bookmarked parent) and executes the given closure with sandbox access
    static func resolveAndAccess<T>(path: String, action: (URL) throws -> T) rethrows -> T {
        var currentPath = path
        var bookmarkData: Data? = nil
        var bookmarkedPath = path
        
        while !currentPath.isEmpty && currentPath != "/" {
            let key = "bookmark_\(currentPath)"
            if let data = UserDefaults.standard.data(forKey: key) {
                bookmarkData = data
                bookmarkedPath = currentPath
                break
            }
            let parentURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()
            let parentPath = parentURL.path
            if parentPath == currentPath {
                break
            }
            currentPath = parentPath
        }
        
        guard let data = bookmarkData else {
            // No bookmark found for the path or any parent, fallback to standard URL (useful inside sandbox container, e.g. App Support)
            AppLogger.fileIO.notice("No bookmark found for \(path) or its parents, falling back to direct URL")
            let url = URL(fileURLWithPath: path)
            return try action(url)
        }

        var isStale = false
        do {
            let bookmarkedURL = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                saveBookmark(for: bookmarkedURL, customKey: bookmarkedPath)
            }
            let success = bookmarkedURL.startAccessingSecurityScopedResource()
            defer {
                if success {
                    bookmarkedURL.stopAccessingSecurityScopedResource()
                }
            }
            
            // We have access now, run the action on the original target path URL
            let targetURL = URL(fileURLWithPath: path)
            return try action(targetURL)
        } catch {
            AppLogger.fileIO.error("Failed to resolve security-scoped bookmark for \(bookmarkedPath) (while accessing \(path)): \(error.localizedDescription). Falling back to direct path.")
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
