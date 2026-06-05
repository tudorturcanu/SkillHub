import Foundation

enum AppPaths {
    static var userHomeDirectory: String {
        let fileManagerHome = FileManager.default.homeDirectoryForCurrentUser.path
        let containerMarker = "/Library/Containers/"

        if let markerRange = fileManagerHome.range(of: containerMarker) {
            return String(fileManagerHome[..<markerRange.lowerBound])
        }

        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty,
           !home.contains(containerMarker) {
            return home
        }

        return "/Users/\(NSUserName())"
    }

    static var agentsDirectory: String {
        "\(userHomeDirectory)/.agents"
    }
}
