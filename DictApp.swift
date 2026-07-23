// DictApp.swift
// Build: swiftc DictApp.swift -framework AppKit -framework CoreServices -o DictApp
// Run:   ./DictApp

import AppKit
import CoreServices

// MARK: - DictionaryServices Bridge (private API)

typealias DCSDictionaryRef = CFTypeRef

// "Get"-named CF functions follow the Get rule (caller does not own the
// result), unlike "Copy"-named ones below. Declaring them as Unmanaged and
// consuming with takeUnretainedValue() avoids an over-release that corrupts
// the heap and crashes on the *second* call in the process's lifetime.
@_silgen_name("DCSGetActiveDictionaries")
func DCSGetActiveDictionaries() -> Unmanaged<CFArray>

@_silgen_name("DCSDictionaryGetIdentifier")
func DCSDictionaryGetIdentifier(_ dict: DCSDictionaryRef) -> Unmanaged<CFString>

@_silgen_name("DCSCopyTextDefinition")
func DCSCopyTextDefinition(_ dict: DCSDictionaryRef?, _ text: CFString, _ range: CFRange) -> Unmanaged<CFString>?

// MARK: - Lookup

/// Finds the first active dictionary whose identifier contains `marker`.
private func resolveActiveDictionary(containing marker: String) -> DCSDictionaryRef? {
    let actives = DCSGetActiveDictionaries().takeUnretainedValue() as [AnyObject]
    for d in actives {
        let ident = DCSDictionaryGetIdentifier(d as CFTypeRef).takeUnretainedValue() as String
        if ident.contains(marker) { return d as CFTypeRef }
    }
    return nil
}

/// The Oxford Thai-English dictionary, resolved once from the active set.
let thaiEnglishDictionary: DCSDictionaryRef? = resolveActiveDictionary(containing: "th-en")

/// The New Oxford American Dictionary (English-English), resolved once from
/// the active set. Used as a fallback when a word has no Thai translation.
let englishDictionary: DCSDictionaryRef? = resolveActiveDictionary(containing: "NOAD")

/// Looks up `text` in `dict`. Returns the raw definition string, or nil when
/// the input is empty/whitespace, `dict` is unavailable, or there is no entry.
private func lookUp(_ text: String, in dict: DCSDictionaryRef?) -> String? {
    // Fail closed on a nil dictionary: passing nil to DCSCopyTextDefinition
    // makes it search ALL active dictionaries, silently ignoring the caller's
    // intended scope.
    guard let dict = dict else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let ns = trimmed as NSString
    // CFRange length MUST be UTF-16 code units, not Swift String.count,
    // or Thai words with combining marks silently fail to resolve.
    let range = CFRangeMake(0, ns.length)
    guard let def = DCSCopyTextDefinition(dict, trimmed as CFString, range)?.takeRetainedValue() else {
        return nil
    }
    return def as String
}

/// Look up `text` in the Thai-English dictionary.
func translate(_ text: String) -> String? {
    lookUp(text, in: thaiEnglishDictionary)
}

/// Look up `text` in the English-English dictionary. Used when `translate`
/// finds no Thai entry for the word.
func lookUpEnglishOnly(_ text: String) -> String? {
    lookUp(text, in: englishDictionary)
}

// MARK: - Result Formatting

/// Splits `text` at the first occurrence of any fixed section `headers`,
/// then puts each header on its own line. Everything within a section is
/// left as the dictionary wrote it, since entries inside a section (phrases,
/// derivatives, etc.) have no reliable separator to split further.
private func splitSections(_ text: String, headers: [String]) -> (mainBody: String, sectionsText: String) {
    var mainBody = text
    var sectionsText = ""
    if let firstRange = headers
        .compactMap({ text.range(of: $0) })
        .min(by: { $0.lowerBound < $1.lowerBound }) {
        mainBody = String(text[text.startIndex..<firstRange.lowerBound])
        sectionsText = String(text[firstRange.lowerBound...])
    }
    for header in headers {
        sectionsText = sectionsText.replacingOccurrences(of: header, with: "\n\n\(header)\n")
    }
    return (
        mainBody.trimmingCharacters(in: .whitespaces),
        sectionsText.trimmingCharacters(in: .whitespacesAndNewlines)
    )
}

/// Section headers used by the Oxford Thai-English dictionary.
private let thaiEnglishSectionHeaders = ["PHRASES / DERIVATIVES", "SYNONYMS"]

/// Reformats a raw Thai-English definition into readable phases: the main
/// senses as a bullet list (senses are comma-separated in this dictionary),
/// followed by each section on its own heading.
func formatForDisplay(_ raw: String) -> String {
    let (mainBody, sectionsText) = splitSections(raw.trimmingCharacters(in: .whitespaces), headers: thaiEnglishSectionHeaders)

    let senses = mainBody
        .components(separatedBy: ", ")
        .map { "• " + $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: "\n")

    return sectionsText.isEmpty ? senses : "\(senses)\n\n\(sectionsText)"
}

