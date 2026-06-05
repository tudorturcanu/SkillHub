import Foundation
import os

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "alice.turcanu.com.SkillKit"

    static let scanning = Logger(subsystem: subsystem, category: "scanning")
    static let fileIO = Logger(subsystem: subsystem, category: "fileIO")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}
