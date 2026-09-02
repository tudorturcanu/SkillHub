import AppKit

final class SkillKitTextView: NSTextView {

    private var didRegisterFormatObserver = false

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didRegisterFormatObserver else { return }
        didRegisterFormatObserver = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplyMarkdownFormat(_:)),
            name: .applyMarkdownFormat,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollToLine(_:)),
            name: .scrollEditorToLine,
            object: nil
        )
    }

    /// Scrolls to and selects a 1-based line, used by "Jump to line" on a
    /// security finding. Only the editable editor responds, so the preview
    /// pane's copy stays put.
    @objc private func handleScrollToLine(_ notification: Notification) {
        guard isEditable, window != nil,
              let line = notification.userInfo?["line"] as? Int, line > 0 else { return }

        let text = string as NSString
        var currentLine = 1
        var lineRange: NSRange?
        var searchLocation = 0

        while searchLocation <= text.length {
            let range = text.lineRange(for: NSRange(location: searchLocation, length: 0))
            if currentLine == line {
                lineRange = range
                break
            }
            guard NSMaxRange(range) > searchLocation else { break }
            searchLocation = NSMaxRange(range)
            currentLine += 1
        }

        // The buffer can be shorter than the scanned source (unsaved deletions,
        // or a reconstructed-frontmatter fallback). Do nothing rather than
        // flashing line 1 as if it were the finding.
        guard let lineRange else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(lineRange)
        scrollRangeToVisible(lineRange)
        showFindIndicator(for: lineRange)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Whether this editor should respond to app-wide formatting commands
    /// (menu items, notifications). Only the focused, editable editor reacts.
    private var isFocusedEditableEditor: Bool {
        guard isEditable, let window else { return false }
        return window.firstResponder === self
    }

    /// Handles `.applyMarkdownFormat` posted by the Format menu.
    /// `object` is "bold", "italic", or "strikethrough".
    @objc private func handleApplyMarkdownFormat(_ notification: Notification) {
        guard isFocusedEditableEditor, let format = notification.object as? String else { return }
        switch format {
        case "bold": toggleBold(nil)
        case "italic": toggleItalic(nil)
        case "strikethrough": toggleStrikethrough(nil)
        default: break
        }
    }

    // MARK: - Cursor

    override func mouseMoved(with event: NSEvent) {
        // If another view (e.g. a floating button) is in front at this point, don't set the I-beam.
        if let hitView = window?.contentView?.hitTest(event.locationInWindow),
           hitView !== self, !(hitView is NSClipView) {
            return
        }
        super.mouseMoved(with: event)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let indicator = subview as? NSTextInsertionIndicator {
            indicator.displayMode = .hidden
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var adjusted = rect
        adjusted.size.width = 2
        super.drawInsertionPoint(in: adjusted, color: color, turnedOn: flag)
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = rect
        rect.size.width += 2
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    // MARK: - Find

    @objc func showFindPanel(_ sender: Any?) {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        performFindPanelAction(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if modifiers == [.command], key == "f" {
            showFindPanel(nil)
            return true
        }

        // ⌘B / ⌘I / ⇧⌘X — advertised in the context menu; only for the focused editor.
        if isFocusedEditableEditor {
            if modifiers == [.command], key == "b" {
                toggleBold(nil)
                return true
            }
            if modifiers == [.command], key == "i" {
                toggleItalic(nil)
                return true
            }
            if modifiers == [.command, .shift], key == "x" {
                toggleStrikethrough(nil)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Markdown Formatting

    @objc func toggleBold(_ sender: Any?) {
        toggleInlineMarker("**")
    }

    @objc func toggleItalic(_ sender: Any?) {
        toggleInlineMarker("*")
    }

    @objc func insertLink(_ sender: Any?) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        if selected.isEmpty {
            insertText("[link text](url)", replacementRange: range)
            let urlStart = range.location + "[link text](".utf16.count
            setSelectedRange(NSRange(location: urlStart, length: "url".utf16.count))
        } else {
            insertText("[\(selected)](url)", replacementRange: range)
            let urlStart = range.location + "[\(selected)](".utf16.count
            setSelectedRange(NSRange(location: urlStart, length: "url".utf16.count))
        }
    }

    @objc func insertHeading(_ sender: Any?) {
        let range = selectedRange()
        let lineRange = (string as NSString).lineRange(for: range)
        let line = (string as NSString).substring(with: lineRange)

        let trimmed = line.drop(while: { $0 == "#" || $0 == " " })
        let hashes = line.prefix(while: { $0 == "#" })

        let newLine: String
        switch hashes.count {
        case 0: newLine = "# \(trimmed)"
        case 1: newLine = "## \(trimmed)"
        case 2: newLine = "### \(trimmed)"
        default: newLine = String(trimmed)
        }

        insertText(newLine, replacementRange: lineRange)
    }

    @objc func toggleStrikethrough(_ sender: Any?) {
        toggleInlineMarker("~~")
    }

    @objc func toggleBulletList(_ sender: Any?) {
        toggleLinePrefix(prefix: "- ", placeholder: "list item")
    }

    @objc func toggleNumberedList(_ sender: Any?) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        if selected.isEmpty {
            insertText("1. list item", replacementRange: range)
            let start = range.location + "1. ".utf16.count
            setSelectedRange(NSRange(location: start, length: "list item".utf16.count))
            return
        }
        let lineRange = (string as NSString).lineRange(for: range)
        let block = (string as NSString).substring(with: lineRange)
        let lines = block.components(separatedBy: "\n")
        var result: [String] = []
        var num = 1
        for line in lines {
            if line.isEmpty {
                result.append(line)
            } else {
                result.append("\(num). \(line)")
                num += 1
            }
        }
        insertText(result.joined(separator: "\n"), replacementRange: lineRange)
    }

    @objc func toggleTodoList(_ sender: Any?) {
        toggleLinePrefix(prefix: "- [ ] ", placeholder: "task")
    }

    @objc func toggleBlockquote(_ sender: Any?) {
        toggleLinePrefix(prefix: "> ", placeholder: "quote")
    }

    @objc func insertHorizontalRule(_ sender: Any?) {
        let range = selectedRange()
        insertText("\n\n---\n\n", replacementRange: range)
    }

    @objc func insertMarkdownTable(_ sender: Any?) {
        let range = selectedRange()
        let table = "| Column 1 | Column 2 | Column 3 |\n| --- | --- | --- |\n| Cell | Cell | Cell |"
        insertText(table, replacementRange: range)
    }

    @objc func toggleInlineCode(_ sender: Any?) {
        wrapSelection(prefix: "`", suffix: "`", placeholder: "code")
    }

    @objc func insertCodeBlock(_ sender: Any?) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        if selected.isEmpty {
            let snippet = "```\ncode\n```"
            insertText(snippet, replacementRange: range)
            let start = range.location + "```\n".utf16.count
            setSelectedRange(NSRange(location: start, length: "code".utf16.count))
        } else {
            insertText("```\n\(selected)\n```", replacementRange: range)
        }
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()

        let formatMenu = NSMenu(title: "Text Format")

        formatMenu.addItem(withTitle: "Headers", action: #selector(insertHeading(_:)), keyEquivalent: "")
        formatMenu.addItem(.separator())

        let boldItem = formatMenu.addItem(withTitle: "Bold", action: #selector(toggleBold(_:)), keyEquivalent: "b")
        boldItem.keyEquivalentModifierMask = .command
        let italicItem = formatMenu.addItem(withTitle: "Italic", action: #selector(toggleItalic(_:)), keyEquivalent: "i")
        italicItem.keyEquivalentModifierMask = .command
        let strikeItem = formatMenu.addItem(withTitle: "Strikethrough", action: #selector(toggleStrikethrough(_:)), keyEquivalent: "x")
        strikeItem.keyEquivalentModifierMask = [.command, .shift]
        formatMenu.addItem(.separator())

        formatMenu.addItem(withTitle: "Insert Link", action: #selector(insertLink(_:)), keyEquivalent: "")
        formatMenu.addItem(.separator())

        formatMenu.addItem(withTitle: "List", action: #selector(toggleBulletList(_:)), keyEquivalent: "")
        formatMenu.addItem(withTitle: "Ordered List", action: #selector(toggleNumberedList(_:)), keyEquivalent: "")
        formatMenu.addItem(withTitle: "Todo", action: #selector(toggleTodoList(_:)), keyEquivalent: "")
        formatMenu.addItem(.separator())

        formatMenu.addItem(withTitle: "Quote", action: #selector(toggleBlockquote(_:)), keyEquivalent: "")
        formatMenu.addItem(withTitle: "Horizontal Rule", action: #selector(insertHorizontalRule(_:)), keyEquivalent: "")
        formatMenu.addItem(withTitle: "Table", action: #selector(insertMarkdownTable(_:)), keyEquivalent: "")
        formatMenu.addItem(.separator())

        formatMenu.addItem(withTitle: "Code", action: #selector(toggleInlineCode(_:)), keyEquivalent: "")
        formatMenu.addItem(withTitle: "Code Block", action: #selector(insertCodeBlock(_:)), keyEquivalent: "")

        let formatItem = NSMenuItem(title: "Text Format", action: nil, keyEquivalent: "")
        formatItem.submenu = formatMenu

        menu.insertItem(.separator(), at: 0)
        menu.insertItem(formatItem, at: 0)

        return menu
    }

    // MARK: - Helpers

    private func toggleLinePrefix(prefix: String, placeholder: String) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        if selected.isEmpty {
            let text = "\(prefix)\(placeholder)"
            insertText(text, replacementRange: range)
            let start = range.location + prefix.utf16.count
            setSelectedRange(NSRange(location: start, length: placeholder.utf16.count))
            return
        }
        let lineRange = (string as NSString).lineRange(for: range)
        let block = (string as NSString).substring(with: lineRange)
        let lines = block.components(separatedBy: "\n")
        let result = lines.map { $0.isEmpty ? $0 : "\(prefix)\($0)" }
        insertText(result.joined(separator: "\n"), replacementRange: lineRange)
    }

    /// Replaces `range` through the undo-aware text-change pipeline so the
    /// delegate's `textDidChange` fires (which pushes the change into the
    /// SwiftUI binding and marks the document as having unsaved changes).
    private func replaceText(in range: NSRange, with replacement: String) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
    }

    /// Toggles a symmetric inline marker (`**`, `*`, `~~`) around the selection.
    ///
    /// - Selection already wrapped (inside or including the markers): unwraps.
    /// - Non-empty selection: wraps it and keeps the inner text selected.
    /// - Empty selection: inserts the marker pair and places the caret between them.
    private func toggleInlineMarker(_ marker: String) {
        guard isEditable else { return }
        let text = string as NSString
        let range = selectedRange()
        let markerLength = marker.utf16.count

        // Selection includes the markers themselves, e.g. "**bold**".
        if range.length >= markerLength * 2 {
            let selected = text.substring(with: range)
            if selected.hasPrefix(marker), selected.hasSuffix(marker) {
                let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
                replaceText(in: range, with: inner)
                setSelectedRange(NSRange(location: range.location, length: inner.utf16.count))
                return
            }
        }

        // Markers immediately surround the selection, e.g. "**|bold|**".
        let before = NSRange(location: range.location - markerLength, length: markerLength)
        let after = NSRange(location: NSMaxRange(range), length: markerLength)
        if before.location >= 0,
           NSMaxRange(after) <= text.length,
           text.substring(with: before) == marker,
           text.substring(with: after) == marker {
            let outer = NSRange(location: before.location, length: range.length + markerLength * 2)
            let inner = text.substring(with: range)
            replaceText(in: outer, with: inner)
            setSelectedRange(NSRange(location: before.location, length: inner.utf16.count))
            return
        }

        // Wrap.
        let selected = text.substring(with: range)
        replaceText(in: range, with: marker + selected + marker)
        setSelectedRange(NSRange(location: range.location + markerLength, length: range.length))
    }

    private func wrapSelection(prefix: String, suffix: String, placeholder: String) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        if selected.isEmpty {
            let text = "\(prefix)\(placeholder)\(suffix)"
            insertText(text, replacementRange: range)
            let placeholderStart = range.location + prefix.utf16.count
            setSelectedRange(NSRange(location: placeholderStart, length: placeholder.utf16.count))
        } else {
            let text = "\(prefix)\(selected)\(suffix)"
            insertText(text, replacementRange: range)
        }
    }
}
