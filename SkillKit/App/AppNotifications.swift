import Foundation

/// App-wide notification names used to route menu commands and cross-view events.
/// `saveCurrentSkill` lives in SkillEditorView.swift and `customScanPathsChanged` in SettingsView.swift.
extension Notification.Name {
    /// Ask the detail view to delete the currently selected skill (with confirmation).
    static let deleteCurrentSkill = Notification.Name("deleteCurrentSkill")
    /// Ask the detail view to flush pending edits and open Rename for the current item.
    static let renameCurrentSkill = Notification.Name("renameCurrentSkill")
    /// Ask the detail view to switch view mode. `object` is a `String`: "edit", "preview", or "playground".
    static let setDetailViewMode = Notification.Name("setDetailViewMode")
    /// Ask the focused editor to apply a Markdown format. `object` is a `String`: "bold", "italic", "strikethrough".
    static let applyMarkdownFormat = Notification.Name("applyMarkdownFormat")
    /// Focus the library search field.
    static let focusLibrarySearch = Notification.Name("focusLibrarySearch")
    /// Posted by SkillScanner when a scan starts/finishes. `userInfo["count"]` is the item count on finish.
    static let scanDidStart = Notification.Name("scanDidStart")
    static let scanDidFinish = Notification.Name("scanDidFinish")
}

extension Notification.Name {
    /// Ask the editor that owns the current skill to scroll to / select a line.
    /// `userInfo["line"]` is a 1-based `Int` into the full file text (frontmatter included).
    /// `userInfo["file"]` is an optional `String` (skill-relative path) when the line belongs to a
    /// bundled file rather than the main skill file — handlers may ignore those.
    static let jumpToEditorLine = Notification.Name("jumpToEditorLine")
    /// Ask the mounted editor to scroll to and select a 1-based line.
    /// `userInfo["line"]` is an `Int` over the full file text.
    static let scrollEditorToLine = Notification.Name("scrollEditorToLine")
    /// Posted just before the app terminates so the editor can flush a
    /// pending autosave synchronously.
    static let applicationWillTerminate = Notification.Name("skillKitApplicationWillTerminate")
}
