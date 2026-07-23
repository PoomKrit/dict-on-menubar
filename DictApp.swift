// DictApp.swift
// Build: swiftc DictApp.swift -framework AppKit -framework CoreServices -o DictApp
// Run:   ./DictApp

import AppKit
import CoreServices

// MARK: - DictionaryServices Bridge (private API)

typealias DCSDictionaryRef = CFTypeRef

@_silgen_name("DCSGetActiveDictionaries")
func DCSGetActiveDictionaries() -> CFArray

@_silgen_name("DCSDictionaryGetIdentifier")
func DCSDictionaryGetIdentifier(_ dict: DCSDictionaryRef) -> CFString

@_silgen_name("DCSCopyTextDefinition")
func DCSCopyTextDefinition(_ dict: DCSDictionaryRef?, _ text: CFString, _ range: CFRange) -> Unmanaged<CFString>?

// MARK: - Lookup

/// The Oxford Thai-English dictionary, resolved once from the active set.
let thaiEnglishDictionary: DCSDictionaryRef? = {
    let actives = DCSGetActiveDictionaries() as [AnyObject]
    for d in actives {
        let ident = DCSDictionaryGetIdentifier(d as CFTypeRef) as String
        if ident.contains("th-en") { return d as CFTypeRef }
    }
    return nil
}()

/// Look up `text` in the Thai-English dictionary. Returns the raw definition
/// string, or nil when the input is empty/whitespace or has no entry.
func translate(_ text: String) -> String? {
    // Fail closed when the Thai-English dictionary is not enabled: passing a
    // nil dictionary would make DCSCopyTextDefinition search ALL active
    // dictionaries, silently violating the "th-en only" contract.
    guard let dict = thaiEnglishDictionary else { return nil }
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

// MARK: - Result Formatting

/// The dictionary's fixed section headers. Everything before the first one
/// is the main definition; everything from the first one onward is left as
/// the dictionary wrote it, since phrase entries within a section have no
/// reliable separator to split on.
private let dictionarySectionHeaders = ["PHRASES / DERIVATIVES", "SYNONYMS"]

/// Reformats a raw dictionary definition into readable phases: the main
/// senses as a bullet list, followed by each section on its own heading.
func formatForDisplay(_ raw: String) -> String {
    let text = raw.trimmingCharacters(in: .whitespaces)

    var mainBody = text
    var sectionsText = ""
    if let firstRange = dictionarySectionHeaders
        .compactMap({ text.range(of: $0) })
        .min(by: { $0.lowerBound < $1.lowerBound }) {
        mainBody = String(text[text.startIndex..<firstRange.lowerBound])
        sectionsText = String(text[firstRange.lowerBound...])
    }

    for header in dictionarySectionHeaders {
        sectionsText = sectionsText.replacingOccurrences(of: header, with: "\n\n\(header)\n")
    }
    sectionsText = sectionsText.trimmingCharacters(in: .whitespacesAndNewlines)

    let senses = mainBody
        .trimmingCharacters(in: .whitespaces)
        .components(separatedBy: ", ")
        .map { "• " + $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: "\n")

    return sectionsText.isEmpty ? senses : "\(senses)\n\n\(sectionsText)"
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubarController: MenubarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menubarController = MenubarController()
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.activate(ignoringOtherApps: true)
app.run()