/// Section headers used by the New Oxford American Dictionary (English-English).
private let englishEnglishSectionHeaders = ["PHRASAL VERBS", "PHRASES", "DERIVATIVES", "USAGE", "ORIGIN"]

/// Prefix shown above an English-English fallback result, so the user
/// understands why no Thai translation appears.
private let englishOnlyNotice = "(คำศัพท์ภาษาอังกฤษ — ไม่มีคำแปลไทย)\n\n"

/// Reformats a raw English-English definition into readable phases. Unlike
/// the Thai-English dictionary, senses here are numbered prose (e.g. "1 ...
/// 2 ..."), not comma-separated, so the main body is left as one paragraph
/// and only the section headers are split onto their own lines.
func formatEnglishEnglishForDisplay(_ raw: String) -> String {
    let (mainBody, sectionsText) = splitSections(raw.trimmingCharacters(in: .whitespaces), headers: englishEnglishSectionHeaders)
    let body = sectionsText.isEmpty ? mainBody : "\(mainBody)\n\n\(sectionsText)"
    return englishOnlyNotice + body
}

// MARK: - Popover View Controller

final class PopoverViewController: NSViewController, NSSearchFieldDelegate {
    var onQuit: (() -> Void)?

    private let searchField = NSSearchField()
    private let resultTextView = NSTextView()
    private let scrollView = NSScrollView()
    private var debounceTimer: Timer?

    private let contentWidth: CGFloat = 320
    private let resultsHeight: CGFloat = 220

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 0))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let innerWidth = contentWidth - 24  // minus edge insets

        // Search field
        searchField.placeholderString = "พิมพ์คำ ไทย หรือ อังกฤษ…"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.font = NSFont.systemFont(ofSize: 14)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        stack.addArrangedSubview(searchField)

        // Results scroll view + text view
        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.drawsBackground = false
        resultTextView.font = NSFont.systemFont(ofSize: 13)
        resultTextView.textContainerInset = NSSize(width: 4, height: 4)
        // Wrap long definition lines to the fixed popover width instead of
        // running off the right edge.
        resultTextView.isHorizontallyResizable = false
        resultTextView.textContainer?.widthTracksTextView = true
        resultTextView.string = "พิมพ์คำเพื่อค้นหา"
        resultTextView.textColor = .secondaryLabelColor

        scrollView.documentView = resultTextView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: resultsHeight).isActive = true
        stack.addArrangedSubview(scrollView)

        // Divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        stack.addArrangedSubview(divider)

        // Quit button
        let quitBtn = NSButton(title: "Quit Dict on Menubar", target: self, action: #selector(quitClicked))
        quitBtn.bezelStyle = .roundRect
        quitBtn.setButtonType(.momentaryPushIn)
        quitBtn.font = NSFont.systemFont(ofSize: 12)
        quitBtn.translatesAutoresizingMaskIntoConstraints = false
        quitBtn.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        stack.addArrangedSubview(quitBtn)

        view.layoutSubtreeIfNeeded()
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    // Fires on every keystroke.
    func controlTextDidChange(_ obj: Notification) {
        debounceTimer?.invalidate()
        let query = searchField.stringValue
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.performLookup(query)
        }
    }

    private func performLookup(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            resultTextView.string = "พิมพ์คำเพื่อค้นหา"
            resultTextView.textColor = .secondaryLabelColor
            return
        }
        if let def = translate(trimmed) {
            resultTextView.string = formatForDisplay(def)
            resultTextView.textColor = .labelColor
        } else if let enDef = lookUpEnglishOnly(trimmed) {
            resultTextView.string = formatEnglishEnglishForDisplay(enDef)
            resultTextView.textColor = .labelColor
        } else {
            resultTextView.string = "ไม่พบคำว่า “\(trimmed)”"
            resultTextView.textColor = .secondaryLabelColor
        }
        resultTextView.scroll(NSPoint.zero)
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}

// MARK: - Menubar Controller

final class MenubarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let popoverVC = PopoverViewController()

    override init() {
        super.init()

        popoverVC.onQuit = { NSApplication.shared.terminate(nil) }

        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "character.book.closed",
                                   accessibilityDescription: "Dictionary")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            popoverVC.focusSearchField()
        }
    }
}

// MARK: - App Delegate

/// Standard Cut/Copy/Paste/Select All items with their usual key
/// equivalents. An accessory app has no menu bar of its own, but Cmd+V
/// (and friends) only work in a text field if some menu item is bound to
/// the "paste:" action — without this, the OS has nothing to route the
/// key press to, so pasting into the search field silently does nothing.
private func makeEditMenuItem() -> NSMenuItem {
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editMenuItem = NSMenuItem()
    editMenuItem.submenu = editMenu
    return editMenuItem
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubarController: MenubarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        mainMenu.addItem(makeEditMenuItem())
        NSApp.mainMenu = mainMenu
        menubarController = MenubarController()
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.activate(ignoringOtherApps: true)
app.run()
